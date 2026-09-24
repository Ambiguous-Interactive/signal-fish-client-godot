#!/usr/bin/env bash
# Install or refresh the dev container's terminal agent CLIs:
#   codex (OpenAI), OpenCode v2, nanocoder, claude (Anthropic).
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
    "${OPENCODE_NPM_SPEC:-@opencode/cli@latest}"
    "${NANOCODER_NPM_SPEC:-@nanocollective/nanocoder@latest}"
    "${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
)
BINARIES=(codex opencode nanocoder claude)
DANGLING_BINARIES=("${BINARIES[@]}" opencode2)
OPENCODE_V1_PACKAGE="opencode-ai"
OPENCODE_V2_PACKAGE="@opencode/cli"

# npm 11 blocks lifecycle scripts on global installs unless explicitly
# allowed. Every entry ships a postinstall that must run:
#   - @opencode/cli: selects/copies its platform binary
#   - @nanocollective/nanocoder: postinstall asset setup
#   - @anthropic-ai/claude-code, @openai/codex: platform package wiring
#   - @github/keytar, node-pty: native modules in these CLIs' dependency
#     trees (observed in the signal-fish-cloud devcontainer)
ALLOW_SCRIPTS="@opencode/cli,@nanocollective/nanocoder,@anthropic-ai/claude-code,@openai/codex,@github/keytar,node-pty,opencode-ai"

# Bounds only the registry version probe so an offline launch fails fast; the
# install leg uses npm's own (much larger) defaults because the package
# tarballs are far bigger than a version lookup.
npm_fetch_timeout_ms="${AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS:-5000}"
case "$npm_fetch_timeout_ms" in
    '' | *[!0-9]*) npm_fetch_timeout_ms=5000 ;;
esac

# Delay between failed `npm install` retry attempts. The hermetic
# fake-npm self-test suite forces instant failures, so it sets 0 to keep
# the state-machine matrix fast; real attach/post-create runs keep 2000 ms.
retry_sleep_ms="${AGENT_TOOLS_RETRY_SLEEP_MS:-2000}"
case "$retry_sleep_ms" in
    '' | *[!0-9]*) retry_sleep_ms=2000 ;;
esac
retry_sleep="$((retry_sleep_ms / 1000)).$(printf '%03d' $((retry_sleep_ms % 1000)))"

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
    for binary in "${DANGLING_BINARIES[@]}"; do
        link="${npm_bin_dir}/${binary}"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            if rm -f "$link"; then
                printf 'agent-tools: removed dangling bin link: %s\n' "$link"
            else
                warn_or_fail "could not remove dangling bin link: ${link}" || exit 1
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
export PATH="${npm_bin_dir}:${PATH}"

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

global_package_version() {
    local package_name="$1"

    npm_package_name="${package_name}" node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => { raw += chunk; });
        process.stdin.on("end", () => {
            try {
                const deps = JSON.parse(raw).dependencies || {};
                const entry = deps[process.env.npm_package_name];
                process.stdout.write(
                    entry && typeof entry.version === "string" ? entry.version : ""
                );
            } catch { process.stdout.write(""); }
        });
    ' <<<"$installed_json"
}

opencode_major_from_version() {
    local version="$1"

    version="${version#opencode }"
    version="${version#v}"
    version="${version#=}"
    version="${version%% *}"
    case "${version%%.*}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "${version%%.*}"
}

read_opencode_version() {
    local binary="$1"
    local output_prefix="$2"
    local status=0

    "$binary" --version >"${output_prefix}.out" 2>"${output_prefix}.err" || status=$?
    [ "$status" -eq 0 ] || return 1
    OPENCODE_VERSION="$(head -n 1 "${output_prefix}.out")"
    if [ -z "$OPENCODE_VERSION" ]; then
        OPENCODE_VERSION="$(head -n 1 "${output_prefix}.err")"
    fi
    [ -n "$OPENCODE_VERSION" ]
}

