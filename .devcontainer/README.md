# Dev Container - Signal Fish Godot Client

A reproducible, batteries-included VS Code dev environment for working on the
Signal Fish Godot client. Built on Ubuntu 24.04 with Godot 4 (headless),
PowerShell 7, Python, Node LTS, and a curated set of reputable extensions and
themes.

## Quick start

1. Install [Docker](https://www.docker.com/) and the
   [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   extension for VS Code.
2. Create your local secrets file (the container load step fails without
   it): `cp .env.example .env.local`, then fill in the values you want.
   `.env.local` is git-ignored.
3. Open this repository in VS Code.
4. When prompted, choose **Reopen in Container**. (Or run the
   `Dev Containers: Reopen in Container` command.)

First build pulls the base image, installs system libs, downloads the pinned
Godot release and web export templates, and provisions the agent CLIs and
MCP servers; subsequent starts are fast (the ~900 MB template archive is
cached across builds by a BuildKit cache mount).

The direct Git hook installed by post-create is canonical. Its path is resolved
with `git rev-parse --git-path hooks`, so linked worktrees do not assume `.git`
is a directory. The `pre-commit` CLI is present only as optional compatibility
tooling for manual `.pre-commit-config.yaml` runs.

## What's inside

| Tool        | Version / Source                                    |
| ----------- | --------------------------------------------------- |
| OS          | Ubuntu 24.04 (`mcr.microsoft.com/devcontainers/base`) |
| Godot       | `4.3-stable` editor binary (run headless via `--headless`) plus web export templates |
| PowerShell  | 7.x via `ghcr.io/devcontainers/features/powershell` |
| Python      | 3.12 via devcontainer feature                       |
| Node.js     | LTS via devcontainer feature (>= 22 required)       |
| Agent CLIs  | `codex`, OpenCode v2, `nanocoder`, `claude` at `@latest`; installed at create and refreshed at start |
| MCP servers | `godot`, `github`, `context7`, `deepwiki`, `git`, `fetch`, `playwright` - see "MCP servers" below |
| GitHub CLI  | Latest via devcontainer feature                     |
| Git hooks   | Direct `git rev-parse --git-path hooks` shim via post-create |
| pre-commit  | Optional compatibility CLI; no framework hook install |

## Extensions

Only reputable, well-maintained extensions are pre-installed:

- **Godot:** `geequlim.godot-tools` (official Godot Tools)
- **PowerShell:** `ms-vscode.powershell` (Microsoft)
- **YAML:** `redhat.vscode-yaml` (Red Hat)
- **TOML:** `tamasfe.even-better-toml`
- **EditorConfig:** `editorconfig.editorconfig`
- **Markdown:** `davidanson.vscode-markdownlint`, `yzhang.markdown-all-in-one`
- **Spell check:** `streetsidesoftware.code-spell-checker`
- **Inline diagnostics:** `usernamehw.errorlens`
- **Git:** `eamodio.gitlens`, `mhutchie.git-graph`
- **GitHub:** `github.vscode-github-actions`,
  `github.vscode-pull-request-github`, `github.remotehub`
- **AI assistants (require a subscription or account; install will succeed
  but the assistant features are gated by sign-in):**
  `github.copilot-chat`, `openai.chatgpt`, `anthropic.claude-code`
- **Theme library:** default `(Modern) Godot Theme VSCode Breeze Dark` from
  `javier-garrido-galdon.godot-theme-vscode`, plus Godot-specific and
  general-purpose alternatives listed below
- **Icons:** `pkief.material-icon-theme`, `vscode-icons-team.vscode-icons`,
  `miguelsolorio.fluent-icons`
- **Visual polish:** `oderwat.indent-rainbow`

### Theme options

The default theme is intentionally Godot-centric and a little underdog:
`(Modern) Godot Theme VSCode Breeze Dark` from
`javier-garrido-galdon.godot-theme-vscode`. Its Marketplace package is MIT
licensed, recently maintained, and tuned for GDScript when paired with Godot
Tools.

The container also installs a broad theme library so contributors can switch
without waiting on extension installs:

| Group | Extensions |
| ----- | ---------- |
| Godot-focused | `javier-garrido-galdon.godot-theme-vscode`, `MrPogofu.true-godot`, `ryanabx.godot-vscode-theme` |
| Core dark staples | `github.github-vscode-theme`, `dracula-theme.theme-dracula`, `Catppuccin.catppuccin-vsc`, `enkia.tokyo-night`, `zhuangtongfa.Material-theme`, `akamud.vscode-theme-onedark`, `sdras.night-owl`, `arcticicestudio.nord-visual-studio-code` |
| Distinctive palettes | `BeardedBear.beardedtheme`, `johnpapa.winteriscoming`, `jdinhlife.gruvbox`, `teabyii.ayu`, `wesbos.theme-cobalt2`, `fisheva.eva-theme`, `miguelsolorio.min-theme`, `DaltonMenezes.aura-theme`, `rocketseat.theme-omni`, `PawelBorkar.jellyfish` |
| Dark/light options | `uloco.theme-bluloco-dark`, `uloco.theme-bluloco-light`, plus light variants bundled by GitHub Theme and Catppuccin |
| Icon/product icon themes | `pkief.material-icon-theme`, `vscode-icons-team.vscode-icons`, `miguelsolorio.fluent-icons` |

Switch color themes with the `Preferences: Color Theme` command.

## Forwarded ports

| Port | Purpose                |
| ---- | ---------------------- |
| 6005 | Godot LSP server       |
| 6006 | Godot debugger         |
| 6007 | Godot debugger (alt)   |

## Files

- [`devcontainer.json`](./devcontainer.json) - features, extensions, settings
- [`Dockerfile`](./Dockerfile) - base image, Godot install, MCP binaries
- [`install-godot.sh`](./install-godot.sh) - deterministic Godot download
- [`install-godot-templates.sh`](./install-godot-templates.sh) - web export templates (cache-mounted download, web-only extraction)
- [`install-agent-tools.sh`](./install-agent-tools.sh) - agent CLI install/refresh
- [`install-mcp-servers.sh`](./install-mcp-servers.sh) - npm MCP server install/refresh
- [`seed-mcp-config.sh`](./seed-mcp-config.sh) - Codex managed block + MCP doctor
- [`mcp-shims/sf-github-mcp.sh`](./mcp-shims/sf-github-mcp.sh) - GitHub MCP launcher shim
- [`post-create.sh`](./post-create.sh) - git hooks + agent CLIs + MCP servers + toolchain summary
- [`post-start.sh`](./post-start.sh) - git trust + best-effort agent CLI
  refresh + MCP server refresh + Python automation deps (PyYAML user-site
  plus a complete `.venv-ci`, matching CI so both local gates are green out
  of the box)

## Local font tip

The default editor/terminal font stack prefers
[FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads). Install it on
your **host** for the best appearance - the container does not need the font.

## Updating Godot

Bump `GODOT_VERSION` in [`devcontainer.json`](./devcontainer.json) (and the
matching arg in [`Dockerfile`](./Dockerfile)). Rebuild the container via
`Dev Containers: Rebuild Container`; the web export templates are installed
for the new version automatically. CI's Godot matrix
(`.github/workflows/ci.yml`) is the compatibility bar; the dev container
tracks the project's target version (`config/features` in
`project.godot`).

## Agent CLIs (codex, opencode, nanocoder, claude)

The four terminal agent CLIs are installed by
[`install-agent-tools.sh`](./install-agent-tools.sh) through their official
npm packages at `@latest`. OpenCode v2 uses `@opencode/cli`; the installer
stages it in an isolated npm prefix and verifies the candidate binary reports
major version 2 before replacing the package-managed v1 `opencode-ai`. If
activation fails, v1 is restored when possible; a failed restoration is a
strict failure and a warn-only update failure. Each CLI's spec is
overridable, e.g.
`CODEX_NPM_SPEC="@openai/codex@0.135.0"`, but the defaults track `@latest`
because these CLIs publish several times a day. The registry version probe
is bounded by `AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS` (default 5000) so an
offline start fails fast; the package install itself uses npm's defaults.
The delay between failed install retries is
`AGENT_TOOLS_RETRY_SLEEP_MS` (default 2000; the hermetic fake-npm test
matrix sets 0).

- **post-create** installs (or refreshes) all four and fails loudly on any
  error; the toolchain summary then reports every version and OpenCode must
  report major version 2.
- **post-start** re-checks versions on every successful container start and
  reinstalls only what is outdated or missing. This refresh is warn-only: a
  registry outage leaves the installed toolchain in place and never blocks
  attaching.

Authentication is intentionally not automated. Run each CLI interactively
inside the container and sign in according to its vendor's docs.

## MCP servers

Seven MCP servers are wired into every agent CLI (claude, opencode v2,
nanocoder, codex, and the VS Code agent host):

| Server    | What it does | Source |
| --------- | ------------ | ------ |
| `godot`   | Launch/run the project headless, capture debug output, scene ops; drives the installed editor via `GODOT_PATH=/usr/local/bin/godot` | [`@coding-solo/godot-mcp`](https://github.com/Coding-Solo/godot-mcp) (pinned npm) |
| `github`  | Official GitHub API tools; **read-only by default** | [`github-mcp-server`](https://github.com/github/github-mcp-server) binary (pinned, checksum-verified) |
| `context7`| Up-to-date library documentation | [`@upstash/context7-mcp`](https://github.com/upstash/context7) (pinned npm, local stdio) |
| `deepwiki`| Q&A over public GitHub repositories | remote `https://mcp.deepwiki.com/mcp` (no auth) |
| `git`     | Read/search git repositories | `mcp-server-git` (pipx, pinned) |
| `fetch`   | Fetch web pages as markdown | `mcp-server-fetch` (pipx, pinned) |
| `playwright` | Drive Chromium for web-export debugging | [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) (pinned npm) |

### Where the configuration lives

- **`.mcp.json`** (repo root, committed) - one file, three clients: Claude
  Code (project scope), Nanocoder (project scope), and the VS Code agent
  host all read it natively. Remote entries carry both `type` (Claude /
  VS Code) and `transport` (Nanocoder) so the shared file works everywhere.
  Every secret-driven server is a **local stdio server with an explicit
  `env` map** whose values are name-only `${VAR:-}` references: Claude Code
  and Nanocoder were verified not to inherit arbitrary parent environment
  for stdio servers, and VS Code does not substitute variables in remote
  headers - explicit env maps are the one shape that works everywhere
  (Nanocoder keys full environment inheritance off the map's presence).
  A server that receives an unexpanded `${VAR...}` literal fails loudly
  rather than authenticating with garbage.
- **`opencode.json`** (repo root, committed) - OpenCode v2 schema
  (`mcp.servers.<name>`; note this is not the v1 `mcp.<name>` shape).
- **`~/.codex/config.toml`** - Codex has no env-expanding config format, so
  `seed-mcp-config.sh` writes a marker-delimited managed block there
  (user-level, so no project-trust prompt); secret-consuming entries use
  `env_vars` allow-lists since Codex forwards a sanitized environment. The
  block is regenerated idempotently on every create/start; content outside
  the markers is preserved; conflicting or corrupted blocks are refused,
  never rewritten.

### Secrets: names in files, values in the environment

Secret values never appear in any configuration file or script output:

1. `runArgs: ["--env-file", ".env.local"]` loads your git-ignored
   `.env.local` (create it from `.env.example`) into the container
   environment at container create time.
2. Committed configs reference the variable **names** only. In
   `.mcp.json`, secret-driven servers are local stdio entries with an
   explicit `env` map using bare `${VAR}` references - the one shape all
   three clients resolve (VS Code only converts bare `${VAR}` in env
   values, not `${VAR:-default}` and not remote headers). `opencode.json`
   needs no maps because OpenCode inherits the parent environment for
   local servers. The codex managed block uses `env_vars` allow-lists
   because Codex forwards a sanitized environment.
3. The GitHub server goes through the `sf-github-mcp` shim, which maps
   `GITHUB_MCP_PAT` onto the binary's canonical
   `GITHUB_PERSONAL_ACCESS_TOKEN` at launch time and defaults
   `GITHUB_READ_ONLY=1`. The `GITHUB_READ_ONLY=0` / `GITHUB_TOOLSETS`
   opt-outs reach the server on opencode, nanocoder, the VS Code agent
   host, and codex (allow-list); Claude Code substitutes only the mapped
   variables, so it always uses the read-only default. Grant the PAT
   only the scopes you need.
4. `seed-mcp-config.sh`'s doctor prints variable names and set/unset state
   only - never values. The harness self-tests enforce this with canary
   secrets.

### Lifecycle

- **post-create** installs the npm servers strictly
  (`install-mcp-servers.sh`) and seeds the configurations
  (`seed-mcp-config.sh`); failures fail the build.
- **post-start** refreshes both warn-only (`--update`), so an outage never
  blocks attaching. The npm installer's specs are pinned concrete versions
  (overridable via `GODOT_MCP_NPM_SPEC` / `PLAYWRIGHT_MCP_NPM_SPEC` /
  `CONTEXT7_MCP_NPM_SPEC`), and "already current" is decided offline from
  npm's own state - no registry probe needed.
- Chromium for `playwright` is downloaded best-effort during post-create
  (skip with `SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1`); it uses @playwright/mcp's
  bundled playwright CLI because its Chromium revision is independent of the
  repo's pinned `playwright` package used by the web-export smoke test.

### Verifying with real clients

```bash
claude mcp list            # health-checks every server
codex mcp list             # shows the managed block entries
godot --headless --export-release "Web" build/web/index.html  # templates
```

Use `/mcp` inside opencode and nanocoder. First use of `.mcp.json` servers
prompts once for approval in Claude Code / VS Code; Context7 works without
an API key at anonymous rate limits and picks up `CONTEXT7_API_KEY` from
its environment (prefer the hosted endpoint at `https://mcp.context7.com/mcp`
if you want to skip the local server - configure it per client, since the
local one is what the shared file ships).

## Troubleshooting

- **Container fails to create with `env file ... not found`:** create the
  secrets file: `cp .env.example .env.local` (`.env.local` is git-ignored;
  see "MCP servers" above).
- **Changed a value in `.env.local` but the container kept the old one:**
  the env file is read by Docker at container *create* time - use
  **Rebuild Container** (or Dev Containers: Rebuild Without Cache);
  a plain reload/restart will not re-read it.
- **`sf-github-mcp: no token found`:** set `GITHUB_MCP_PAT` in `.env.local`
  and rebuild; the server refuses to start without a token rather than
  running unauthenticated.
- **Godot export says templates are missing:** rebuild the container so
  `install-godot-templates.sh` runs for the current `GODOT_VERSION`;
  templates land in `~/.local/share/godot/export_templates/<version>/` and
  the directory name is derived from the installed editor itself.
- **`seed-mcp-config.sh` reports a conflict in `~/.codex/config.toml`:**
  either remove your own `[mcp_servers.<name>]` tables that collide with the
  managed set or delete the managed block; then rerun
  `bash .devcontainer/seed-mcp-config.sh`.
- **Git hooks fail with `pwsh: not found`:** rebuild the container; the
  PowerShell feature install may have been skipped.
- **Godot LSP not connecting:** confirm port 6005 is forwarded and that
  `godotTools.editorPath.godot4` points to `/usr/local/bin/godot`.
- **Permission errors on mounted volumes:** run
  `Dev Containers: Rebuild Without Cache`.
- **PowerShell terminal reports a PSReadLine assembly already loaded error:**
  rebuild the container so the guarded profile from `pwsh-profile.ps1` is
  copied into `$HOME/.config/powershell/profile.ps1`.
- **An agent CLI (`codex`/`opencode`/`nanocoder`/`claude`) is missing after
  rebuild:** run `bash .devcontainer/post-create.sh` and check the
  `==> Installing agent CLIs` section for npm or PATH errors. The installer
  requires Node.js >= 22 and a writable npm global prefix; if npm installs
  successfully but a CLI is still not found, compare `npm config get prefix`
  with `$PATH` - the installer prepends the expected npm global `bin`
  directory during setup.
