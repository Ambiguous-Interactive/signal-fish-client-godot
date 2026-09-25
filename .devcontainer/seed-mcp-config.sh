#!/usr/bin/env bash
# Seed and verify agent MCP configurations.
#
# Claude Code, Nanocoder, and the VS Code agent host read the committed
# repo-root `.mcp.json`, and OpenCode v2 reads the committed `opencode.json`;
# both reference secrets by NAME (`${VAR}` / `{env:VAR}`), so nothing here
# writes secret values. Codex has no env-expanding config format, so its
# entries live in a marker-delimited managed block in `~/.codex/config.toml`
# (user-level: no project-trust prompt; regenerated on every run; content
# outside the markers is preserved verbatim).
#
# Modes:
#   (no args)  post-create: strict; failures exit non-zero.
#   --update   post-start: best-effort; failures warn and exit 0.
#
# The doctor section prints only variable NAMES and set/unset state - never
# values (CI and self-tests enforce this with canary secrets).
set -euo pipefail

MODE="${1:-install}"
case "$MODE" in
    install) ;;
    --update) ;;
    *)
        echo "seed-mcp-config: ERROR: unknown mode '${MODE}' (expected 'install' or '--update')" >&2
        exit 2
        ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MCP_JSON="${REPO_ROOT}/.mcp.json"
OPENCODE_JSON="${REPO_ROOT}/opencode.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_MARKER_BEGIN="# >>> signal-fish-mcp >>> managed by .devcontainer/seed-mcp-config.sh (regenerated; edit outside the markers)"
CODEX_MARKER_END="# <<< signal-fish-mcp <<<"

# Servers every surface must expose. Data-driven single source for the
# doctor and the duplicate-table guard below.
SERVERS=(godot github context7 deepwiki git fetch playwright)

CODEX_MANAGED_BLOCK="${CODEX_MARKER_BEGIN}
[mcp_servers.godot]
command = \"godot-mcp\"
args = []

[mcp_servers.godot.env]
GODOT_PATH = \"/usr/local/bin/godot\"

[mcp_servers.github]
command = \"sf-github-mcp\"
args = []

[mcp_servers.context7]
url = \"https://mcp.context7.com/mcp\"
bearer_token_env_var = \"CONTEXT7_API_KEY\"

[mcp_servers.deepwiki]
url = \"https://mcp.deepwiki.com/mcp\"

[mcp_servers.git]
command = \"mcp-server-git\"
args = []

[mcp_servers.fetch]
command = \"mcp-server-fetch\"
args = []

[mcp_servers.playwright]
command = \"playwright-mcp\"
args = []
${CODEX_MARKER_END}"

warn_or_fail() {
    local message="$1"

    if [ "$MODE" = "--update" ]; then
        printf 'seed-mcp-config: WARNING: %s\n' "$message" >&2
        return 0
    fi
    printf 'seed-mcp-config: ERROR: %s\n' "$message" >&2
    return 1
}

# --- JSON config validation ----------------------------------------------------

json_has_server() {
    # <file> <"mcpServers"|"mcp.servers"> <server> -> exit 0 when present.
    # Verdict on exit status from python's own evaluation, never output.
    local file="$1"
    local key_path="$2"
    local server="$3"

    [ -f "$file" ] || return 2
    python3 - "$file" "$key_path" "$server" <<'PY'
import json
import sys

path, key_path, server = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    node = json.load(handle)
for key in key_path.split("."):
    node = node[key]
sys.exit(0 if isinstance(node, dict) and server in node else 1)
PY
}

validate_json_configs() {
    local status=0
    local spec
    while IFS='|' read -r file key_path label; do
        if [ ! -f "$file" ]; then
            warn_or_fail "missing ${label} (${file})" || status=1
            continue
        fi
        if ! python3 -m json.tool "$file" >/dev/null 2>&1; then
            warn_or_fail "${label} is not valid JSON: ${file}" || status=1
            continue
        fi
        for server in "${SERVERS[@]}"; do
            if ! json_has_server "$file" "$key_path" "$server"; then
                warn_or_fail "${label} does not declare the '${server}' MCP server" || status=1
            fi
        done
    done <<SPEC
${MCP_JSON}|mcpServers|.mcp.json
${OPENCODE_JSON}|mcp.servers|opencode.json
SPEC
    return "$status"
}

# --- Codex managed block ---------------------------------------------------------

# Print the [mcp_servers.*] table names defined OUTSIDE the managed block.
outside_codex_tables() {
    BEGIN="$CODEX_MARKER_BEGIN" END="$CODEX_MARKER_END" awk '
        $0 == ENVIRON["BEGIN"] { skip = 1; next }
        $0 == ENVIRON["END"] { skip = 0; next }
        !skip && /^\[mcp_servers\.[A-Za-z0-9_-]+\]$/ {
            line = $0
            gsub(/^\[mcp_servers\.|\]$/, "", line)
            print line
        }
    ' "$1" 2>/dev/null
}

