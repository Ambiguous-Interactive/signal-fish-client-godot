#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

cleanup_paths=()

cleanup() {
	for path in "${cleanup_paths[@]}"; do
		rm -rf "${path}"
	done
}

trap cleanup EXIT

bootstrap_python="${PYTHON:-python3}"
# Only needed to fall back to user site-packages when the project venv is
# unusable; skip the interpreter spawn on the common venv path.
if [[ ! -f ".venv-ci/bin/activate" ]]; then
	original_user_site="$(
		"${bootstrap_python}" - <<'PY'
import site

print(site.getusersitepackages())
PY
	)"
fi

export HOME="${GDSCRIPT_TOOL_HOME:-${RUNNER_TEMP:-/tmp}/signal-fish-runtime-home}"
mkdir -p "${HOME}"
export GDTOOLKIT_CACHE_DIR="${GDTOOLKIT_CACHE_DIR:-${HOME}/gdtoolkit-cache}"

if [[ -f ".venv-ci/bin/activate" ]]; then
	# shellcheck disable=SC1091
	source ".venv-ci/bin/activate"
elif [[ -d ".venv-ci" ]]; then
	echo "::warning::.venv-ci is missing bin/activate; using user site-packages" >&2
	export PYTHONPATH="${original_user_site}${PYTHONPATH:+:${PYTHONPATH}}"
elif [[ -d "${original_user_site}" ]]; then
	export PYTHONPATH="${original_user_site}${PYTHONPATH:+:${PYTHONPATH}}"
fi

python_bin="${PYTHON:-python3}"
target="${1:-all}"
run_static_check() {
    "${python_bin}" scripts/run-runtime-static.py "$@"
}

run_private_helpers() {
    run_static_check private-helpers
}

run_static_on() {
    run_static_check scoped "$@"
}

run_format() {
    run_static_check format
}

run_lint() {
    run_static_check lint
}

run_python_types() {
    run_static_check python-types
}

run_gdscript_static() {
    run_static_check gdscript-static
}

run_static() {
    run_static_check static
}

# Any SCRIPT ERROR line is a runtime abort inside a test function: GDScript
# only unwinds that function, so a green suite would still have silently
# skipped every assertion after the abort point (issue #104).
_fail_on_script_errors() {
	local output="$1"
	if grep -q "SCRIPT ERROR" "${output}"; then
		echo "::error::SCRIPT ERROR in godot output (issue #104): the aborted test skipped its remaining assertions — fix the error, never trust a green suite" >&2
		return 1
	fi
}

report_godot_output() {
	local output="$1" failed="$2"
	if [[ "${failed}" -ne 0 || "${SF_VERBOSE:-0}" == "1" ]]; then
		cat "${output}"
	else
		echo "passed (set SF_VERBOSE=1 for full Godot output)"
		awk '
			/^(ERROR|WARNING):/ { if (++count <= 10) print }
			END { if (count > 10) printf "... %d more diagnostics\n", count - 10 }
		' "${output}"
	fi
}

# One slow pass over the (possibly network-backed) workspace tree; workers
# extract this local archive instead of each re-reading the tree (7 tar
# traversals -> 1). Returns 1 outside a git worktree; copy_cold_project
# then falls back to its per-worker pipe.
build_project_archive() {
	local archive="$1"
	local manifest="${archive}.manifest"
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		return 1
	fi
	git ls-files --cached --others --exclude-standard -z |
		while IFS= read -r -d '' path; do
			if [[ -f "${path}" || -L "${path}" ]]; then
				printf '%s\0' "${path}"
			fi
		done >"${manifest}"
	tar --null --files-from="${manifest}" --create --file="${archive}"
	rm -f "${manifest}"
}

# Warm-cache fast path: one read of the live .godot import cache into the
# given prep dir on fast local storage; every suite then clones it locally,
# turning each engine boot from a full cold reimport (~1.3 s) into a warm
# start (~0.3 s) — the dominant per-suite cost. Each suite still gets its
# own copy, so concurrent boots never share cache files. CI checkouts have
# no .godot, so CI boots stay byte-identical cold imports; SF_COLD=1 forces
# the CI-identical cold import locally too.
prepare_warm_cache_snapshot() {
	local dest="$1"
	if [[ "${SF_COLD:-0}" == "1" || ! -d ".godot" ]]; then
		return 0
	fi
	cp -a .godot "${dest}/.godot"
}

make_cold_parent() {
	local cold_parent_template="${RUNNER_TEMP:-/tmp}/signal-fish-godot-cold.XXXXXX"
	mktemp -d "${cold_parent_template}"
}

