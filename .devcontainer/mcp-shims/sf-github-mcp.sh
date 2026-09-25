#!/usr/bin/env bash
# Launcher shim for GitHub's official MCP server (github-mcp-server).
#
# Every agent configuration in this repo points at this shim by name rather
# than at the binary directly, so the token is read from the shim's inherited
# environment at launch time and is never written into any configuration
# file. The shim exists to rename, not to store: it maps the repo's
# GITHUB_MCP_PAT convention (see .env.example) onto the binary's canonical
# GITHUB_PERSONAL_ACCESS_TOKEN.
#
# Installed to /usr/local/bin/sf-github-mcp by the dev container Dockerfile.
set -euo pipefail

export GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GITHUB_MCP_PAT:-}}"
case "${GITHUB_PERSONAL_ACCESS_TOKEN}" in
    *'${'*)
        # A client that did not expand ${GITHUB_MCP_PAT:-} hands us the
        # literal text; that must fail loudly, not authenticate with garbage.
        printf 'sf-github-mcp: token is an unexpanded variable reference; this client does not substitute ${VAR} in .mcp.json env maps\n' >&2
        exit 1
        ;;
esac
if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN}" ]; then
    printf 'sf-github-mcp: no token found; set GITHUB_MCP_PAT in .env.local (see .env.example) and rebuild the container\n' >&2
    exit 1
fi

# Read-only by default; opt out with GITHUB_READ_ONLY=0 in .env.local.
export GITHUB_READ_ONLY="${GITHUB_READ_ONLY:-1}"

exec /usr/local/bin/github-mcp-server stdio
