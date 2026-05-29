# Dev Container — Signal Fish Godot Client

A reproducible, batteries-included VS Code dev environment for working on the
Signal Fish Godot client. Built on Ubuntu 24.04 with Godot 4 (headless),
PowerShell 7, Python, Node LTS, and a curated set of reputable extensions.

## Quick start

1. Install [Docker](https://www.docker.com/) and the
   [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   extension for VS Code.
2. Open this repository in VS Code.
3. When prompted, choose **Reopen in Container**. (Or run the
   `Dev Containers: Reopen in Container` command.)

First build pulls the base image, installs system libs, and downloads the
pinned Godot release; subsequent starts are fast.

The direct `.git/hooks/pre-commit` shim installed by post-create is canonical.
The `pre-commit` CLI is present only as optional compatibility tooling for
manual `.pre-commit-config.yaml` runs.

## What's inside

| Tool        | Version / Source                                    |
| ----------- | --------------------------------------------------- |
| OS          | Ubuntu 24.04 (`mcr.microsoft.com/devcontainers/base`) |
| Godot       | `4.3-stable` editor binary (run headless via `--headless`) |
| PowerShell  | 7.x via `ghcr.io/devcontainers/features/powershell` |
| Python      | 3.12 via devcontainer feature                       |
| Node.js     | LTS via devcontainer feature                        |
| Codex CLI   | Pinned `@openai/codex` npm package via post-create  |
| GitHub CLI  | Latest via devcontainer feature                     |
| Git hooks   | Direct `.git/hooks/pre-commit` shim via post-create |
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
- **Theme:** `github.github-vscode-theme` (GitHub Dark Default)
- **Icons:** `pkief.material-icon-theme`, `oderwat.indent-rainbow`

## Forwarded ports

| Port | Purpose                |
| ---- | ---------------------- |
| 6005 | Godot LSP server       |
| 6006 | Godot debugger         |
| 6007 | Godot debugger (alt)   |

## Files

- [`devcontainer.json`](./devcontainer.json) — features, extensions, settings
- [`Dockerfile`](./Dockerfile) — base image and Godot install
- [`install-godot.sh`](./install-godot.sh) — deterministic Godot download
- [`install-codex.sh`](./install-codex.sh) — pinned OpenAI Codex CLI install
- [`post-create.sh`](./post-create.sh) — git hooks + Codex + toolchain summary

## Local font tip

The default editor/terminal font stack prefers
[FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads). Install it on
your **host** for the best appearance — the container does not need the font.

## Updating Godot

Bump `GODOT_VERSION` in [`devcontainer.json`](./devcontainer.json) (and the
matching arg in [`Dockerfile`](./Dockerfile)). Rebuild the container via
`Dev Containers: Rebuild Container`.

## Updating Codex CLI

Codex CLI is installed by [`install-codex.sh`](./install-codex.sh) through the
official npm package, `@openai/codex`. Bump `CODEX_CLI_VERSION` in that script,
rebuild the container, and confirm the post-create toolchain summary reports the
new `codex --version` output.

Codex authentication is intentionally not automated. Run `codex` interactively
inside the container and sign in with ChatGPT or configure an API key according
to the OpenAI docs.

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
- **`codex` is missing after rebuild:** run `bash .devcontainer/post-create.sh`
  and check the `==> Installing Codex CLI` section for npm or PATH errors. If
  npm installs successfully but `codex` is still not found, compare
  `npm config get prefix` with `$PATH`; the installer prepends the expected
  npm global `bin` directory during setup.
