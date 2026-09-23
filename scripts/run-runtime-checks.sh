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

run_private_helpers() {
	"${python_bin}" scripts/check-gdscript-private-helpers.py --self-test addons/signal_fish tests demo
}

run_format() {
	gdformat --diff --check addons/signal_fish tests demo
}

run_lint() {
	gdlint addons/signal_fish tests demo
}

run_static() {
	# gdtoolkit bootstraps its grammar cache ($HOME/.cache/gdtoolkit/<version>)
	# with a bare `os.makedirs` (parser.py, no exist_ok): concurrent cold
	# starts race EEXIST and a check fails with "Cannot open file ..." —
	# CI runners cold-start this home on every run. Pre-create the leaf
	# sequentially; identical-content pickle writes afterward are benign.
	mkdir -p "${HOME}/.cache/gdtoolkit/$(gdformat --version | awk '{print $2}')"
	# All three checks are independent; run them concurrently and report each
	# tool's output verbatim after all finish.
	local helper_output format_output lint_output helper_rc format_rc lint_rc
	helper_output="$(mktemp)"
	format_output="$(mktemp)"
	lint_output="$(mktemp)"
	cleanup_paths+=("${helper_output}" "${format_output}" "${lint_output}")
	run_private_helpers >"${helper_output}" 2>&1 &
	local helper_pid=$!
	run_format >"${format_output}" 2>&1 &
	local format_pid=$!
	run_lint >"${lint_output}" 2>&1 &
	local lint_pid=$!
	helper_rc=0
	wait "${helper_pid}" || helper_rc=$?
	format_rc=0
	wait "${format_pid}" || format_rc=$?
	lint_rc=0
	wait "${lint_pid}" || lint_rc=$?
	cat "${helper_output}"
	rm -f "${helper_output}"
	cat "${format_output}"
	rm -f "${format_output}"
	cat "${lint_output}"
	rm -f "${lint_output}"
	if [[ "${helper_rc}" -ne 0 || "${format_rc}" -ne 0 || "${lint_rc}" -ne 0 ]]; then
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
	manifest="$(mktemp)"
	cleanup_paths+=("${manifest}")
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
	local cold_parent cold_project
	cold_parent="$(make_cold_parent)"
	# Register cleanup in this shell; copy_cold_project returns the project path via stdout.
	cleanup_paths+=("${cold_parent}")
	cold_project="$(copy_cold_project "${cold_parent}")"
	godot --headless --path "${cold_project}" --script "${script_path}"
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
		_godot_command "${commands[0]}" "${repo_root}"
		return
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
	done
	return "${failed}"
}

run_smoke() {
	run_godot_script tests/smoke/run_websocket_smoke.gd
}

case "${target}" in
	all)
		run_static
		run_godot
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
	smoke)
		run_smoke
		;;
	*)
		echo "usage: $0 [all|static|private-helpers|format|lint|godot [suite...]|smoke]" >&2
		echo "  godot suites: protocol transport client binary reconnect demo_boot p2p_boot" >&2
		echo "  a single godot suite runs warm in-tree; SF_COLD=1 forces the cold copy" >&2
		exit 2
		;;
esac
