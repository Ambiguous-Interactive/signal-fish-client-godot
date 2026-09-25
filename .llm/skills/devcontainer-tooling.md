---
description: Use when changing the VS Code dev container, installed tools, MCP servers, shell profiles, or post-create/post-start setup.
triggers: devcontainer, container, codex, opencode, nanocoder, claude, agent cli, cli, post-create, postcreate, post-start, poststart, powershell profile, pwsh profile, PSReadLine, toolchain, mcp, mcp servers, godot-mcp, playwright-mcp, github-mcp-server, context7, deepwiki, env file, secrets
category: Tooling
---

# Dev Container Tooling

## Trigger

Use this skill when changing `.devcontainer/**`, installed command-line tools,
MCP server wiring, PowerShell profile behavior, or post-create/post-start
setup.

## Placement Rules

- The Dockerfile runs before devcontainer features. Tools that depend on Node,
  PowerShell, Python feature state, or the final remote user should be installed
  from `post-create.sh` or a helper it calls, unless the Dockerfile installs the
  dependency itself.
- Keep command-line tool installs idempotent and pinned by default. Allow an
  environment override only when the default remains a concrete version.
  Documented exception: the agent CLIs below install at `@latest` (each spec
  still env-overridable) because they publish several times a day; freshness is
  kept by a registry-probe fast path instead of version pins, matching the
  sibling Signal Fish devcontainers.
- Never automate interactive authentication. Install the CLI and verify a
  non-interactive command such as `--version`; let users sign in later.

## Current Guarantees

- The four terminal agent CLIs - OpenAI Codex (`@openai/codex`), OpenCode v2
  (`@opencode/cli`), Nanocoder (`@nanocollective/nanocoder`), and Claude Code
  (`@anthropic-ai/claude-code`) - are installed by
  `.devcontainer/install-agent-tools.sh` into npm's global prefix.
- `post-create.sh` invokes the installer strictly after the Node feature has
  made `node` (>= 22) and `npm` available, then verifies each of the four
  binaries is on PATH and includes all four versions in the toolchain summary.
  Any install or verification failure fails post-create.
- `post-start.sh` runs after every successful container start: it re-applies
  the git `safe.directory` trust, re-runs the installer with `--update`
  (warn-only), and heals the Python automation deps so the local gate matches
  CI: PyYAML is installed into user site-packages when bare `python3` cannot
  import it (harness sandbox tests strip `.venv-ci`, and runner images ship
  PyYAML globally), and `.venv-ci` is created when missing with the runtime
  (gdtoolkit, per ci.yml) and automation (PyYAML, per llm-harness.yml)
  requirements, so `scripts/run-runtime-checks.sh` and the harness share one
  local venv. Both heals are warn-only and never block attaching.
- The installer installs each package with its own `npm install --global`
  (npm treats one multi-package command as a single transaction, so one
  failing postinstall used to roll back every package while leaving their
  `bin` symlinks behind) and sweeps dangling `bin` links before probing and
  after failed attempts, so a broken install degrades to "missing" (which the
  next run reinstalls) instead of leaving PATH poisoned with commands that
  fail exec with "No such file or directory".
- Health checks verdict on exit status, never on captured-output presence.
  The installer's verification runs each `--version` with stdout and stderr
  redirected to separate files: nonzero exit means broken (the first error
  line is reported as the diagnostic - how the `~/.cache` EACCES class of
  failure is diagnosed), exit 0 with no output means missing, and only exit
  0 with output counts as ready (stderr is consulted when stdout is empty,
  because some CLIs print their version there). OpenCode must additionally
  report major version 2. Merging the streams and treating any non-empty
  line as a version once marked dying binaries as ready; the harness
  self-tests now reject that pattern.
