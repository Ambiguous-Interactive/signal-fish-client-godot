#!/usr/bin/env bash
# Seed and verify agent MCP configurations.
#
# Claude Code, Nanocoder, and the VS Code agent host read the committed
# repo-root `.mcp.json`, and OpenCode v2 reads the committed `opencode.json`;
# both reference secrets by NAME (`${VAR}` env maps / parent-environment
# inheritance), so nothing here writes secret values. Codex has no
# env-expanding config format, so its entries live in a marker-delimited
# managed block in `~/.codex/config.toml` (user-level: no project-trust
# prompt; regenerated on every run; content outside the markers is
# preserved verbatim; secret-consuming entries use `env_vars` allow-lists
# because Codex forwards a sanitized environment).
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
env_vars = [\"GITHUB_MCP_PAT\", \"GITHUB_PERSONAL_ACCESS_TOKEN\", \"GITHUB_READ_ONLY\", \"GITHUB_TOOLSETS\"]

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
args = [\"--browser\", \"chromium\", \"--headless\", \"--no-sandbox\"]
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

# One python fork reports every JSON problem for both config surfaces.
# Per-server forks here were the seed-test fork tax (~45 execve calls per
# run; issue #145 class). Lines, consumed by validate_json_configs, the
# doctor, and json_report_valid:
#   FILE_MISSING|<label>|<path>
#   FILE_INVALID|<label>|<path>
#   SERVER_MISSING|<label>|<server>
#   REPORT_OK (sentinel; its absence means the report is unknown)
json_report() {
    python3 - "$MCP_JSON" "$OPENCODE_JSON" "${SERVERS[@]}" <<'PY'
import json
import os
import sys

mcp_path, opencode_path, *servers = sys.argv[1:]
surfaces = (
    (".mcp.json", mcp_path, "mcpServers"),
    ("opencode.json", opencode_path, "mcp.servers"),
)
for label, path, key_path in surfaces:
    if not os.path.isfile(path):
        print(f"FILE_MISSING|{label}|{path}")
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            node = json.load(handle)
    except (OSError, ValueError):
        print(f"FILE_INVALID|{label}|{path}")
        continue
    for key in key_path.split("."):
        node = node[key] if isinstance(node, dict) and key in node else None
    for server in servers:
        if not isinstance(node, dict) or server not in node:
            print(f"SERVER_MISSING|{label}|{server}")
print("REPORT_OK")
PY
}

# 0 only when json_report actually finished (an empty report - python3
# missing - must read as "unknown", never as "all surfaces ok").
json_report_valid() {
    local kind rest
    while IFS='|' read -r kind rest; do
        [ -n "$kind" ] || continue
        if [ "$kind" = "REPORT_OK" ]; then
            return 0
        fi
    done <<<"$JSON_REPORT"
    return 1
}

json_surface_loaded() {
    # <label> -> 0 when the report has no missing/invalid entry for it.
    local label="$1" kind found rest
    while IFS='|' read -r kind found rest; do
        [ -n "$kind" ] || continue
        if { [ "$kind" = "FILE_MISSING" ] || [ "$kind" = "FILE_INVALID" ]; } && [ "$found" = "$label" ]; then
            return 1
        fi
    done <<<"$JSON_REPORT"
    return 0
}

json_server_ok() {
    # <label> <server> -> 0 when the surface loaded and declares the server.
    json_report_valid || return 1
    json_surface_loaded "$1" || return 1
    local label="$1" server="$2" kind found rest
    while IFS='|' read -r kind found rest; do
        [ -n "$kind" ] || continue
        if [ "$kind" = "SERVER_MISSING" ] && [ "$found" = "$label" ] && [ "$rest" = "$server" ]; then
            return 1
        fi
    done <<<"$JSON_REPORT"
    return 0
}

validate_json_configs() {
    local status=0
    local kind label rest
    while IFS='|' read -r kind label rest; do
        [ -n "$kind" ] || continue
        case "$kind" in
            FILE_MISSING)   warn_or_fail "missing ${label} (${rest})" || status=1 ;;
            FILE_INVALID)   warn_or_fail "${label} is not valid JSON: ${rest}" || status=1 ;;
            SERVER_MISSING) warn_or_fail "${label} does not declare the '${rest}' MCP server" || status=1 ;;
        esac
    done <<<"$JSON_REPORT"
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
                begin_count = 1
                next
            }
            if (done && line == ENVIRON["BEGIN"]) {
                # A second complete block is exactly the damage the old
                # replace-then-append bug produced; refuse rather than
                # "repair" it into duplicate TOML tables.
                begin_count = begin_count + 1
                if (begin_count > 1) fail = 1
                next
            }
            if (skip) {
                if (line == ENVIRON["END"]) { skip = 0 }
                next
            }
            print
        }
        END {
            # An `exit` in the main rule would still run this END block and
            # its own exit would override the code - so every status is
            # decided HERE.
            if (fail) exit 3
            if (skip) exit 2
            exit done ? 0 : 1
        }
    ' "${CODEX_CONFIG}" >"${tmp_out}" || rc=$?
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
        rm -f "${tmp_out}"
        warn_or_fail "${CODEX_CONFIG} has a corrupted managed block (begin marker without end marker, or more than one managed block); fix or delete it and rerun" || status=1
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

# Anchored, CR-tolerant check that the codex config defines
# [mcp_servers.<server>] (a commented-out line is not a configured server).
# All table names are extracted with one awk per run instead of one fork per
# server (issue #145 fork tax); the managed block counts as configured.
codex_config_tables() {
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\[mcp_servers\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\]$/) {
                sub(/^\[mcp_servers\./, "", line)
                sub(/\]$/, "", line)
                print line
            }
        }
    ' "$1" 2>/dev/null
}

codex_table_present() {
    # <tables output> <server> -> 0 when a table equals the server or is a
    # subtable of it ([mcp_servers.<server>.<sub>]).
    local tables="$1" server="$2" line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$line" = "$server" ] || [[ "$line" == "$server".* ]]; then
            return 0
        fi
    done <<<"$tables"
    return 1
}

doctor() {
    local server file_ok codex_ok
    local doctor_missing=0
    local codex_tables
    codex_tables="$(codex_config_tables "${CODEX_CONFIG}" || true)"
    echo "==> MCP doctor (values are never printed; only names and state)"
    for server in "${SERVERS[@]}"; do
        printf '  %-9s' "$server"
        file_ok=1
        json_server_ok ".mcp.json" "$server" || file_ok=0
        printf ' mcp.json:%s' "$([ "$file_ok" -eq 1 ] && echo ok || echo MISSING)"
        json_server_ok "opencode.json" "$server" \
            && printf ' opencode:%s' ok || printf ' opencode:%s' MISSING
        codex_ok=1
        codex_table_present "$codex_tables" "$server" || codex_ok=0
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
JSON_REPORT="$(json_report)" || {
    warn_or_fail "could not evaluate MCP JSON configs (python3 failed)" || status=1
    JSON_REPORT=""
}
validate_json_configs || status=1
seed_codex_config || status=1
doctor
status=$((status + DOCTOR_STATUS))

if [ "$status" -ne 0 ]; then
    warn_or_fail "MCP configuration seeding reported problems above" || exit 1
    exit 0
fi
echo "==> MCP configurations seeded."
