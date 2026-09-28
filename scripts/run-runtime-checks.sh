#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
if [[ -f ".venv-ci/bin/activate" ]]; then
	unset PYTHONHOME
	export PATH="${repo_root}/.venv-ci/bin:${PATH}"
fi
exec "${PYTHON:-python3}" scripts/run-runtime-checks.py "$@"
