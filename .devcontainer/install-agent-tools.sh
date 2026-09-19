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

# --- Dangling bin-link hygiene ------------------------------------------------

# npm's global reify is transactional for package directories but not for bin
# symlinks: when a global install fails (for example a package postinstall
# that exits nonzero), npm rolls back every extracted package yet leaves the
# freshly created bin symlinks in place. Those dangling links then shadow
# PATH with commands that fail exec with "No such file or directory" instead
# of an honest "command not found" -- the exact symptom that made a broken
# toolchain look like a missing one. Sweep them so a failed install degrades
# to "absent" (which the probe below reinstalls) instead of "poisoned".
sweep_dangling_bins() {
    local binary link
    for binary in "${BINARIES[@]}"; do
        link="${npm_bin_dir}/${binary}"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            if rm -f "$link"; then
                printf 'agent-tools: removed dangling bin link: %s\n' "$link"
            else
                warn_or_fail "could not remove dangling bin link: ${link}" || true
            fi
        fi
    done
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

# A prior failed run may have left bin links whose targets were rolled back;
# clean them before probing so PATH never holds commands that cannot exec.
sweep_dangling_bins

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

# Each package is installed by its own `npm install --global` invocation.
# npm treats one multi-package command as a single transaction: if ANY
# postinstall fails (opencode-ai's did, when a root-owned ~/.cache crashed its
# verify step), npm rolls back EVERY package in the command while leaving
# their bin symlinks behind -- so one broken package used to destroy the
# whole toolchain. Per-package installs bound the blast radius to that
# package alone; the remaining CLIs still land.
if [ "${#install_specs[@]}" -gt 0 ]; then
    printf 'agent-tools: installing %d package(s) into %s\n' "${#install_specs[@]}" "$npm_prefix"
    failed_specs=()
    for spec in "${install_specs[@]}"; do
        attempts=3
        [ "$MODE" = "--update" ] && attempts=1

        spec_ok=0
        attempt=1
        while [ "$attempt" -le "$attempts" ]; do
            if npm install --global --no-audit --no-fund \
                "${npm_allow_scripts_args[@]}" \
                "$spec"; then
                spec_ok=1
                break
            fi
            # A failed attempt rolls back package directories but may leave
            # dangling bin links; sweep so the next attempt (or the version
            # probe) sees the true state.
            sweep_dangling_bins
            if [ "$attempt" -lt "$attempts" ]; then
                printf 'agent-tools: npm install of %s failed (attempt %d/%d); retrying\n' "$spec" "$attempt" "$attempts" >&2
                sleep 2
            fi
            attempt=$((attempt + 1))
        done

        if [ "$spec_ok" != 1 ]; then
            failed_specs+=("$spec")
        fi
    done

    if [ "${#failed_specs[@]}" -gt 0 ]; then
        warn_or_fail "npm could not install: ${failed_specs[*]}" || exit 1
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

    # Capture stderr too: when a binary exists but dies on startup (for
    # example EACCES under a root-owned ~/.cache), the first error line is
    # far more actionable than reporting the CLI as silently missing.
    # `|| true` guards against pipefail aborting on SIGPIPE if a chatty
    # --version output ever exceeds the pipe buffer after head exits.
    version="$( ("$binary" --version 2>&1 || true) | head -n 1 || true )"
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