# Refuse to create a duplicate-table TOML error: if the user already defines
# one of our server tables outside the managed block, report and keep hands off.
codex_has_unmanaged_conflict() {
    local config="$1" server
    local outside
    outside="$(outside_codex_tables "$config")"
    for server in "${SERVERS[@]}"; do
        if grep -qxF "$server" <<<"$outside"; then
            return 0
        fi
    done
    return 1
}

seed_codex_config() {
    local status=0 rc=1
    local tmp_dir tmp_out

    if [ -f "${CODEX_CONFIG}" ] && codex_has_unmanaged_conflict "${CODEX_CONFIG}"; then
        warn_or_fail "${CODEX_CONFIG} defines signal-fish MCP server tables outside the managed block; remove them (or the managed block) and rerun" || status=1
        return "$status"
    fi

    if [ ! -f "${CODEX_CONFIG}" ]; then
        mkdir -p "$(dirname "${CODEX_CONFIG}")"
        printf '%s\n' "${CODEX_MANAGED_BLOCK}" >"${CODEX_CONFIG}"
        echo "seed-mcp-config: wrote codex managed block to ${CODEX_CONFIG}"
        return "$status"
    fi

    tmp_dir="$(dirname "${CODEX_CONFIG}")"
    tmp_out="$(mktemp "${tmp_dir}/.config.toml.XXXXXX")"
    # rc semantics from awk: 0 = managed block found and replaced, 1 = block
    # absent (append), 2 = corrupted (begin marker without end marker).
    rc=0
    BEGIN="$CODEX_MARKER_BEGIN" END="$CODEX_MARKER_END" BLOCK="$CODEX_MANAGED_BLOCK" \
        awk '
        BEGIN { done = 0; skip = 0 }
        !done && $0 == ENVIRON["BEGIN"] {
            print ENVIRON["BLOCK"]
            done = 1; skip = 1
            next
        }
        skip {
            if ($0 == ENVIRON["END"]) { skip = 0 }
            next
        }
        { print }
        END {
            if (skip) exit 2
            exit done ? 0 : 1
        }
    ' "${CODEX_CONFIG}" >"${tmp_out}" || rc=$?
    if [ "$rc" -eq 2 ]; then
        rm -f "${tmp_out}"
        warn_or_fail "${CODEX_CONFIG} has a corrupted managed block (begin marker without end marker); fix or delete it and rerun" || status=1
        return "$status"
    fi

    # Byte-exact compare: a run that changes nothing must not touch the file.
    if cmp -s "${tmp_out}" "${CODEX_CONFIG}"; then
        rm -f "${tmp_out}"
        echo "seed-mcp-config: codex managed block is current; skipped"
        return "$status"
    fi

    if [ "$rc" -eq 1 ]; then
        # Block absent (awk exited 1 having only echoed the original lines):
        # append the block itself, preserving everything already there.
        {
            printf '\n'
            printf '%s\n' "${CODEX_MANAGED_BLOCK}"
        } >>"${CODEX_CONFIG}"
        rm -f "${tmp_out}"
    else
        # Atomic replace on the same filesystem.
        mv "${tmp_out}" "${CODEX_CONFIG}"
    fi
    echo "seed-mcp-config: wrote codex managed block to ${CODEX_CONFIG}"
    return "$status"
}

# --- Doctor -----------------------------------------------------------------------

doctor() {
    local server file_ok
    echo "==> MCP doctor (values are never printed; only names and state)"
    for server in "${SERVERS[@]}"; do
        printf '  %-9s' "$server"
        file_ok=1
        json_has_server "${MCP_JSON}" "mcpServers" "$server" || file_ok=0
        printf ' mcp.json:%s' "$([ "$file_ok" -eq 1 ] && echo ok || echo MISSING)"
        json_has_server "${OPENCODE_JSON}" "mcp.servers" "$server" \
            && printf ' opencode:%s' ok || printf ' opencode:%s' MISSING
        if [ -f "${CODEX_CONFIG}" ] && grep -q "\\[mcp_servers\\.${server}\\]" "${CODEX_CONFIG}"; then
            printf ' codex:%s' ok
        else
            printf ' codex:%s' MISSING
        fi
        printf '\n'
    done
    local var
    for var in GITHUB_MCP_PAT CONTEXT7_API_KEY GITHUB_READ_ONLY; do
        if [ -n "${!var:-}" ]; then
            printf '  env %-18s set\n' "$var"
        else
            printf '  env %-18s UNSET\n' "$var"
        fi
    done
}

# --- Run ------------------------------------------------------------------------

status=0
validate_json_configs || status=1
seed_codex_config || status=1
doctor

if [ "$status" -ne 0 ]; then
    warn_or_fail "MCP configuration seeding reported problems above" || exit 1
    exit 0
fi
echo "==> MCP configurations seeded."
