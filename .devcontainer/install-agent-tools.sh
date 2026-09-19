#!/usr/bin/env bash
# Install or refresh the dev container's terminal agent CLIs:
#   codex (OpenAI), opencode, nanocoder, claude (Anthropic).
#
# Modes:
#   (no args)  post-create install: strict; any failure exits non-zero.
#   --update   post-start refresh: best-effort; failures warn and exit 0 so a
#              registry outage can never block VS Code from attaching.
#
# Both modes probe the npm registry in parallel and skip the slow global
# install when every CLI is already current. Each spec is overridable per tool
# (e.g. CODEX_NPM_SPEC="@openai/codex@0.135.0"); the defaults stay @latest to
# match the sibling Signal Fish devcontainers, whose CLIs publish several
# times a day and are impractical to pin by hand.
set -euo pipefail

MODE="${1:-install}"
case "$MODE" in
    install) ;;
    --update) ;;
    *)
        echo "agent-tools: ERROR: unknown mode '${MODE}' (expected 'install' or '--update')" >&2
        exit 2
        ;;
esac

# Registry requests and package lifecycle scripts must never see forwarded
# credentials (mirrors signal-fish-cloud's provisioning posture).
unset GITHUB_TOKEN GH_TOKEN GITHUB_MCP_PAT Z_AI_API_KEY Z_AI_MODE CONTEXT7_API_KEY

PACKAGES=(
    "${CODEX_NPM_SPEC:-@openai/codex@latest}"
    "${OPENCODE_NPM_SPEC:-opencode-ai@latest}"
    "${NANOCODER_NPM_SPEC:-@nanocollective/nanocoder@latest}"
    "${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
)
BINARIES=(codex opencode nanocoder claude)

# npm 11 blocks lifecycle scripts on global installs unless explicitly
# allowed. Every entry ships a postinstall that must run:
#   - opencode-ai: selects/copies its platform binary
#   - @nanocollective/nanocoder: postinstall asset setup
#   - @anthropic-ai/claude-code, @openai/codex: platform package wiring
#   - @github/keytar, node-pty: native modules in these CLIs' dependency
#     trees (observed in the signal-fish-cloud devcontainer)
ALLOW_SCRIPTS="opencode-ai,@nanocollective/nanocoder,@anthropic-ai/claude-code,@openai/codex,@github/keytar,node-pty"

# Bounds only the registry version probe so an offline launch fails fast; the
# install leg uses npm's own (much larger) defaults because the package
# tarballs are far bigger than a version lookup.
npm_fetch_timeout_ms="${AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS:-5000}"
case "$npm_fetch_timeout_ms" in
    '' | *[!0-9]*) npm_fetch_timeout_ms=5000 ;;
esac

warn_or_fail() {
    local message="$1"

    if [ "$MODE" = "--update" ]; then
        printf 'agent-tools: WARNING: %s; continuing with the installed toolchain\n' "$message" >&2
        return 0
    fi
    printf 'agent-tools: ERROR: %s\n' "$message" >&2
    return 1
}

# --- Node toolchain guard ----------------------------------------------------

node_major="$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p' || true)"
if [ -z "$node_major" ] || [ "$node_major" -lt 22 ]; then
    warn_or_fail "Node.js 22 or newer is required (found: $(node --version 2>/dev/null || echo 'none'))" || exit 1
    exit 0
fi

# npm 11 introduced the lifecycle-script policy (--allow-scripts); npm 10
# (bundled with Node 22) predates it, where scripts simply run as before.
npm_allow_scripts_args=()
npm_major="$(npm --version 2>/dev/null | sed -nE 's/^([0-9]+).*/\1/p' || true)"
if [ -n "$npm_major" ] && [ "$npm_major" -ge 11 ]; then
    npm_allow_scripts_args=(--allow-scripts="$ALLOW_SCRIPTS")
fi

npm_prefix="$(npm config get prefix 2>/dev/null || true)"
if [ -z "$npm_prefix" ]; then
    warn_or_fail "npm config get prefix returned empty" || exit 1
    exit 0
fi

npm_bin_dir="${npm_prefix}/bin"
case ":${PATH}:" in
    *":${npm_bin_dir}:"*) ;;
    *) export PATH="${npm_bin_dir}:${PATH}" ;;
esac

# A not-yet-created user prefix (e.g. NPM_CONFIG_PREFIX=$HOME/.npm-global) is
# fine when its parent is writable; only an unwritable established prefix is
# a rebuild-grade problem.
if [ ! -d "$npm_prefix" ]; then
    if [ ! -w "$(dirname "$npm_prefix")" ]; then
        warn_or_fail "npm global prefix parent is not writable: $(dirname "$npm_prefix"); rebuild the container instead of repairing with elevated npm" || exit 1
        exit 0
    fi
