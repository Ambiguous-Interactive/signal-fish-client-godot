#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"
exec python3 "${repo_root}/.devcontainer/post-start.py"