- The installer derives npm's global prefix, prepends its `bin` directory to
  PATH, and passes npm 11's `--allow-scripts` (npm blocks lifecycle scripts on
  global installs by default; `@opencode/cli` needs its postinstall to select
  the platform binary). The flag is only passed on npm >= 11; npm 10 (bundled
  with Node 22) predates the policy and runs scripts as before. OpenCode v2 is
  staged in an isolated npm prefix and its binary must report major version 2
  before the package-managed v1 `opencode-ai` is removed. If staging or
  activation fails, v1 remains active when restoration succeeds; a failed
  restoration is a strict failure and a warn-only update failure. An offline
  update also retains v1 when v2 is absent; if both records exist and the
  active binary is proven v2, v1 is removed without a registry request. Specs
  are overridable via
  `CODEX_NPM_SPEC`, `OPENCODE_NPM_SPEC`,
  `NANOCODER_NPM_SPEC`, and `CLAUDE_NPM_SPEC`;
  `AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS` (default 5000) bounds only the registry
  version probe, not the install itself, and `AGENT_TOOLS_RETRY_SLEEP_MS`
  (default 2000) is the backoff between failed install retries; the hermetic
  fake-npm self-test matrix sets 0 so rollback cases do not pay real sleep
  time.
- `post-create.sh` repairs root-owned mounted directories such as
  `/commandhistory` and `~/.cache` (Docker creates volume-mount parents as
  root; a root-owned `~/.cache` crashed opencode's postinstall verify step and
  VS Code's agent host with EACCES), installs the direct git hooks-path
  pre-commit shim via `scripts/install-git-hooks.ps1 -Force`, and does not
  install the slower pre-commit framework hook.
- npm cache lives under the container user's home directory and is not mounted
  as a named volume by this repo, so cache ownership repair is not part of the
  devcontainer contract.
- `.devcontainer/pwsh-profile.ps1` is best-effort terminal polish. It must not
  emit errors if PSReadLine is already loaded, preloaded as an assembly by the
  VS Code PowerShell extension, missing, or too old for optional settings.

## MCP Servers

The dev container seeds seven MCP servers into every agent CLI (claude,
opencode, nanocoder, codex, and the VS Code agent host): `godot`
(@coding-solo/godot-mcp driving the installed headless editor via
`GODOT_PATH`), `github` (official github-mcp-server binary), `context7`
(@upstash/context7-mcp, local stdio, key from env), `deepwiki` (remote repo
Q&A), `git` (mcp-server-git), `fetch` (mcp-server-fetch), and `playwright`
(@playwright/mcp for web-export browser work).

- Secret invariant: values live only in the process environment.
  `runArgs: ["--env-file", ".env.local"]` loads the git-ignored `.env.local`
  (template: `.env.example`) into the container at create time, and every
  committed config references secrets by NAME only - bare `${VAR}` env maps
  in `.mcp.json`, parent-environment inheritance in `opencode.json`, and
  `env_vars` allow-lists in the codex managed block. Nothing writes a
  secret value to disk, and the doctor prints only variable names and
  set/unset state.
- Empirical stdio contract (verified with the installed clients): Claude
  Code and Nanocoder do not inherit arbitrary parent environment for stdio
  servers, so `.mcp.json` secret-driven entries carry explicit `env` maps.
  The map values must be BARE `${VAR}` references: VS Code converts only
  bare `${VAR}` in env values (not `${VAR:-default}`, not remote headers),
  Claude expands bare or defaulted forms, and Nanocoder's map presence
  triggers full `{...process.env}` inheritance. This is why `context7` is
  the local `context7-mcp` stdio server (key from env) rather than the
  hosted HTTP endpoint - no single remote shape works across all three
  clients. The shim rejects an unexpanded literal loudly, so a
  non-substituting client fails visibly instead of authenticating with
  garbage.
- One committed file, three clients: repo-root `.mcp.json` is read natively
  by Claude Code (project scope), Nanocoder (project scope), and the VS Code
  agent host. Remote entries carry BOTH `type` (Claude/VS Code) and
  `transport` (Nanocoder); Claude Code ignores the extra key (verified).
- OpenCode v2 reads `opencode.json` with the v2 schema (`mcp.servers.<name>`,
  `environment`, `disabled`) - not the v1 `mcp.<name>` shape.
- Codex has no env-expanding config format, so
  `.devcontainer/seed-mcp-config.sh` writes a marker-delimited managed block
  into `~/.codex/config.toml` (user-level: no project-trust prompt). Codex
  forwards a sanitized environment by default, so the block's
  secret-consuming entries declare `env_vars` allow-lists. The block is
  regenerated idempotently (a config that exists without the block is
  appended - that path must never be mistaken for a no-op); content outside
  the markers is preserved; unmanaged tables (including subtables) with
  managed names and corrupted blocks (begin marker without end marker) are
  refused instead of rewritten; CRLF-edited configs are handled. In install
  mode the doctor gates the exit status - MISSING is a failure, not a note.
- `.devcontainer/mcp-shims/sf-github-mcp.sh` renames the repo's
  `GITHUB_MCP_PAT` convention onto github-mcp-server's canonical
  `GITHUB_PERSONAL_ACCESS_TOKEN` at launch time and defaults
  `GITHUB_READ_ONLY=1` (opt out with `GITHUB_READ_ONLY=0`); with no token it
  fails loudly with an actionable message instead of starting unauthenticated.
- Install split follows the placement rules above: the Dockerfile installs
  the non-Node servers (github-mcp-server binary, checksum-verified against
  upstream `checksums.txt`; pipx `mcp-server-git` / `mcp-server-fetch`), and
  `.devcontainer/install-mcp-servers.sh` (post-create strict, post-start
  warn-only via `--update`) installs the npm ones with pinned concrete specs
  (`GODOT_MCP_NPM_SPEC`, `PLAYWRIGHT_MCP_NPM_SPEC`,
  `CONTEXT7_MCP_NPM_SPEC`); non-concrete overrides are rejected at startup
  because they would make the offline skip check permanently false. Offline
  skip logic compares npm's global state against the pinned spec - no
  registry probe. Readiness requires the bin to exist AND be executable.
- Playwright Chromium is installed (best-effort, install mode only,
  `SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1` to skip) with @playwright/mcp's own
  bundled playwright CLI, because its Chromium revision is independent of
  the repo's pinned `playwright` package used by the web-export smoke test
  (single pin site: `.github/actions/playwright-chromium`).
- `.devcontainer/install-godot-templates.sh` installs the web export
  templates so the repo's only export preset ("Web") works locally. The
  ~900 MB upstream archive is downloaded through a BuildKit cache mount and
  only `templates/web_*` is extracted; the target directory name is derived
  from the installed editor's own version string (`4.3.stable`), never from
  string-munging the release tag alone.

## Validation

After editing `.devcontainer/**`, run:

```powershell
pwsh -NoProfile -File scripts/agent-check.ps1
```

When feasible, also run:

```bash
bash .devcontainer/post-create.sh
```

The harness self-tests statically check the agent CLI installer (packages,
binaries, Node >= 22 guard, `--allow-scripts`, verification), parse-check the
shell scripts with `bash -n`, and simulate the PSReadLine assembly conflict
that previously made the PowerShell extension terminal noisy.

The harness also covers the MCP tooling: static completeness checks (managed
server set matches across `.mcp.json`, `opencode.json`, and the seeder;
pinned npm specs; shim rename/read-only defaults; Dockerfile pins and cache
mount; `.env.local` plumbing), a behavioral seeder suite (fresh seed,
idempotent skip, drift repair, unmanaged-conflict refusal, corrupted-block
refusal, and a canary-secret sweep proving values never reach output or
disk), and a behavioral installer suite against a hermetic fake npm (fresh
install, offline skip, strict/warn-only failure modes, and a canary check
that credentials never reach the npm process environment).

To validate the wiring with real clients after a rebuild:
`claude mcp list`, `codex mcp list`, `/mcp` in opencode and nanocoder, and
`godot --headless --export-release "Web" build/web/index.html` for the
templates.
