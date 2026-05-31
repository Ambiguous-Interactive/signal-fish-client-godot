---
description: Central AI context for Signal Fish Godot client work.
triggers: agent, llm, context, godot, signal fish, client, runtime client, SignalFishClient, connect, connection, Godot 3, Godot 4, browser export, protocol fixture
category: Core
---

# Signal Fish Godot Client AI Context

This repository contains Godot bindings for the Signal Fish protocol. Treat
this file as the canonical AI context; vendor-specific agent files should only
point here unless a tool requires a tiny wrapper format.

## Project Intent

- Build a GDScript-first Signal Fish client intended to work across major
  Godot versions once compatibility is validated.
- Prioritize Godot 4 and web exports, where C# is not available.
- Keep protocol behavior aligned with:
  - <https://github.com/Ambiguous-Interactive/signal-fish-cloud>
  - <https://github.com/Ambiguous-Interactive/signal-fish-server>
  - <https://github.com/Ambiguous-Interactive/signal-fish-client-rust>
- Keep AI-facing context concise; split Markdown details into `.llm/skills`,
  `.llm/code-samples`, and `.llm/research`.

## Working Rules

- Read this file, then open only the specific skill or reference files that
  match the current task.
- Keep `.llm` Markdown files and known pointer files at or below 300 lines.
- Add `description`, `triggers`, and `category` frontmatter to every `.llm`
  Markdown file except generated `.llm/index.md`.
- Update generated indexes after adding, removing, or renaming `.llm`
  Markdown files.
- Prefer Godot-native APIs and GDScript examples over C# assumptions.
- Keep web export constraints visible in networking, crypto, threading, and
  file-system decisions.
- Do not invent protocol details. Anchor concrete wire, auth, and reconnect
  semantics to upstream paths and commits before runtime implementation.
- After editing any `.ps1`, `.psm1`, `.psd1`, or `.llm/**` file, run
  `pwsh -NoProfile -File scripts/agent-check.ps1` and resolve every reported
  issue before continuing or proposing a commit. This is the same validation
  the pre-commit hook and CI run; running it locally turns hook failures
  into fast in-loop feedback.

## Runtime Implementation Checklist

Before coding the first runtime client:

- Start with `.llm/skills/architectural-planning.md` for public API, state,
  boundaries, and verification shape.
- Use `.llm/skills/signal-fish-protocol.md` before defining wire messages,
  auth, reconnect, close, or error semantics.
- Use `.llm/skills/godot-gdscript.md` for `SignalFishClient`, signals, addon
  layout, and GDScript API shape.
- Use `.llm/skills/godot-transport.md` for `WebSocketPeer`, polling, close
  handling, backpressure, and transport adapter boundaries.
- Use `.llm/skills/web-export.md` for browser export, `Origin`, mixed-content,
  storage, and TLS constraints.
- Use `.llm/skills/testing-automation.md` for protocol fixtures, fake transport
  tests, smoke checks, generated files, and CI.
- Use `.llm/skills/security-privacy.md` before handling tokens, secrets, logs,
  persistence, or browser-visible identifiers.

MVP rule: implement Godot 4 first. Add Godot 3 only after a separate
compatibility decision and smoke tests for the `WebSocketClient` adapter path.

Definition of done for the first usable client:

- Protocol fixtures are pinned to upstream Signal Fish paths and commits.
- Fake transport tests cover connect, receive, send, close, error, reconnect,
  and backpressure behavior before live network tests.
- Close codes, close reasons, failures, and cleanup are surfaced through the
  documented Godot API.
- Godot 4 smoke test passes with the `WebSocketPeer` adapter.
- Browser export manual check covers HTTPS hosting, `wss://`, WebSocket
  `Origin`, mixed-content rejection, and no native-only socket assumptions.

## Repository Layout

- `.llm/context.md`: this canonical context file.
- `.llm/index.md`: generated inventory of AI context Markdown files.
- `.llm/skills`: task-triggered guidance with metadata.
- `.llm/code-samples`: compact implementation examples.
- `.llm/research`: curated notes and upstream links.
- `scripts/generate-llm-index.ps1`: thin wrapper around shared generator
  functions that regenerate `.llm/index.md` and this file's generated section.
- `scripts/lint-llm.ps1`: thin wrapper around shared linter functions that
  enforce line limits, metadata, pointers, and index freshness.
- `scripts/run-llm-hooks.ps1`: single entry point invoked by the installed
  pre-commit shim (from `git rev-parse --git-path hooks`) and by CI. Modes are
  `PreCommit` (staged-aware fast path with AutoFix), `AgentFast`
  (non-mutating fast path), `Full` (structural plus behavioral self-tests), and
  `CI` (`Full` plus loud generated diff verification). Fast modes use
  in-process parse/static guards; `Full` and `CI` run `preflight.ps1`. Use
  `-Profile` when changing hook performance.
