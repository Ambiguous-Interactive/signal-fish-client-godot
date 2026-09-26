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
  PowerShell, or the final remote user should be installed
  from `post-create.sh` or a helper it calls, unless the Dockerfile installs the
  dependency itself (it provides Python 3.12 via Ubuntu apt, so `RUN` steps may
  use it directly; PEP 668 is pre-unlocked via `/etc/pip.conf` to match CI's
  global-Python install path).
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
  PyYAML globally), and `.venv-ci` is rebuilt from scratch when missing or
  broken (`venv` cannot upgrade a venv whose interpreter symlink died, so the
  old tree is removed first) with the runtime (gdtoolkit, per ci.yml) and
  automation (PyYAML, per llm-harness.yml) requirements, so
  `scripts/run-runtime-checks.sh` and the harness share one local venv. Both
  heals are warn-only and never block attaching.
- Heavyweight downloads (apt archives/indexes, the Godot editor zip, the
  ~900 MB web export templates, pipx/pip wheels) ride BuildKit cache mounts,
  so warm rebuilds - including `--no-cache` ones - skip the re-downloads.
  The base image's `docker-clean` deletes `/var/cache/apt/archives/*.deb`
  after every apt operation, so the apt archives mount only works because
  the Dockerfile removes that hook first; the other mounts have no such
  in-image cleanup.
- The create-time env guard (`initializeCommand` in `devcontainer.json` +
  `.devcontainer/ensure-env-file.ps1`) materializes `.env.local` from
  `.env.example` on a fresh clone (docker `--env-file` fails the create when
  the file is absent); it never overwrites an existing file. It spawns `sh`
  on the host (so `sh` must be on the host PATH; the workspace folder rides
  in as `$0`, making quote-bearing paths safe), prefers the richer pwsh
  guard script when the host has it, and falls back to plain `cp`.
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

## Cross-tool contracts (verify empirically, pin with tests)

These failure classes were each found by an adversarial reviewer or a live
failure, fixed once, and pinned by a test. When touching this tooling,
assume the contract, then re-verify with the real tool:

- **Checksum identity.** `sha256sum -c` resolves the names listed in a
  checksums manifest against the downloaded file's own name. Download the
  asset under its canonical manifest name - never a shorthand like
  `tool.tar.gz` - or verification is impossible to pass (or silently
  vacuous). Pinned by a static suite assertion that the `--output` name
  equals the grepped manifest entry.
- **awk exit statuses are decided in END.** A main-rule `exit N` still runs
  the END block, and an `exit` there overrides the code. Compute a flag in
  the main rules and exit in END only. Also: mawk's alternation
  `sub(/a|b/, "", s)` can misfire where two sequential subs are exact -
  prefer two subs.
- **`node -e` argv slots.** `node -e 'script' a b` places script arguments
  at `process.argv[1]`/`[2]` as plain strings - not an object, and argv[0]
  is node itself.
- **MCP client environment contracts** (see "MCP Servers" above): Claude
  Code expands env maps but does not inherit arbitrary parent environment;
  Nanocoder keys full inheritance off the map's presence; VS Code converts
  only bare `${VAR}` in env values and nothing in remote headers; Codex
  forwards a sanitized environment unless `env_vars` allows names. Re-check
  these whenever a client ships a major release, and headless/container
  flags (`--headless`, `--no-sandbox`) whenever a GUI-adjacent server is
  added.
- **Root-created HOME paths.** A root RUN step that creates any path under
  the container user's HOME must chown the whole created subtree back
  (parent directories included) or later user-level writes fail with
  EACCES.
- **Docker strips full-line comments in a continued RUN.** The parser
  removes lines whose first non-space character is `#` before the shell
  runs, so shell-level simulations of the RUN text can disagree with what
  the build executes (a "broken" comment-in-continuation is a phantom,
  and a comment inside a quoted word list vanishes rather than leaking).
  Extract-and-run checks must account for the parser step.
- **WSL bash.exe appends the Windows PATH after the Linux PATH.** A
  Windows-side `$env:PATH` prepend loses inside WSL bash, so host tools
  beat harness sandbox fakes (hermetic suites would run real npm/gh or
  vacuously pass). The harness pins sandbox bins via `BASH_ENV` (bash
  sources it in every non-interactive shell); `Set-WslBashSandboxPath` in
  `scripts/test-llm-harness.ps1` is the single mechanism - keep new
  bash-spawning suites on it. Register EVERY custom variable a suite
  expects to read inside bash via `Add-EnvToWslPassthrough` (not only
  path-like ones): an unregistered var is silently empty under the
  WSLENV-filtered boundary and the suite fails or passes vacuously with
  no pointer at the cause.

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
