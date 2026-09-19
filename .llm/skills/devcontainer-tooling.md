---
description: Use when changing the VS Code dev container, installed tools, shell profiles, or post-create/post-start setup.
triggers: devcontainer, container, codex, opencode, nanocoder, claude, agent cli, cli, post-create, postcreate, post-start, poststart, powershell profile, pwsh profile, PSReadLine, toolchain
category: Tooling
---

# Dev Container Tooling

## Trigger

Use this skill when changing `.devcontainer/**`, installed command-line tools,
PowerShell profile behavior, or post-create/post-start setup.

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

- The four terminal agent CLIs — OpenAI Codex (`@openai/codex`), OpenCode
  (`opencode-ai`), Nanocoder (`@nanocollective/nanocoder`), and Claude Code
  (`@anthropic-ai/claude-code`) — are installed by
  `.devcontainer/install-agent-tools.sh` into npm's global prefix.
- `post-create.sh` invokes the installer strictly after the Node feature has
  made `node` (>= 22) and `npm` available, then verifies each of the four
  binaries is on PATH and includes all four versions in the toolchain summary.
  Any install or verification failure fails post-create.
- `post-start.sh` runs on every container start/attach: it re-applies the git
  `safe.directory` trust and re-runs the installer with `--update`, which
  probes the registry in parallel and reinstalls only outdated or missing
  CLIs. `--update` is warn-only: a registry outage degrades to the installed
  toolchain and never blocks attaching.
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
  line is reported as the diagnostic — how the `~/.cache` EACCES class of
  failure is diagnosed), exit 0 with no output means missing, and only exit
  0 with output counts as ready (stderr is consulted when stdout is empty,
  because some CLIs print their version there). Merging the streams and
  treating any non-empty line as a version once marked dying binaries as
  ready; the harness self-tests now reject that pattern.
- The installer derives npm's global prefix, prepends its `bin` directory to
  PATH, and passes npm 11's `--allow-scripts` (npm blocks lifecycle scripts on
  global installs by default; `opencode-ai` needs its postinstall to select
  the platform binary). The flag is only passed on npm >= 11; npm 10 (bundled
  with Node 22) predates the policy and runs scripts as before. Specs are
  overridable via `CODEX_NPM_SPEC`, `OPENCODE_NPM_SPEC`, `NANOCODER_NPM_SPEC`,
  and `CLAUDE_NPM_SPEC`; `AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS` (default 5000)
  bounds only the registry version probe, not the install itself.
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
