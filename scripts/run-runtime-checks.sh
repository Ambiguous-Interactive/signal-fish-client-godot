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

run_godot() {
	"${python_bin}" scripts/run-runtime-godot.py godot "$@"
}

run_smoke() {
	"${python_bin}" scripts/run-runtime-godot.py smoke
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
