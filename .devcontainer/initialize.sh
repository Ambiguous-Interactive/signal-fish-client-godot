#!/usr/bin/env bash
set -euo pipefail

cd /workspace
if [ -e .env.local ]; then
    [ -f .env.local ] || { echo 'ERROR: .env.local must be a file.' >&2; exit 1; }
    exit 0
fi

[ -r .env.example ] || { echo 'ERROR: .env.example is missing.' >&2; exit 1; }
# Noclobber preserves a file created concurrently by another window.
(
    umask 077
    set -o noclobber
    exec 3> .env.local || { [ -f .env.local ] && exit 0; exit 1; }
    cat .env.example >&3
    # Ownership matching is cosmetic; some bind mounts (root-squash NFS,
    # certain Docker Desktop drivers) refuse chown. The host-side
    # `docker --env-file` read still needs the file readable, or create
    # fails anyway (PR #159 review + CI).
    if chown --reference=.env.example .env.local; then
        :
    elif chmod a+r .env.local 2>/dev/null; then
        echo 'WARN: could not set .env.local ownership; made it world-readable instead. Tighten after editing.' >&2
    else
        echo 'WARN: could not set .env.local ownership or mode; fix by hand before rebuilding.' >&2
    fi
    echo '==> Created .env.local; edit it and rebuild to apply secrets.'
)
