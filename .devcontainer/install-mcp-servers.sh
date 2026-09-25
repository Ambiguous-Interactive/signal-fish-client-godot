#!/usr/bin/env bash
# Install or refresh the dev container's npm-based MCP servers:
#   godot-mcp (@coding-solo/godot-mcp) and playwright-mcp (@playwright/mcp).
#
# The Dockerfile installs the non-npm MCP servers (github-mcp-server binary,
# pipx mcp-server-git / mcp-server-fetch); this script covers the two that
# need Node, because Node itself is provided by a devcontainer feature that
# is layered on *after* the Dockerfile (see .llm/skills/devcontainer-tooling.md).
#
# Modes:
#   (no args)  post-create install: strict; any failure exits non-zero.
#   --update   post-start refresh: best-effort; failures warn and exit 0 so a
#              registry outage can never block VS Code from attaching.
#
# Unlike install-agent-tools.sh there is no registry probe: both specs are
# pinned concrete versions (overridable), so "installed version == spec"
# is decidable offline from npm's own state.
set -euo pipefail

MODE="${1:-install}"
case "$MODE" in
    install) ;;
    --update) ;;
    *)
        echo "mcp-servers: ERROR: unknown mode '${MODE}' (expected 'install' or '--update')" >&2
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    echo "mcp-servers: ERROR: unexpected extra arguments: $*" >&2
    exit 2
fi

# Package installs must never see forwarded credentials (mirrors
# install-agent-tools.sh).
unset GITHUB_TOKEN GH_TOKEN GITHUB_MCP_PAT GITHUB_PERSONAL_ACCESS_TOKEN \
    Z_AI_API_KEY Z_AI_MODE CONTEXT7_API_KEY

# Pinned concrete versions (harness test asserts the shape). Overrides must
# stay concrete so the offline "installed == spec" skip remains decidable;
# validated below.
PACKAGES=(
    "${GODOT_MCP_NPM_SPEC:-@coding-solo/godot-mcp@0.1.1}"
    "${PLAYWRIGHT_MCP_NPM_SPEC:-@playwright/mcp@0.0.82}"
    "${CONTEXT7_MCP_NPM_SPEC:-@upstash/context7-mcp@4.0.4}"
)
BINARIES=(godot-mcp playwright-mcp context7-mcp)
DANGLING_BINARIES=("${BINARIES[@]}")
# None of these packages ship lifecycle scripts today (playwright removed its
# postinstall years ago; browsers install on demand). The allow list keeps a
# future postinstall from being silently skipped by npm >= 11's policy.
ALLOW_SCRIPTS="@coding-solo/godot-mcp,@playwright/mcp,@upstash/context7-mcp,playwright,playwright-core"

warn_or_fail() {
    local message="$1"

    if [ "$MODE" = "--update" ]; then
        printf 'mcp-servers: WARNING: %s; continuing with the installed toolchain\n' "$message" >&2
        return 0
    fi
    printf 'mcp-servers: ERROR: %s\n' "$message" >&2
    return 1
}

sweep_dangling_bins() {
    local npm_bin_dir="$1"
    local binary link
    for binary in "${DANGLING_BINARIES[@]}"; do
        link="${npm_bin_dir}/${binary}"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link" || warn_or_fail "could not remove dangling bin link: ${link}" || exit 1
            printf 'mcp-servers: removed dangling bin link: %s\n' "$link"
        fi
    done
}

# --- Node toolchain guard ----------------------------------------------------

node_major="$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p' || true)"
if [ -z "$node_major" ] || [ "$node_major" -lt 22 ]; then
    warn_or_fail "Node.js 22 or newer is required (found: $(node --version 2>/dev/null || echo 'none'))" || exit 1
    exit 0
fi

npm_major="$(npm --version 2>/dev/null | sed -nE 's/^([0-9]+).*/\1/p' || true)"
npm_allow_scripts_args=()
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

# One `npm list --json` call per invocation of installed_versions(); each
# call forks npm once and the result is consumed by a single node parse.
installed_versions()
{
    npm list --global --depth=0 --json 2>/dev/null || true
}

# Verdict from the parsed npm state: the node helper exits 0 only when the
# exact name@version pair is present. (npm list itself may exit non-zero
# for unrelated reasons, so its status is deliberately not consulted.)
package_is_installed() {
    local package="$1"
    local expected_version="$2"

    [ -n "$expected_version" ] || return 1
    installed_versions | node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => { raw += chunk; });
        process.stdin.on("end", () => {
            // node -e places script arguments at argv[1] and argv[2].
            const name = process.argv[1];
            const expected = process.argv[2];
            try {
                const deps = JSON.parse(raw).dependencies || {};
                const entry = deps[name];
                process.exit(entry && entry.version === expected ? 0 : 1);
            } catch {
                process.exit(1);
            }
        });
    ' "$package" "$expected_version"
}