copy_cold_project() {
	local cold_parent="$1"
	local cold_project="${cold_parent}/project"
	local manifest
	# The manifest lives under the cold parent so the caller's existing
	# `rm -rf cold_parent` cleanup removes it too; registering it in the
	# caller-agnostic cleanup_paths leaked one file per suite in the
	# background workers, whose cleanup_paths is a subshell copy.
	manifest="${cold_parent}/manifest"
	mkdir -p "${cold_project}"

	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if [[ -n "${SF_GODOT_ARCHIVE:-}" && -f "${SF_GODOT_ARCHIVE}" ]]; then
			# Local archive built once by run_godot (see build_project_archive).
			tar --extract --file="${SF_GODOT_ARCHIVE}" --directory="${cold_project}"
		else
			# One tar stream per copy: packing the tracked+untracked file list once
			# is several times faster than a per-file mkdir/cp loop, which used to
			# dominate the wall of every suite boot. Files deleted in the working
			# tree (rm, pre-staging) are skipped like the old loop did; tar errors
			# stay loud through pipefail + set -e instead of shrinking the copy
			# behind a zero exit.
			git ls-files --cached --others --exclude-standard -z |
				while IFS= read -r -d '' path; do
					if [[ -f "${path}" || -L "${path}" ]]; then
						printf '%s\0' "${path}"
					fi
				done >"${manifest}"
			tar --null --files-from="${manifest}" --create --file=- |
				tar --extract --file=- --directory="${cold_project}"
		fi
	else
		tar \
			--exclude="./.git" \
			--exclude="./.godot" \
			--exclude="./.import" \
			--exclude="./.venv-ci" \
			--exclude="./logs_*.zip" \
			-cf - . | tar -C "${cold_project}" -xf -
	fi

	# Clone the warm import cache when a snapshot exists (see
	# prepare_warm_cache_snapshot); the clone reads local storage, so it is
	# nearly free.
	if [[ -n "${SF_GODOT_WARM_CACHE:-}" && -d "${SF_GODOT_WARM_CACHE}/.godot" ]]; then
		cp -a "${SF_GODOT_WARM_CACHE}/.godot" "${cold_project}/.godot"
	fi

	printf '%s\n' "${cold_project}"
}

run_godot_script() {
	local script_path="$1"
	local cold_parent cold_project output failed
	cold_parent="$(make_cold_parent)"
	# Register cleanup in this shell; copy_cold_project returns the project path via stdout.
	cleanup_paths+=("${cold_parent}")
	cold_project="$(copy_cold_project "${cold_parent}")"
	output="$(mktemp)"
	cleanup_paths+=("${output}")
	failed=0
	godot --headless --path "${cold_project}" --script "${script_path}" >"${output}" 2>&1 || failed=$?
	_fail_on_script_errors "${output}" || failed=1
	report_godot_output "${output}" "${failed}"
	return "${failed}"
}

_godot_command() {
	local command_path="$1"
	if [[ "${command_path}" == @demo ]]; then
		godot --headless --path "${2}" --quit-after 3
	elif [[ "${command_path}" == @p2p ]]; then
		godot --headless --path "${2}" res://demo/p2p.tscn --quit-after 3
	else
		godot --headless --path "${2}" --script "${command_path}"
	fi
}

_godot_worker() {
	local command_path="$1"
	local cold_parent cold_project
	cold_parent="$(make_cold_parent)"
	# The worker owns its cold copy: concurrent Godot boots would race on the
	# shared .godot caches if they imported one project directory together.
	# (They still share user://, but nothing in the suites reads it.) The
	# path is expanded into the trap text at registration time: after a
	# set -e abort the function frame (and its locals) is gone before the
	# EXIT trap runs, so a quoted variable reference would clean nothing.
	# shellcheck disable=SC2064
	trap "rm -rf '${cold_parent}'" EXIT
	cold_project="$(copy_cold_project "${cold_parent}")"
	_godot_command "${command_path}" "${cold_project}"
}

