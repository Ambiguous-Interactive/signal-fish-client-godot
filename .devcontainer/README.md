# Dev Container - Signal Fish Godot Client

A reproducible, batteries-included VS Code dev environment for working on the
Signal Fish Godot client. Built on Ubuntu 24.04 with Godot 4 (headless),
PowerShell 7, Python, Node LTS, and a curated set of reputable extensions and
themes.

## Quick start

1. Install [Docker](https://www.docker.com/) and the
   [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   extension for VS Code.
2. Open this repository in VS Code.
3. When prompted, choose **Reopen in Container**. (Or run the
   `Dev Containers: Reopen in Container` command.)

First build pulls the base image, installs system libs, and downloads the
pinned Godot release; subsequent starts are fast.

The direct Git hook installed by post-create is canonical. Its path is resolved
with `git rev-parse --git-path hooks`, so linked worktrees do not assume `.git`
is a directory. The `pre-commit` CLI is present only as optional compatibility
tooling for manual `.pre-commit-config.yaml` runs.

## What's inside

| Tool        | Version / Source                                    |
| ----------- | --------------------------------------------------- |
| OS          | Ubuntu 24.04 (`mcr.microsoft.com/devcontainers/base`) |
| Godot       | `4.3-stable` editor binary (run headless via `--headless`) |
| PowerShell  | 7.x via `ghcr.io/devcontainers/features/powershell` |
| Python      | 3.12 via devcontainer feature                       |
| Node.js     | LTS via devcontainer feature (>= 22 required)       |
| Agent CLIs  | `codex`, OpenCode v2, `nanocoder`, `claude` at `@latest`; installed at create and refreshed at start |
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
- [`Dockerfile`](./Dockerfile) - base image and Godot install
- [`install-godot.sh`](./install-godot.sh) - deterministic Godot download
- [`install-agent-tools.sh`](./install-agent-tools.sh) - agent CLI install/refresh
- [`post-create.sh`](./post-create.sh) - git hooks + agent CLIs + toolchain summary
- [`post-start.sh`](./post-start.sh) - git trust + best-effort agent CLI refresh

## Local font tip

The default editor/terminal font stack prefers
[FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads). Install it on
your **host** for the best appearance - the container does not need the font.

## Updating Godot

Bump `GODOT_VERSION` in [`devcontainer.json`](./devcontainer.json) (and the
matching arg in [`Dockerfile`](./Dockerfile)). Rebuild the container via
`Dev Containers: Rebuild Container`.

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

- **post-create** installs (or refreshes) all four and fails loudly on any
  error; the toolchain summary then reports every version and OpenCode must
  report major version 2.
- **post-start** re-checks versions on every successful container start and
  reinstalls only what is outdated or missing. This refresh is warn-only: a
  registry outage leaves the installed toolchain in place and never blocks
  attaching.

Authentication is intentionally not automated. Run each CLI interactively
inside the container and sign in according to its vendor's docs.

## Troubleshooting

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