elif [ ! -w "$npm_prefix" ]; then
    warn_or_fail "npm global prefix is not writable: ${npm_prefix}; rebuild the container instead of repairing with elevated npm" || exit 1
    exit 0
fi

# --- Registry probe (parallel) -----------------------------------------------

probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT

pids=()
for index in "${!PACKAGES[@]}"; do
    npm view "${PACKAGES[$index]}" version \
        --fetch-timeout="$npm_fetch_timeout_ms" --fetch-retries=0 \
        >"${probe_dir}/${index}" 2>/dev/null &
    pids+=("$!")
done

installed_json="$(npm list --global --depth=0 --json 2>/dev/null || true)"

registry_ok=1
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        registry_ok=0
    fi
done
if [ "$registry_ok" != 1 ]; then
    echo "agent-tools: WARNING: npm registry version probe incomplete; treating installed versions as unknown" >&2
fi

install_specs=()
for index in "${!PACKAGES[@]}"; do
    spec="${PACKAGES[$index]}"
    package="${spec%@*}"
    # A version-less scoped override ("@openai/codex") strips to "" at its
    # leading '@'; the package name is then the spec itself.
    if [ -z "$package" ]; then
        package="$spec"
    fi
    binary="${BINARIES[$index]}"

    latest=""
    if [ -s "${probe_dir}/${index}" ]; then
        latest="$(tr -d '[:space:]' <"${probe_dir}/${index}")"
    fi

    installed="$(npm_spec_package="$package" node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => { raw += chunk; });
        process.stdin.on("end", () => {
            try {
                const deps = JSON.parse(raw).dependencies || {};
                const entry = deps[process.env.npm_spec_package];
                process.stdout.write(
                    entry && typeof entry.version === "string" ? entry.version : ""
                );
            } catch { process.stdout.write(""); }
        });
    ' <<<"$installed_json")"

    # In --update mode, an unreachable registry plus an absent CLI means every
    # install attempt is doomed; skip instead of paying it on every attach.
    if [ "$MODE" = "--update" ] && [ "$registry_ok" != 1 ] \
        && [ -z "$installed" ] && [ ! -x "${npm_bin_dir}/${binary}" ]; then
        printf 'agent-tools: skipping %s: registry unreachable and not installed (rerun post-create when online)\n' "$binary" >&2
        continue
    fi

    # Skip only when the binary is present, a version is recorded, and the
    # registry (if reachable) reports nothing newer. An unreachable registry
    # keeps whatever is already installed.
    if [ ! -x "${npm_bin_dir}/${binary}" ] \
        || [ -z "$installed" ] \
        || { [ -n "$latest" ] && [ "$installed" != "$latest" ]; }; then
        install_specs+=("$spec")
    fi
done

# --- Install ------------------------------------------------------------------

if [ "${#install_specs[@]}" -gt 0 ]; then
    printf 'agent-tools: installing %d package(s) into %s\n' "${#install_specs[@]}" "$npm_prefix"
    attempts=3
    [ "$MODE" = "--update" ] && attempts=1

    install_ok=0
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        if npm install --global --no-audit --no-fund \
            "${npm_allow_scripts_args[@]}" \
            "${install_specs[@]}"; then
            install_ok=1
            break
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            printf 'agent-tools: npm install attempt %d/%d failed; retrying\n' "$attempt" "$attempts" >&2
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    if [ "$install_ok" != 1 ]; then
        warn_or_fail "npm could not install: ${install_specs[*]}" || exit 1
        exit 0
    fi
else
    echo "agent-tools: all agent CLIs are current; skipped npm install"
fi

# --- Verification --------------------------------------------------------------

ready=()
missing=()
for index in "${!BINARIES[@]}"; do
    binary="${BINARIES[$index]}"

    if ! command -v "$binary" >/dev/null 2>&1; then
        missing+=("$binary")
        continue
    fi

    # `|| true` guards against pipefail aborting on SIGPIPE if a chatty
    # --version output ever exceeds the pipe buffer after head exits.
    version="$( ("$binary" --version 2>/dev/null || true) | head -n 1 || true )"
    if [ -z "$version" ]; then
        missing+=("$binary")
        continue
    fi
    ready+=("${binary}@${version}")
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn_or_fail "agent CLIs missing or silent after provisioning: ${missing[*]} (npm prefix: ${npm_prefix})" || exit 1
    exit 0
fi

printf 'agent-tools: ready: %s\n' "${ready[*]}"