- `scripts/install-git-hooks.ps1`: materializes a portable POSIX-sh shim
  (`#!/usr/bin/env sh`) into the hook directory resolved by `git rev-parse
  --git-path hooks` (usually `.git/hooks/pre-commit`). Sh is available on
  Linux, macOS, and Windows (Git for Windows bundles `sh.exe`); a pwsh shebang
  would break on Windows because `pwsh -File` refuses extensionless files. The
  committed `.githooks/pre-commit*` files are reference templates only; the live
  hook lives in the resolved git hooks directory after running the installer.
  The installer clears legacy `core.hooksPath` values that normalize to
  `.githooks`, including trailing slash or backslash variants, and warns before
  leaving foreign hook paths in place unless `-Force` is used.
- `scripts/agent-check.ps1`: fast post-edit validator for agents and humans.
  It invokes `run-llm-hooks.ps1 -Mode AgentFast -SkipStagedCheck -NoAutoFix`
  in the same PowerShell process; pass `-Full` for exhaustive behavioral tests.
- `scripts/check-gdscript-private-helpers.py`: gdtoolkit-parser static guard
  for unreachable private GDScript helper chains and cold-cache-fragile
  self-`class_name` references; runtime CI runs it with `--self-test` before
  protocol fixtures.
- `scripts/run-runtime-checks.sh`: shared runtime validation entry point used
  by CI and local checks. It sets a deterministic writable `HOME` for
  tool caches, activates `.venv-ci` when present, and runs Godot from a
  temporary project copy that excludes `.godot` so local runs exercise the same
  cold-cache path as CI. Subcommands are `all`, `private-helpers`, `format`,
  `lint`, and `godot`.
- `scripts/validate-github-config.py`: deterministic local validator for
  GitHub workflows and Dependabot config. It rejects duplicate YAML keys,
  `gh api --slurp` combined with `--jq`, unsafe workflow triggers or
  permissions, drift between required auto-merge workflows and actual
  workflow names, CRLF shebangs in the auto-merge script, and grouped
  `devcontainers` Dependabot updates.
- `scripts/preflight.ps1`: self-healing bootstrap. Parse-checks itself
  first, then every tracked `.ps1`/`.psm1`/`.psd1`. `-AutoFix` recovers
  corrupted sources via the index/staged copy first, falling back to
  `git checkout HEAD -- <path>`, and backs up the corrupt working-tree copy
  plus any staged/index copy under `git rev-parse --git-path
  preflight-recovery` first (most recent 20 retained). See
  `.llm/skills/agent-harness.md` "Recovery From AutoFix" for the full backup
  naming scheme and the restore recipe. `run-llm-hooks.ps1 -Mode Full`, CI,
  `agent-check.ps1 -Full`, and the Claude Code `Stop` hook run it before
  downstream validation; fast modes use in-process parse/static guards instead
  of spawning preflight.
- `scripts/test-llm-harness.ps1`: dependency-free self-tests for the shared
  harness library and hook wiring.
- `scripts/lib/LlmHarness.psm1`: shared module (frontmatter parsing, cached
  Markdown inventory, generated content, linter checks, path helpers, and
  staging-artifact discovery) imported by the generator, linter, hook runner,
  and tests.
- `.claude/settings.json` + `.claude/hooks/*.ps1`: agentic guardrails.
  `PostToolUse` parse-checks every `.ps1`/`.psm1`/`.psd1` write/edit and
  runs a fast per-file `.llm` structural validator after `.llm/**` edits;
  `Stop` runs preflight; `SessionStart` emits a one-shot reminder.
  Tracked scripts with shebangs are forced to LF by `.gitattributes` and
  by a byte-level self-test so direct Unix execution cannot resolve an
  interpreter name ending in `\r`.
  `.claude/settings.local.json` is intentionally gitignored for local Claude
  Code permission overrides.

## Required Checks

Prerequisite: PowerShell 7+ (`pwsh`) on PATH. Windows users should
install from <https://aka.ms/powershell>. The pre-commit shim, hooks,
and CI all hard-require `pwsh`; bare `powershell.exe` is not supported
(the shim detects it only to emit a clear error). GitHub config validation
also needs Python 3 with `requirements-automation.txt` installed.

Primary entry point (invoked by the installed git hooks-path pre-commit shim
and CI):

```powershell
pwsh -NoProfile -File scripts/run-llm-hooks.ps1 -Mode Full
```

This regenerates `.llm/index.md` and `.llm/context.md`, runs the linter,
self-tests, and generated-file checks.

Install the pre-commit hook once per checkout:

```powershell
pwsh -NoProfile -File scripts/install-git-hooks.ps1
```

Granular alternatives when iterating:

```powershell
pwsh -NoProfile -File scripts/generate-llm-index.ps1
pwsh -NoProfile -File scripts/lint-llm.ps1
pwsh -NoProfile -File scripts/test-llm-harness.ps1
pwsh -NoProfile -File scripts/agent-check.ps1
python -m pip install -r requirements-automation.txt
python scripts/validate-github-config.py --self-test
python scripts/validate-github-config.py --repo-root .
```

