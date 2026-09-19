# Session 004 - Devcontainer Agent CLI Suite

Date: 2026-09-18

## Scope

Bring the Godot devcontainer to parity with the sibling repos
(signal-fish-server, signal-fish-client-rust, signal-fish-cloud) for terminal
agent tooling:

- Auto-install four agent CLIs at container create: `codex`, `opencode`,
  `nanocoder`, `claude`.
- Refresh them warn-only on every container start (registry fast path).
- Record the tooling guarantees in `.llm/skills/devcontainer-tooling.md`
  instead of growing `PLAN.md`.

## Decisions

- Version policy: `@latest` + version-probe fast path (matches all three
  siblings). The skill's "pinned by default" rule gains a documented
  exception for these CLIs, which publish multiple times per day.
- One generalized installer (`.devcontainer/install-agent-tools.sh`)
  replaces `install-codex.sh`; `--update` mode is the warn-only post-start
  refresh (rust repo pattern).
- Node devcontainer feature stays on `"lts"`; the installer guards
  Node >= 22 and uses npm 11's `--allow-scripts` so `opencode-ai`'s
  platform-binary postinstall runs.

## Work log

- RED: rewrote devcontainer self-tests in `scripts/test-llm-harness.ps1`
  to demand the generalized installer, post-create wiring, and post-start
  refresh; confirmed failures before implementing.
- GREEN: implemented installer + lifecycle wiring; harness green.
- Verified live in Docker (Ubuntu 24.04 + Node 24): install, verification,
  and idempotent fast-path skip.
- Fixed a local-environment bug class found on the baseline: `bash -n`
  invocations fed Windows absolute paths fail under WSL bash
  (`bash_syntax_check` in validate-github-config.py,
  `Assert-ScriptParsesWithBash` in test-llm-harness.ps1, relative invocation
  in the dependabot auto-merge test). Restored working-tree-deleted
  CHATGPT.md/GEMINI.md pointer files that broke sandbox lints.
- Adversarial review round 1 (zero-knowledge sub-agent): 0 P1, 2 P2, 8 P3.
  All fixed: bash-prefix invocation (repo scripts are 100644), prefix-parent
  writability fallback, version-less scoped-spec package guard, credential
  unset before registry/npm work, code-only `--update` assertion, hoisted
  invariant assertions + full ALLOW_SCRIPTS literal asserted, check-then-add
  safe.directory, probe-only fetch timeout, --update skips absent CLIs when
  offline, SIGPIPE guard.
- Fixed during round 2: `Get-TextDiagnosticLines` used `$matches` as a local,
  which the `-match` operator clobbers (crash on the diagnostics path).
  Renamed to `$matchedLines`; repo-wide sweep found no other instance.
- Adversarial review round 2: all 11 fixes FIXED-VERIFIED, verdict approved;
  3 polish items applied (full ALLOW_SCRIPTS assertion, `--allow-scripts`
  only on npm >= 11, accurate probe warning).

## Verification matrix (Docker, live registry)

| Scenario | Result |
| --- | --- |
| Node 24 / npm 11, fresh, online, strict | exit 0; codex 0.155.1, opencode 1.18.31, nanocoder 1.30.0, claude 2.1.278 |
| Node 24 / npm 11, rerun, strict | exit 0; "skipped npm install" (fast path) |
| Node 24 / npm 11, offline, --update | exit 0; warns, keeps installed toolchain |
| Node 24 / npm 11, fresh, offline, strict | exit 1; loud failure (post-create contract) |
| Node 20, strict / --update | exit 1 / exit 0 (Node >= 22 guard) |
| Node 24 / npm 11, nonexistent user prefix | exit 0; parent-writable fallback creates it |
| Node 22 / npm 10, fresh, online, strict | exit 0; --allow-scripts correctly omitted |

## Notes

- npm 11 blocks lifecycle scripts by default on global installs;
  `--allow-scripts` (npm >= 11 only) allows the four CLIs plus their
  script-bearing deps (`@github/keytar`, `node-pty`), mirroring the cloud
  repo's list.