spec_version() {
    # "@scope/name@1.2.3" -> "1.2.3"; a spec without a trailing version
    # yields "" (treated as "always install", never as "current").
    local version="${1##*@}"

    case "$version" in
        */*) printf '' ;;
        *) printf '%s' "$version" ;;
    esac
}

# Overrides must stay concrete: a dist-tag or range would make the offline
# "installed == spec" check permanently false, so every post-start would
# reinstall and strict verification would fail after a successful install.
validate_specs_are_concrete() {
    local spec version
    for spec in "${PACKAGES[@]}"; do
        version="$(spec_version "$spec")"
        if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'; then
            echo "mcp-servers: ERROR: npm spec '${spec}' must pin a concrete x.y.z version (set a concrete override or unset it)." >&2
            return 1
        fi
    done
}
if ! validate_specs_are_concrete; then
    exit 1
fi

spec_package() {
    # "@scope/name@1.2.3" -> "@scope/name"; a version-less scoped spec
    # ("@scope/name") strips to "" at its leading '@' and is the spec itself.
    local spec="$1"
    local package="${spec%@*}"

    if [ -z "$package" ]; then
        package="$spec"
    fi
    printf '%s' "$package"
}

# --- Install -------------------------------------------------------------------

failed_specs=()
for spec in "${PACKAGES[@]}"; do
    package="$(spec_package "$spec")"
    version="$(spec_version "$spec")"

    if package_is_installed "$package" "$version"; then
        printf 'mcp-servers: %s@%s is current; skipped\n' "$package" "$version"
        continue
    fi

    sweep_dangling_bins "$npm_bin_dir"
    if npm install --global --no-audit --no-fund \
        "${npm_allow_scripts_args[@]}" \
        "$spec"; then
        printf 'mcp-servers: installed %s\n' "$spec"
    else
        sweep_dangling_bins "$npm_bin_dir"
        failed_specs+=("$spec")
    fi
done

if [ "${#failed_specs[@]}" -gt 0 ]; then
    warn_or_fail "npm could not install: ${failed_specs[*]}" || exit 1
    exit 0
fi

# --- Verification --------------------------------------------------------------

missing=()
for index in "${!BINARIES[@]}"; do
    binary="${BINARIES[$index]}"
    spec="${PACKAGES[$index]}"
    binary_path="$(command -v "$binary" 2>/dev/null || true)"
    # Presence AND executability: command -v alone reports success for a
    # non-executable file left behind by a partially failed install.
    if [ -z "$binary_path" ] || [ ! -x "$binary_path" ]; then
        missing+=("$binary")
        continue
    fi
    if ! package_is_installed "$(spec_package "$spec")" "$(spec_version "$spec")"; then
        missing+=("${binary} (npm global state does not match ${spec})")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn_or_fail "MCP servers missing or mismatched after provisioning: ${missing[*]} (npm prefix: ${npm_prefix})" || exit 1
    exit 0
fi

# --- Playwright Chromium (install mode only; best-effort) -----------------------

if [ "$MODE" != "install" ]; then
    echo "mcp-servers: --update skipped the Chromium install (heal via post-create or rerun the installer in install mode)"
elif [ "${SF_MCP_SKIP_PLAYWRIGHT_BROWSER:-0}" = "1" ]; then
    echo "mcp-servers: SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1; skipped Chromium install"
else
    # @playwright/mcp launches browsers through its own bundled playwright,
    # whose Chromium revision is independent of the repo's pinned
    # `playwright` package (single pin site: .github/actions/playwright-chromium),
    # so the browser must be installed with that bundled CLI, not npx.
    mcp_pkg_dir="${npm_prefix}/lib/node_modules/@playwright/mcp"
    # The path is passed through the environment (not interpolated into the
    # JS text) so prefixes containing quotes or backslashes survive.
    pw_cli="$(MCP_PKG_DIR="$mcp_pkg_dir" node -p \
        "const path = require('path'); path.join(path.dirname(require.resolve('playwright/package.json', { paths: [process.env.MCP_PKG_DIR] })), 'cli.js')" \
        2>/dev/null || true)"
    if [ -n "$pw_cli" ] && [ -f "$pw_cli" ]; then
        echo "==> Installing Chromium for playwright-mcp (best-effort; may take a few minutes)"
        if node "$pw_cli" install --with-deps chromium; then
            echo "==> Chromium installed for playwright-mcp"
        else
            echo "mcp-servers: WARNING: Chromium install failed; playwright-mcp tools will not run" \
                "until it succeeds (rerun: node \"$pw_cli\" install --with-deps chromium)" >&2
        fi
    else
        echo "mcp-servers: WARNING: could not locate @playwright/mcp's bundled playwright CLI; skipping Chromium install" >&2
    fi
fi

printf 'mcp-servers: ready: %s\n' "${BINARIES[*]}"