opencode_binary_is_owned_by_package() {
    local binary="$1"
    local package_root="$2"
    local target

    [ -L "$binary" ] || return 1
    [ -f "${package_root}/package.json" ] || return 1
    target="$(readlink -f -- "$binary" 2>/dev/null)" || return 1
    case "$target" in
        "${package_root}"/*) ;;
        *) return 1 ;;
    esac
}

active_opencode_is_v2() {
    local output_prefix="${probe_dir}/active-opencode-check"
    local package_root="${npm_prefix}/lib/node_modules/@opencode/cli"
    local major

    opencode_binary_is_owned_by_package "${npm_bin_dir}/opencode" "$package_root" || return 1
    [ -n "$(global_package_version "$OPENCODE_V2_PACKAGE")" ] || return 1
    read_opencode_version "${npm_bin_dir}/opencode" "$output_prefix" || return 1
    major="$(opencode_major_from_version "$OPENCODE_VERSION")" || return 1
    [ "$major" = 2 ]
}

candidate_opencode_is_v2() {
    local candidate_prefix="$1"
    local candidate_binary="${candidate_prefix}/bin/opencode"
    local output_prefix="${probe_dir}/candidate-opencode"
    local package_root="${candidate_prefix}/lib/node_modules/@opencode/cli"
    local major

    opencode_binary_is_owned_by_package "$candidate_binary" "$package_root" || return 1
    read_opencode_version "$candidate_binary" "$output_prefix" || return 1
    major="$(opencode_major_from_version "$OPENCODE_VERSION")" || return 1
    [ "$major" = 2 ]
}

save_active_opencode_v2_bins() {
    local alias
    local source_alias
    local backup_dir="${probe_dir}/active-opencode-v2-bins"

    mkdir -p "$backup_dir"
    for alias in opencode opencode2; do
        source_alias="$alias"
        if [ ! -e "${npm_bin_dir}/${source_alias}" ] && [ ! -L "${npm_bin_dir}/${source_alias}" ]; then
            if [ "$alias" = opencode ]; then
                source_alias=opencode2
            else
                source_alias=opencode
            fi
        fi
        if [ ! -e "${npm_bin_dir}/${source_alias}" ] && [ ! -L "${npm_bin_dir}/${source_alias}" ]; then
            return 1
        fi
        cp -a "${npm_bin_dir}/${source_alias}" "${backup_dir}/${alias}" || return 1
    done
}

restore_active_opencode_v2_bins() {
    local backup_dir="${probe_dir}/active-opencode-v2-bins"
    local alias
    local restore_ok=1

    for alias in opencode opencode2; do
        if [ ! -e "${backup_dir}/${alias}" ] && [ ! -L "${backup_dir}/${alias}" ]; then
            continue
        fi
        rm -f "${npm_bin_dir}/${alias}"
        cp -a "${backup_dir}/${alias}" "${npm_bin_dir}/${alias}" || restore_ok=0
    done
    [ "$restore_ok" = 1 ]
}

remove_opencode_v1() {
    local uninstall_status=0

    save_active_opencode_v2_bins || return 1
    npm uninstall --global "${OPENCODE_V1_PACKAGE}" || uninstall_status=$?
    restore_active_opencode_v2_bins || return 1
    active_opencode_is_v2 || return 1
    return "$uninstall_status"
}

remove_opencode_aliases() {
    rm -f "${npm_bin_dir}/opencode" "${npm_bin_dir}/opencode2"
}

restore_opencode_v1() {
    local version="$1"
    local major

    npm uninstall --global "@opencode/cli" >/dev/null 2>&1 || true
    sweep_dangling_bins
    if ! npm install --global --no-audit --no-fund \
        "${npm_allow_scripts_args[@]}" "${OPENCODE_V1_PACKAGE}@${version}"; then
        remove_opencode_aliases
        return 1
    fi
    if ! read_opencode_version "${npm_bin_dir}/opencode" "${probe_dir}/restored-opencode-v1"; then
        remove_opencode_aliases
        return 1
    fi
    if ! major="$(opencode_major_from_version "$OPENCODE_VERSION")"; then
        remove_opencode_aliases
        return 1
    fi
    if [ "$major" != 1 ]; then
        remove_opencode_aliases
        return 1
    fi
}

promote_opencode_v2() {
    local spec="$1"
    local v1_version="$2"
    local candidate_prefix="${probe_dir}/opencode-v2-prefix"

    if ! npm install --global --prefix "$candidate_prefix" --no-audit --no-fund \
        "${npm_allow_scripts_args[@]}" "$spec"; then
        return 1
    fi
    if ! candidate_opencode_is_v2 "$candidate_prefix"; then
        return 1
    fi

    if ! npm uninstall --global "${OPENCODE_V1_PACKAGE}"; then
        if restore_opencode_v1 "$v1_version"; then
            return 1
        fi
        return 2
    fi
    if ! npm install --global --no-audit --no-fund \
        "${npm_allow_scripts_args[@]}" "$spec"; then
        sweep_dangling_bins
        if restore_opencode_v1 "$v1_version"; then
            return 1
        fi
        return 2
    fi
    installed_json="$(npm list --global --depth=0 --json 2>/dev/null || true)"
    if ! active_opencode_is_v2; then
        if restore_opencode_v1 "$v1_version"; then
            return 1
        fi
        return 2
    fi
    opencode_v1_installed=""
}

probe_ok=()
for index in "${!pids[@]}"; do
    if wait "${pids[$index]}"; then
        probe_ok[$index]=1
    else
        probe_ok[$index]=0
        echo "agent-tools: WARNING: npm registry probe failed for ${PACKAGES[$index]}" >&2
    fi
done

opencode_v1_installed="$(global_package_version "${OPENCODE_V1_PACKAGE}")"
opencode_migration_blocked=0
if [ -n "$opencode_v1_installed" ]; then
    if active_opencode_is_v2; then
        printf 'agent-tools: removing OpenCode v1 package %s after proving the active binary is v2\n' "$opencode_v1_installed"
        if remove_opencode_v1; then
            opencode_v1_installed=""
            installed_json="$(npm list --global --depth=0 --json 2>/dev/null || true)"
        else
            warn_or_fail "could not remove OpenCode v1 after activating v2" || exit 1
            exit 0
        fi
    elif [ "${probe_ok[1]}" = 1 ]; then
        printf 'agent-tools: staging OpenCode v2 before replacing v1 %s\n' "$opencode_v1_installed"
        opencode_migration_status=0
        promote_opencode_v2 "${PACKAGES[1]}" "$opencode_v1_installed" || opencode_migration_status=$?
        if [ "$opencode_migration_status" -ne 0 ]; then
            opencode_migration_blocked=1
            if [ "$opencode_migration_status" = 2 ]; then
                warn_or_fail "could not prove and activate OpenCode v2; OpenCode v1 could not be restored" || exit 1
            else
                warn_or_fail "could not prove and activate OpenCode v2; retaining OpenCode v1" || exit 1
            fi
        fi
    else
        opencode_migration_blocked=1
        echo "agent-tools: WARNING: retaining OpenCode v1 because the v2 package is unavailable" >&2
    fi
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
    if [ "${probe_ok[$index]}" = 1 ] && [ -s "${probe_dir}/${index}" ]; then
        latest="$(tr -d '[:space:]' <"${probe_dir}/${index}")"
    fi

    installed="$(global_package_version "$package")"

    if [ "$index" = 1 ] && [ -n "$opencode_v1_installed" ] \
        && { [ "$opencode_migration_blocked" = 1 ] || [ "${probe_ok[$index]}" != 1 ]; }; then
        printf 'agent-tools: deferring OpenCode v2 install for %s while retaining v1\n' "$binary" >&2
        continue
    fi

    # In --update mode, an unreachable registry plus an absent CLI means every
    # install attempt is doomed; skip instead of paying it on every attach.
    if [ "$MODE" = "--update" ] && [ "${probe_ok[$index]}" != 1 ] \
        && [ -z "$installed" ] && [ ! -x "${npm_bin_dir}/${binary}" ]; then
        printf 'agent-tools: skipping %s: registry unreachable and not installed (rerun post-create when online)\n' "$binary" >&2
        continue
    fi

    opencode_needs_install=0
    if [ "$index" = 1 ] && ! active_opencode_is_v2; then
        opencode_needs_install=1
    fi
    if [ ! -x "${npm_bin_dir}/${binary}" ] \
        || [ -z "$installed" ] \
        || [ "$opencode_needs_install" = 1 ] \
        || { [ -n "$latest" ] && [ "$installed" != "$latest" ]; }; then
        install_specs+=("$spec")
    fi
done

# --- Install ------------------------------------------------------------------

# Each package is installed by its own `npm install --global` invocation.
# npm treats one multi-package command as a single transaction: if ANY
# postinstall fails (OpenCode's did, when a root-owned ~/.cache crashed its
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
                installed_json="$(npm list --global --depth=0 --json 2>/dev/null || true)"
                spec_ok=1
                break
            fi
            # A failed attempt rolls back package directories but may leave
            # dangling bin links; sweep so the next attempt (or the version
            # probe) sees the true state.
            sweep_dangling_bins
            if [ "$attempt" -lt "$attempts" ]; then
                printf 'agent-tools: npm install of %s failed (attempt %d/%d); retrying\n' "$spec" "$attempt" "$attempts" >&2
                if [ "$retry_sleep_ms" -gt 0 ]; then
                    sleep "$retry_sleep"
                fi
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

    # Verdict on exit status, with stdout/stderr captured separately: a
    # binary that exists but dies on startup (for example EACCES under a
    # root-owned ~/.cache) exits nonzero and prints an error line. Merging
    # the streams and treating any output as a version would mark broken
    # CLIs as ready; an error line is a diagnostic, not a version.
    version_status=0
    "$binary" --version >"${probe_dir}/${binary}.out" 2>"${probe_dir}/${binary}.err" || version_status=$?
    if [ "$version_status" -ne 0 ]; then
        missing+=("$binary")
        diagnostic="$(head -n 1 "${probe_dir}/${binary}.err")"
        if [ -z "$diagnostic" ]; then
            diagnostic="$(head -n 1 "${probe_dir}/${binary}.out")"
        fi
        if [ -n "$diagnostic" ]; then
            printf 'agent-tools: %s --version exited %d: %s\n' "$binary" "$version_status" "$diagnostic" >&2
        fi
        continue
    fi
    version="$(head -n 1 "${probe_dir}/${binary}.out")"
    if [ -z "$version" ]; then
        # Exit 0 with empty stdout: the CLI reports its version on stderr.
        version="$(head -n 1 "${probe_dir}/${binary}.err")"
    fi
    if [ -z "$version" ]; then
        missing+=("$binary")
        continue
    fi
    if [ "$binary" = "opencode" ] && ! active_opencode_is_v2; then
        missing+=("opencode (active binary is not an owned @opencode/cli package or is not major 2)")
        continue
    fi
    ready+=("${binary}@${version}")
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn_or_fail "agent CLIs missing or silent after provisioning: ${missing[*]} (npm prefix: ${npm_prefix})" || exit 1
    exit 0
fi

printf 'agent-tools: ready: %s\n' "${ready[*]}"