run_godot() {
	local all_names=(protocol transport client binary reconnect demo_boot p2p_boot)
	local all_commands=(
		tests/protocol/run_protocol_tests.gd
		tests/transport/run_transport_tests.gd
		tests/client/run_client_tests.gd
		tests/client/run_binary_tests.gd
		tests/client/run_reconnect_tests.gd
		@demo
		@p2p
	)
	local names=() commands=()
	if [[ "$#" -gt 0 ]]; then
		local name index found
		for name in "$@"; do
			found=""
			for index in "${!all_names[@]}"; do
				if [[ "${all_names[${index}]}" == "${name}" ]]; then
					names+=("${name}")
					commands+=("${all_commands[${index}]}")
					found=1
					break
				fi
			done
			if [[ -z "${found}" ]]; then
				echo "unknown suite: ${name} (suites: ${all_names[*]})" >&2
				return 2
			fi
		done
	else
		names=("${all_names[@]}")
		commands=("${all_commands[@]}")
	fi

	# Single-suite fast path for local iteration: run warm in-tree (the live
	# .godot cache, no cold copy) — a multi-second copy per boot is pure
	# overhead when only one engine is running. SF_COLD=1 forces the
	# CI-identical cold-copy isolation.
	if [[ "${#names[@]}" -eq 1 && "${SF_COLD:-0}" != "1" ]]; then
		echo "=== ${names[0]} (warm; SF_COLD=1 for the CI-identical cold copy) ==="
		local warm_output failed
		warm_output="$(mktemp)"
		cleanup_paths+=("${warm_output}")
		failed=0
		_godot_command "${commands[0]}" "${repo_root}" >"${warm_output}" 2>&1 || failed=$?
		_fail_on_script_errors "${warm_output}" || failed=1
		report_godot_output "${warm_output}" "${failed}"
		return "${failed}"
	fi

	# Suites are independent processes; run them concurrently and report each
	# result after all finish (same pattern as run_static).
	# Wall clock drops from the sum of engine boots to the slowest suite.
	# The tree archive and the warm cache snapshot are each built once,
	# concurrently, so seven workers read local storage instead of seven
	# traversals of the workspace mount.
	local prep_dir
	prep_dir="$(mktemp -d "${TMPDIR:-/tmp}/signal-fish-godot-prep.XXXXXX")"
	cleanup_paths+=("${prep_dir}")
	build_project_archive "${prep_dir}/proj.tar" >"${prep_dir}/archive.log" 2>&1 &
	local archive_pid=$!
	prepare_warm_cache_snapshot "${prep_dir}" >"${prep_dir}/snapshot.log" 2>&1 &
	local snapshot_pid=$!
	local archive_rc=0 snapshot_rc=0
	wait "${archive_pid}" || archive_rc=$?
	wait "${snapshot_pid}" || snapshot_rc=$?
	if [[ "${archive_rc}" -ne 0 || "${snapshot_rc}" -ne 0 ]]; then
		# Prep is an optimization, not a gate: workers fall back to their own
		# tar pipe (and cold boots), which stays correct. A failed tar or cp
		# can leave a truncated artifact behind — remove it, or the workers
		# would extract a partial tree instead of falling back.
		echo "::warning::godot prep step failed; using per-worker copies" >&2
		cat "${prep_dir}/archive.log" "${prep_dir}/snapshot.log" >&2 || true
		if ((archive_rc != 0)); then
			rm -f "${prep_dir}/proj.tar"
		fi
		if ((snapshot_rc != 0)); then
			rm -rf "${prep_dir}/.godot"
		fi
	fi
	local archive="${prep_dir}/proj.tar"
	[[ -f "${archive}" ]] || archive=""
	local cache_snapshot="${prep_dir}"
	[[ -d "${cache_snapshot}/.godot" ]] || cache_snapshot=""
	SF_GODOT_ARCHIVE="${archive}"
	SF_GODOT_WARM_CACHE="${cache_snapshot}"
	export SF_GODOT_ARCHIVE SF_GODOT_WARM_CACHE
	local outputs=()
	local pids=()
	local index
	for index in "${!names[@]}"; do
		local output
		output="$(mktemp)"
		outputs+=("${output}")
		cleanup_paths+=("${output}")
		_godot_worker "${commands[${index}]}" >"${output}" 2>&1 &
		pids+=("${!}")
	done
	local failed=0
	for index in "${!names[@]}"; do
		local rc=0
		wait "${pids[${index}]}" || rc=$?
		echo "=== ${names[${index}]} ==="
		_fail_on_script_errors "${outputs[${index}]}" || rc=1
		report_godot_output "${outputs[${index}]}" "${rc}"
		if [[ "${rc}" -ne 0 ]]; then
			failed=1
		fi
	done
	return "${failed}"
}

run_smoke() {
	run_godot_script tests/smoke/run_websocket_smoke.gd
}

