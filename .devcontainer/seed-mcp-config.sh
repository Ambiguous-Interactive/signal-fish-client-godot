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
if [ "$#" -gt 1 ]; then
    echo "seed-mcp-config: ERROR: unexpected extra arguments: $*" >&2
    exit 2
fi

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
# Codex forwards a sanitized environment by default; without this
# allow-list the shim would launch without a token and exit loudly.
env_vars = [\"GITHUB_MCP_PAT\", \"GITHUB_PERSONAL_ACCESS_TOKEN\"]

[mcp_servers.context7]
command = \"context7-mcp\"
args = []
env_vars = [\"CONTEXT7_API_KEY\"]

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
# CRLF-edited configs are handled: the trailing \r is stripped before
# matching so a Windows-edited file can never hide a conflicting table.
outside_codex_tables() {
    BEGIN="$CODEX_MARKER_BEGIN" END="$CODEX_MARKER_END" awk '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line == ENVIRON["BEGIN"]) { skip = 1; next }
            if (line == ENVIRON["END"]) { skip = 0; next }
            if (!skip && line ~ /^\[mcp_servers\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\]$/) {
                sub(/^\[mcp_servers\./, "", line)
                sub(/\]$/, "", line)
                print line
            }
        }
    ' "$1" 2>/dev/null
}

# Refuse to create a duplicate-table TOML error: if the user already defines
# one of our server tables (or a subtable such as
# [mcp_servers.godot.env]) outside the managed block, report and keep hands
# off. Subtable matches matter because TOML forbids redefining the base
# table afterwards just as much as an exact duplicate.
codex_has_unmanaged_conflict() {
    local config="$1" server line
    local outside
    outside="$(outside_codex_tables "$config")"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        for server in "${SERVERS[@]}"; do
            if [ "$line" = "$server" ] || [[ "$line" == "$server".* ]]; then
                return 0
            fi
        done
    done <<<"$outside"
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
    # absent (the output is the unchanged input), 2 = corrupted (begin
    # marker without end marker). Marker comparison is CR-tolerant so a
    # CRLF-edited config cannot hide its block and get double-seeded.
    rc=0
    BEGIN="$CODEX_MARKER_BEGIN" END="$CODEX_MARKER_END" BLOCK="$CODEX_MANAGED_BLOCK" \
        awk '
        {
            line = $0
            sub(/\r$/, "", line)
            if (!done && line == ENVIRON["BEGIN"]) {
                print ENVIRON["BLOCK"]
                done = 1; skip = 1
                next
            }
            if (skip) {
                if (line == ENVIRON["END"]) { skip = 0 }
                next
            }
            print
        }
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

    if [ "$rc" -eq 1 ]; then
        # Block absent: append the managed block, preserving everything
        # already there. This is the common case for an existing user
        # config; it must never be mistaken for a no-op (the unchanged
        # output above would compare byte-identical to the input).
        rm -f "${tmp_out}"
        {
            printf '\n'
            printf '%s\n' "${CODEX_MANAGED_BLOCK}"
        } >>"${CODEX_CONFIG}"
        echo "seed-mcp-config: wrote codex managed block to ${CODEX_CONFIG}"
        return "$status"
    fi

    # rc = 0: the block was found and replaced. Byte-exact compare so a run
    # that changes nothing must not touch the file.
    if cmp -s "${tmp_out}" "${CODEX_CONFIG}"; then
        rm -f "${tmp_out}"
        echo "seed-mcp-config: codex managed block is current; skipped"
        return "$status"
    fi

    # Atomic replace on the same filesystem.
    mv "${tmp_out}" "${CODEX_CONFIG}"
    echo "seed-mcp-config: wrote codex managed block to ${CODEX_CONFIG}"
    return "$status"
}

# --- Doctor -----------------------------------------------------------------------

# Anchored, CR-tolerant, comment-aware check that the codex config defines
# [mcp_servers.<server>] (a commented-out line is not a configured server).
codex_has_server_table() {
    local config="$1" server="$2"

    [ -f "${config}" ] || return 1
    SERVER="$server" awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            target = "^\\[mcp_servers\\." ENVIRON["SERVER"] "(\\.[A-Za-z0-9_-]+)*\\]$"
            if (line ~ target) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "${config}"
}

doctor() {
    local server file_ok codex_ok
    local doctor_missing=0
    echo "==> MCP doctor (values are never printed; only names and state)"
    for server in "${SERVERS[@]}"; do
        printf '  %-9s' "$server"
        file_ok=1
        json_has_server "${MCP_JSON}" "mcpServers" "$server" || file_ok=0
        printf ' mcp.json:%s' "$([ "$file_ok" -eq 1 ] && echo ok || echo MISSING)"
        json_has_server "${OPENCODE_JSON}" "mcp.servers" "$server" \
            && printf ' opencode:%s' ok || printf ' opencode:%s' MISSING
        codex_ok=1
        codex_has_server_table "${CODEX_CONFIG}" "$server" || codex_ok=0
        printf ' codex:%s' "$([ "$codex_ok" -eq 1 ] && echo ok || echo MISSING)"
        [ "$file_ok" -eq 1 ] && [ "$codex_ok" -eq 1 ] || doctor_missing=1
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
    # In install (post-create) mode the codex surface is fully script-owned,
    # so a MISSING here can only mean a refused write or a bug - fail loudly
    # instead of printing a table nobody gates on. --update stays
    # informational so an outage never blocks attach.
    if [ "$doctor_missing" -eq 1 ]; then
        warn_or_fail "doctor found MISSING MCP servers (see above)" || DOCTOR_STATUS=1
    fi
    return 0
}

# --- Run ------------------------------------------------------------------------

status=0
DOCTOR_STATUS=0
validate_json_configs || status=1
seed_codex_config || status=1
doctor
status=$((status + DOCTOR_STATUS))

if [ "$status" -ne 0 ]; then
    warn_or_fail "MCP configuration seeding reported problems above" || exit 1
    exit 0
fi
echo "==> MCP configurations seeded."
