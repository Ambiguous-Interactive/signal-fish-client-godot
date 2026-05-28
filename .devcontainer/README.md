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

## What's inside

| Tool        | Version / Source                                    |
| ----------- | --------------------------------------------------- |
| OS          | Ubuntu 24.04 (`mcr.microsoft.com/devcontainers/base`) |
| Godot       | `4.3-stable` editor binary (run headless via `--headless`) |
| PowerShell  | 7.x via `ghcr.io/devcontainers/features/powershell` |
| Python      | 3.12 via devcontainer feature                       |
| Node.js     | LTS via devcontainer feature                        |
| GitHub CLI  | Latest via devcontainer feature                     |
| pre-commit  | Installed via `pipx`, hooks installed automatically |

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
- [`post-create.sh`](./post-create.sh) — pipx + pre-commit + toolchain summary

## Local font tip

The default editor/terminal font stack prefers
[FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads). Install it on
your **host** for the best appearance — the container does not need the font.

## Updating Godot

Bump `GODOT_VERSION` in [`devcontainer.json`](./devcontainer.json) (and the
matching arg in [`Dockerfile`](./Dockerfile)). Rebuild the container via
`Dev Containers: Rebuild Container`.

## Troubleshooting

- **Pre-commit hooks fail with `pwsh: not found`:** rebuild the container; the
  PowerShell feature install may have been skipped.
- **Godot LSP not connecting:** confirm port 6005 is forwarded and that
  `godotTools.editorPath.godot4` points to `/usr/local/bin/godot`.
- **Permission errors on mounted volumes:** run
  `Dev Containers: Rebuild Without Cache`.
