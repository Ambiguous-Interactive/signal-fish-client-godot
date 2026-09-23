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
original_user_site="$("${bootstrap_python}" - <<'PY'
import site

print(site.getusersitepackages())
PY
)"

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
GD_DIRS=(addons/signal_fish tests demo)

gdtoolkit_version() {
	# importlib.metadata reads the dist-info without importing the gdtoolkit
	# parser: ~0.15 s vs ~0.7 s for `gdformat --version` (a full import).
	# Every prepare call in one gate run reuses the first answer.
	if [[ -z "${_GDTOOLKIT_VERSION:-}" ]]; then
		_GDTOOLKIT_VERSION="$("${bootstrap_python}" -c 'import importlib.metadata as m; print(m.version("gdtoolkit"))')"
		export _GDTOOLKIT_VERSION
	fi
	printf '%s\n' "${_GDTOOLKIT_VERSION}"
}

prepare_gdtoolkit_cache() {
	# gdtoolkit bootstraps its grammar cache ($HOME/.cache/gdtoolkit/<version>)
	# with a bare `os.makedirs` (parser.py, no exist_ok): concurrent cold
	# starts race EEXIST and a check fails with "Cannot open file ..." —
	# CI runners cold-start this home on every run. Pre-create the leaf
	# sequentially; identical-content pickle writes afterward are benign.
	mkdir -p "${HOME}/.cache/gdtoolkit/$(gdtoolkit_version)"
}