Use `-Check` in CI to validate generated files without modifying them:

```powershell
pwsh -NoProfile -File scripts/generate-llm-index.ps1 -Check
```

Runtime protocol checks are separate from the LLM harness:

```bash
bash scripts/run-runtime-checks.sh all
```

## Generated LLM Index

Do not edit the section below manually. Regenerate it with
`pwsh -NoProfile -File scripts/generate-llm-index.ps1`.

<!-- LLM-INDEX:START -->
## Skills

- [Adversarial Verification](skills/adversarial-verification.md) (`Quality`) - Use when hardening plans, implementations, tests, or reviews with independent adversarial checks.
  Triggers: adversarial, red team, green team, zero knowledge, handoff, verification, deterministic, quality gate
- [Agent Harness](skills/agent-harness.md) (`Core`) - Use when changing AI context, vendor pointer files, indexes, hooks, or LLM automation.
  Triggers: agent harness, llm, context, skills, index, hooks, ci, automation
- [Architectural Planning](skills/architectural-planning.md) (`Planning`) - Use when planning runtime architecture, protocol boundaries, state machines, or multi-file features.
  Triggers: planning, architecture, design doc, state machine, data flow, feature plan, technical plan
- [Dev Container Tooling](skills/devcontainer-tooling.md) (`Tooling`) - Use when changing the VS Code dev container, installed tools, shell profiles, or post-create setup.
  Triggers: devcontainer, container, codex, cli, post-create, postcreate, powershell profile, pwsh profile, PSReadLine, toolchain
- [Godot GDScript Bindings](skills/godot-gdscript.md) (`Godot`) - Use when writing or reviewing Godot addon code, GDScript APIs, scenes, resources, or exports.
  Triggers: godot, gdscript, addon, plugin, scene, resource, export, api
- [Godot Transport Adapters](skills/godot-transport.md) (`Godot`) - Use when implementing or reviewing Godot transport adapters for WebSocket, WebRTC, polling, reconnect, or multiplayer APIs.
  Triggers: godot transport, client, runtime client, connect, connection, websocketpeer, WebSocketPeer, WebSocketClient, websocketmultiplayerpeer, browser export, Godot 3, Godot 4, webrtc, poll, reconnect, networking, protocol fixture
- [Review And Debugging](skills/review-debugging.md) (`Quality`) - Use when reviewing code, investigating bugs, or validating fixes before merge.
  Triggers: review, code review, debug, investigate, root cause, bug, regression, production risk
- [Security And Privacy](skills/security-privacy.md) (`Protocol`) - Use when handling tokens, user identifiers, logs, persistence, networking, or dependency decisions.
  Triggers: security, privacy, token, secret, logging, storage, tls, dependency
- [Signal Fish Protocol](skills/signal-fish-protocol.md) (`Protocol`) - Use when implementing protocol messages, transports, sessions, auth, or compatibility with upstream Signal Fish projects.
  Triggers: signal fish, protocol, websocket, session, auth, message, rust client, server
- [Testing And Automation](skills/testing-automation.md) (`Testing`) - Use when adding validation scripts, hooks, CI, Godot tests, fixtures, or generated-file checks.
  Triggers: test, ci, github actions, hook, pre-commit, lint, generated, fixture
- [Godot Web Export Constraints](skills/web-export.md) (`Godot`) - Use when code may run in browser exports, WebSocket or WebRTC transport, storage, crypto, or platform-specific Godot behavior.
  Triggers: web export, browser export, html5, browser, websocket, WebSocketPeer, WebSocketClient, client, runtime client, connect, connection, webrtc, cors, origin, mixed content, tls, storage, crypto, Godot 4

## Other LLM Files

- [GDScript Client Shape](code-samples/gdscript-client-shape.md) - Sketch of the intended GDScript-facing Signal Fish client shape.
- [LLM Context Organization](README.md) - Organization guide for repo-specific AI context files.
- [Godot Networking And Web Notes](research/godot-networking-web.md) - Source-backed notes for Godot WebSocket, WebRTC, browser export, and cross-platform networking decisions.
- [Godot Target Notes](research/godot-targets.md) - Compatibility notes for targeting major Godot versions from a GDScript Signal Fish addon.
- [GStack Adaptation Notes](research/gstack-adaptations.md) - Practical gstack practices adapted for this repo's lightweight LLM harness.
- [Signal Fish Protocol Fixtures](research/protocol-fixtures.md) - Pinned upstream sources used to build Signal Fish v2 protocol fixtures for the Godot client.
- [Signal Fish Upstream References](research/protocol-links.md) - Curated upstream references for Signal Fish protocol and client compatibility work.
<!-- LLM-INDEX:END -->
