#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

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
exec "${python_bin}" scripts/run-runtime-checks.py "$@"