# Run a per-file GDScript tool over GD_DIRS as parallel same-tool shards and
# report each shard's output verbatim once all finish. Sharding cuts the
# per-invocation interpreter/parse fixed cost that dominates a serial run of
# the small file set; the checks themselves are unchanged (issue #112).
run_sharded_tool() {
	local tool="$1"
	shift
	local files=()
	# `read -d ''` works back to bash 3.2 (macOS stock); `mapfile -d` would
	# need 4.4 and abort under `set -e` there.
	while IFS= read -r -d '' file; do
		files+=("${file}")
	done < <(find "${GD_DIRS[@]}" -type f -name '*.gd' -print0 | sort -z)
	if [[ "${#files[@]}" -eq 0 ]]; then
		return 0
	fi
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/signal-fish-shards.XXXXXX")"
	# The subshell owns the shard outputs: its EXIT trap removes them even
	# when `set -e` aborts mid-wait, so an early failure cannot leak files.
	(
		trap 'rm -rf "'"$tmp_dir"'"' EXIT
		local shard_count=4
		local shard_size=$((( ${#files[@]} + shard_count - 1 ) / shard_count))
		local pids=() outs=() index=0 shard=0
		while [[ "${index}" -lt "${#files[@]}" ]]; do
			local batch=() output
			while
				[[ "${#batch[@]}" -lt "${shard_size}" && "${index}" -lt "${#files[@]}" ]]
			do
				batch+=("${files[${index}]}")
				index=$((index + 1))
			done
			output="${tmp_dir}/shard-${shard}.out"
			"${tool}" "$@" "${batch[@]}" >"${output}" 2>&1 &
			pids+=("$!")
			outs+=("${output}")
			shard=$((shard + 1))
		done
		local failed=0 i rc
		for i in "${!pids[@]}"; do
			rc=0
			wait "${pids[${i}]}" || rc=$?
			cat "${outs[${i}]}"
			[[ "${rc}" -eq 0 ]] || failed=1
		done
		[[ "${failed}" -eq 0 ]] || exit 1
	)
}

run_private_helpers() {
	"${python_bin}" scripts/check-gdscript-private-helpers.py --self-test "${GD_DIRS[@]}"
}

# Scoped variants for the agent fast loop: same tools, no analyzer self-test,
# explicit file set. The full self-test + whole-tree sweep stays the CI and
# pre-push contract; this only widens what the inner loop may skip.
run_private_helpers_on() {
	"${python_bin}" scripts/check-gdscript-private-helpers.py "$@"
}

# Sharded per-file tool run over an explicit file list:
#   run_sharded_tool_on <tool> [tool args...] -- <files...>
run_sharded_tool_on() {
	local tool="$1"
	shift
	local tool_args=() files=() past_separator=""
	while [[ "$#" -gt 0 ]]; do
		if [[ -z "${past_separator}" && "${1}" == "--" ]]; then
			past_separator="1"
		elif [[ -n "${past_separator}" ]]; then
			files+=("$1")
		else
			tool_args+=("$1")
		fi
		shift
	done
	if [[ "${#files[@]}" -eq 0 ]]; then
		return 0
	fi
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/signal-fish-shards.XXXXXX")"
	(
		trap 'rm -rf "'"$tmp_dir"'"' EXIT
		local shard_count=4
		local shard_size=$((( ${#files[@]} + shard_count - 1 ) / shard_count))
		local pids=() outs=() index=0 shard=0
		while [[ "${index}" -lt "${#files[@]}" ]]; do
			local batch=() output
			while
				[[ "${#batch[@]}" -lt "${shard_size}" && "${index}" -lt "${#files[@]}" ]]
			do
				batch+=("${files[${index}]}")
				index=$((index + 1))
			done
			output="${tmp_dir}/shard-${shard}.out"
			# ${tool_args[@]+...}: the array may be empty (gdlint takes no
			# args) and bare empty-array expansion aborts under `set -u` on
			# bash < 4.4 (macOS stock 3.2).
			"${tool}" ${tool_args[@]+"${tool_args[@]}"} "${batch[@]}" >"${output}" 2>&1 &
			pids+=("$!")
			outs+=("${output}")
			shard=$((shard + 1))
		done
		local failed=0 i rc
		for i in "${!pids[@]}"; do
			rc=0
			wait "${pids[${i}]}" || rc=$?
			cat "${outs[${i}]}"
			[[ "${rc}" -eq 0 ]] || failed=1
		done
		[[ "${failed}" -eq 0 ]] || exit 1
	)
}

# Scoped static checks for the agent fast loop: the same three checks over
# the given files only, skipping the analyzer self-test (a ~2 s guard on the
# analyzer itself that CI and the full gate still enforce). An empty list is
# a no-op: the analyzer's own zero-args default would sweep the whole tree.
run_static_on() {
	if [[ "$#" -eq 0 ]]; then
		return 0
	fi
	prepare_gdtoolkit_cache
	local helper_out format_out lint_out failed=0 rc
	helper_out="$(mktemp)"
	format_out="$(mktemp)"
	lint_out="$(mktemp)"
	# Always invoked backgrounded (subshell), so cleanup_paths would be a
	# copy and leak; the EXIT trap self-cleans even on a `set -e` abort,
	# mirroring the cold-copy workers.
	trap 'rm -rf "'"${helper_out}"'" "'"${format_out}"'" "'"${lint_out}"'"' EXIT
	run_private_helpers_on "$@" >"${helper_out}" 2>&1 &
	local helper_pid=$!
	run_sharded_tool_on gdformat --diff --check -- "$@" >"${format_out}" 2>&1 &
	local format_pid=$!
	run_sharded_tool_on gdlint -- "$@" >"${lint_out}" 2>&1 &
	local lint_pid=$!
	rc=0
	wait "${helper_pid}" || failed=1
	cat "${helper_out}"
	rc=0
	wait "${format_pid}" || rc=$?
	cat "${format_out}"
	[[ "${rc}" -eq 0 ]] || failed=1
	rc=0
	wait "${lint_pid}" || rc=$?
	cat "${lint_out}"
	[[ "${rc}" -eq 0 ]] || failed=1
	return "${failed}"
}


run_format() {
	prepare_gdtoolkit_cache
	run_sharded_tool gdformat --diff --check
}

run_lint() {
	prepare_gdtoolkit_cache
	run_sharded_tool gdlint
}

run_static() {
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/signal-fish-static.XXXXXX")"
	# One temp dir owned by a subshell trap: if `set -e` aborts a check early,
	# the remaining outputs still get cleaned up instead of leaking.
	(
		trap 'rm -rf "'"$tmp_dir"'"' EXIT
		# run_format/run_lint pre-create the grammar cache themselves before
		# their shards start, so no separate prepare step is needed here.
		run_private_helpers >"${tmp_dir}/helper.out" 2>&1 &
		local helper_pid=$!
		run_format >"${tmp_dir}/format.out" 2>&1 &
		local format_pid=$!
		run_lint >"${tmp_dir}/lint.out" 2>&1 &
		local lint_pid=$!
		local failed=0 rc
		rc=0
		wait "${helper_pid}" || rc=$?
		cat "${tmp_dir}/helper.out"
		[[ "${rc}" -eq 0 ]] || failed=1
		rc=0
		wait "${format_pid}" || rc=$?
		cat "${tmp_dir}/format.out"
		[[ "${rc}" -eq 0 ]] || failed=1
		rc=0
		wait "${lint_pid}" || rc=$?
		cat "${tmp_dir}/lint.out"
		[[ "${rc}" -eq 0 ]] || failed=1
		[[ "${failed}" -eq 0 ]] || exit 1
	)
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
	else
		tar \
			--exclude="./.git" \
			--exclude="./.godot" \
			--exclude="./.import" \
			--exclude="./.venv-ci" \
			--exclude="./logs_*.zip" \
			-cf - . | tar -C "${cold_project}" -xf -
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
	cat "${output}"
	_fail_on_script_errors "${output}" || failed=1
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
		cat "${warm_output}"
		_fail_on_script_errors "${warm_output}" || failed=1
		return "${failed}"
	fi

	# Suites are independent processes; run them concurrently and report each
	# suite's output verbatim after all finish (same pattern as run_static).
	# Wall clock drops from the sum of engine boots to the slowest suite.
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
		cat "${outputs[${index}]}"
		if [[ "${rc}" -ne 0 ]]; then
			failed=1
		fi
		_fail_on_script_errors "${outputs[${index}]}" || failed=1
	done
	return "${failed}"
}

run_smoke() {
	run_godot_script tests/smoke/run_websocket_smoke.gd
}

# Agent fast loop (issue #117): check only what the dirty tree can affect.
# Suite selection is a BFS over the runners' res:// preload strings — a
# changed test file maps to the suites that (transitively) load it; any
# production-side or unreferenced change falls back to the full gate, so the
# mapping can't silently under-run. Output states exactly what ran and why.
collect_changed_files() {
	{
		git diff --name-only HEAD
		git ls-files --others --exclude-standard
	} | sort -u
}

suite_uses_file() {
	local runner="$1" target="$2"
	if [[ "${runner}" == "${target}" ]]; then
		return 0
	fi
	local queue=("$runner") seen=""
	while [[ "${#queue[@]}" -gt 0 ]]; do
		local current="${queue[0]}"
		queue=("${queue[@]:1}")
		case " $seen " in *" ${current} "*) continue ;; esac
		seen+="${current} "
		if grep -qF "res://${target}" "${current}" 2>/dev/null; then
			return 0
		fi
		while IFS= read -r dep; do
			queue+=("${dep#res://}")
		done < <(grep -o 'res://tests/[^"]*' "${current}" 2>/dev/null || true)
	done
	return 1
}

run_changed() {
	local files
	files="$(collect_changed_files)"
	if [[ -z "${files}" ]]; then
		echo "working tree clean; nothing to check"
		return 0
	fi
	local runtime_changed="" gd_suites=() md_only=1 file
	while IFS= read -r file; do
		case "${file}" in
			*.md | .markdownlint* | LICENSE)
				;;
			*)
				md_only=""
				;;
		esac
		case "${file}" in
			addons/* | demo/* | scripts/* | project.godot | export_presets.cfg | tests/fixtures/*)
				runtime_changed="full"
				;;
			tests/*.gd)
				gd_suites+=("${file}")
				;;
		esac
	done <<<"${files}"

	if [[ -n "${md_only}" ]]; then
		echo "docs-only change: no runtime checks; run agent-check.ps1 for .llm edits"
		return 0
	fi

	if [[ "${runtime_changed}" == "full" ]]; then
		echo "=== changed: production-side edit -> all suites, static scoped to the edit ==="
		local static_output godot_rc=0 static_rc=0
		static_output="$(mktemp)"
		cleanup_paths+=("${static_output}")
		# Format/lint/private-helper checks are per-file, so scoping them to
		# the edited files cannot miss an effect of the edit; the analyzer
		# self-test and whole-tree sweep stay the `all`/CI/pre-push contract.
		# Every godot suite still runs: a production file can affect any of
		# them, so the behavioral gate never under-runs (issue #117).
		local static_files=() gd_file
		for gd_file in ${gd_suites[@]+"${gd_suites[@]}"}; do
			[[ -f "${gd_file}" ]] && static_files+=("${gd_file}")
		done
		# Same directory scope as the gate (addons/signal_fish, tests, demo):
		# the fast loop must never be stricter than the pre-push contract.
		while IFS= read -r file; do
			case "${file}" in
				addons/signal_fish/*.gd | demo/*.gd)
					[[ -f "${file}" ]] && static_files+=("${file}")
					;;
			esac
		done <<<"${files}"
		run_static_on ${static_files[@]+"${static_files[@]}"} >"${static_output}" 2>&1 &
		local static_pid=$!
		run_godot || godot_rc=$?
		wait "${static_pid}" || static_rc=$?
		cat "${static_output}"
		[[ "${static_rc}" -eq 0 && "${godot_rc}" -eq 0 ]]
		return
	fi

	local runner name names=()
	for runner in \
		"protocol tests/protocol/run_protocol_tests.gd" \
		"transport tests/transport/run_transport_tests.gd" \
		"client tests/client/run_client_tests.gd" \
		"binary tests/client/run_binary_tests.gd" \
		"reconnect tests/client/run_reconnect_tests.gd"; do
		name="${runner%% *}"
		runner="${runner#* }"
		# ${gd_suites[@]+...}: possibly empty; bare expansion aborts under
		# `set -u` on bash < 4.4 (macOS stock 3.2).
		for file in ${gd_suites[@]+"${gd_suites[@]}"}; do
			if suite_uses_file "${runner}" "${file}"; then
				names+=("${name}")
				break
			fi
		done
	done
	if [[ "${#names[@]}" -eq 0 ]]; then
		echo "=== changed: unreferenced test file -> full gate ==="
		run_static
		run_godot
		return
	fi

	echo "=== changed: suites ${names[*]} ==="
	# Deleted paths still map to their suite above (the runners reference
	# them), but the static tools cannot read a missing file.
	local static_files=()
	for file in ${gd_suites[@]+"${gd_suites[@]}"}; do
		[[ -f "${file}" ]] && static_files+=("${file}")
	done
	local godot_rc=0 static_rc=0
	# Same bash < 4.4 empty-array guard as above.
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
		echo "usage: $0 [all|static|private-helpers|format|lint|godot [suite...]|changed|smoke]" >&2
		echo "  godot suites: protocol transport client binary reconnect demo_boot p2p_boot" >&2
		echo "  a single godot suite runs warm in-tree; SF_COLD=1 forces the cold copy" >&2
		echo "  changed checks only what the dirty tree can affect (agent fast loop)" >&2
		exit 2
		;;
esac
