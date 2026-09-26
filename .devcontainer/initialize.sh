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
    # certain Docker Desktop drivers) reject chown, and a blocked create
    # is worse than a file the user must chown by hand (PR #159 review).
    chown --reference=.env.example .env.local \
        || echo 'WARN: could not set .env.local ownership; chown it manually if editing fails.' >&2
    echo '==> Created .env.local; edit it and rebuild to apply secrets.'
)
