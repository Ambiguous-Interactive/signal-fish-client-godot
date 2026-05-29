---
description: Use when changing the VS Code dev container, installed tools, shell profiles, or post-create setup.
triggers: devcontainer, container, codex, cli, post-create, postcreate, powershell profile, pwsh profile, PSReadLine, toolchain
category: Tooling
---

# Dev Container Tooling

## Trigger

Use this skill when changing `.devcontainer/**`, installed command-line tools,
PowerShell profile behavior, or post-create setup.

## Placement Rules

- The Dockerfile runs before devcontainer features. Tools that depend on Node,
  PowerShell, Python feature state, or the final remote user should be installed
  from `post-create.sh` or a helper it calls, unless the Dockerfile installs the
  dependency itself.
- Keep command-line tool installs idempotent and pinned by default. Allow an
  environment override only when the default remains a concrete version.
- Never automate interactive authentication. Install the CLI and verify a
  non-interactive command such as `--version`; let users sign in later.

## Current Guarantees

- OpenAI Codex CLI is installed by `.devcontainer/install-codex.sh` using the
  official npm package `@openai/codex` and the pinned `CODEX_CLI_VERSION`.
- `post-create.sh` invokes the Codex installer after the Node feature has made
  `node` and `npm` available, then includes `codex --version` in the toolchain
  summary.
- `post-create.sh` repairs root-owned mounted directories such as
  `/commandhistory`, installs the direct `.git/hooks/pre-commit` shim via
  `scripts/install-git-hooks.ps1 -Force`, and does not install the slower
  pre-commit framework hook.
- The Codex installer derives npm's global prefix, prepends its `bin` directory
  to `PATH`, and fails loudly if `codex --version` does not report the pinned
  version. npm registry failures are setup failures, not silent warnings.
- npm cache lives under the container user's home directory and is not mounted
  as a named volume by this repo, so cache ownership repair is not part of the
  devcontainer contract.
- `.devcontainer/pwsh-profile.ps1` is best-effort terminal polish. It must not
  emit errors if PSReadLine is already loaded, preloaded as an assembly by the
  VS Code PowerShell extension, missing, or too old for optional settings.

## Validation

After editing `.devcontainer/**`, run:

```powershell
pwsh -NoProfile -File scripts/agent-check.ps1
```

When feasible, also run:

```bash
bash .devcontainer/post-create.sh
```

The harness self-tests statically check the Codex installer, parse-check the
shell scripts with `bash -n`, and simulate the PSReadLine assembly conflict
that previously made the PowerShell extension terminal noisy.