# Agent fast loop (issue #117): Python selects checks from NUL-delimited Git
# paths and the test preload graph. Bash runs the selected gates.
run_changed() {
	local plan
	plan="$(mktemp)"
	cleanup_paths+=("${plan}")
	"${bootstrap_python}" scripts/select-runtime-checks.py >"${plan}"
	local fields=() field
	while IFS= read -r -d '' field; do
		fields+=("${field}")
	done <"${plan}"
	local mode="${fields[0]}" docs="${fields[1]}" python="${fields[2]}" pins="${fields[3]}"
	local suite_count="${fields[4]}" index=5 names=() static_files=()
	local i static_count
	for ((i = 0; i < suite_count; i++)); do
		names+=("${fields[${index}]}")
		index=$((index + 1))
	done
	static_count="${fields[${index}]}"
	index=$((index + 1))
	for ((i = 0; i < static_count; i++)); do
		static_files+=("${fields[${index}]}")
		index=$((index + 1))
	done

	if [[ "${mode}" == "clean" ]]; then
		echo "working tree clean; nothing to check"
		return 0
	fi
	if [[ "${mode}" == "docs" ]]; then
		echo "=== changed: docs-only edit -> style check (runtime suites unaffected) ==="
		"${bootstrap_python}" scripts/check-docs-style.py --changed
		return
	fi
	if [[ "${docs}" == "1" ]]; then
		"${bootstrap_python}" scripts/check-docs-style.py --changed
	fi
	if [[ "${mode}" == "python" ]]; then
		echo "=== changed: Python-only edit -> types, lint, format ==="
		run_python_types
		return
	fi
	if [[ "${python}" == "1" && "${mode}" != "full" ]]; then
		run_python_types
	fi

	if [[ "${mode}" == "full" ]]; then
		if [[ "${pins}" == "1" ]]; then
			echo "=== changed: tooling edit -> all suites and full static checks ==="
		else
			echo "=== changed: production-side edit -> all suites, static scoped to the edit ==="
		fi
		local static_output godot_rc=0 static_rc=0
		static_output="$(mktemp)"
		cleanup_paths+=("${static_output}")
		local python_output="" python_pid="" python_rc=0
		if [[ "${python}" == "1" && "${pins}" == "0" ]]; then
			python_output="$(mktemp)"
			cleanup_paths+=("${python_output}")
			run_python_types >"${python_output}" 2>&1 &
			python_pid=$!
		fi
		if [[ "${pins}" == "1" ]]; then
			run_static >"${static_output}" 2>&1 &
		else
			run_static_on ${static_files[@]+"${static_files[@]}"} >"${static_output}" 2>&1 &
		fi
		local static_pid=$!
		run_godot || godot_rc=$?
		wait "${static_pid}" || static_rc=$?
		cat "${static_output}"
		if [[ -n "${python_pid}" ]]; then
			wait "${python_pid}" || python_rc=$?
			cat "${python_output}"
		fi
		[[ "${static_rc}" -eq 0 && "${godot_rc}" -eq 0 && "${python_rc}" -eq 0 ]]
		return
	fi

	if [[ "${mode}" == "unreferenced" || "${mode}" == "uncertain" ]]; then
		if [[ "${mode}" == "uncertain" ]]; then
			echo "=== changed: uncertain test preload -> full gate ==="
		else
			echo "=== changed: unreferenced test file -> full gate ==="
		fi
		run_static
		run_godot
		return
	fi

	echo "=== changed: suites ${names[*]} ==="
	local godot_rc=0 static_rc=0
	run_static_on ${static_files[@]+"${static_files[@]}"} &
	local static_pid=$!
	run_godot "${names[@]}" || godot_rc=$?
	wait "${static_pid}" || static_rc=$?
	[[ "${static_rc}" -eq 0 && "${godot_rc}" -eq 0 ]]
}

case "${target}" in
all)
	# Static checks and the godot suites are independent: run them
	# concurrently and the gate wall drops to the slower half.
	local_all_output="$(mktemp)"
	cleanup_paths+=("${local_all_output}")
	run_static >"${local_all_output}" 2>&1 &
	static_pid=$!
	godot_rc=0
	run_godot || godot_rc=$?
	static_rc=0
	wait "${static_pid}" || static_rc=$?
	cat "${local_all_output}"
	if [[ "${static_rc}" -ne 0 || "${godot_rc}" -ne 0 ]]; then
		exit 1
	fi
	;;
static)
	run_static
	;;
gdscript-static)
	run_gdscript_static
	;;
python-types)
	run_python_types
	;;
private-helpers)
	run_private_helpers
	;;
format)
	run_format
	;;
lint)
	run_lint
	;;
godot)
	shift
	run_godot "$@"
	;;
changed)
	run_changed
	;;
smoke)
	run_smoke
	;;
*)
	echo "usage: $0 [all|static|gdscript-static|python-types|private-helpers|format|lint|godot [suite...]|changed|smoke]" >&2
	echo "  godot suites: protocol transport client binary reconnect demo_boot p2p_boot" >&2
	echo "  a single godot suite runs warm in-tree; SF_COLD=1 forces the cold copy" >&2
	echo "  changed checks only what the dirty tree can affect (agent fast loop)" >&2
	exit 2
	;;
esac
