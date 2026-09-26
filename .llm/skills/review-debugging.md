---
description: Use when reviewing code, investigating bugs, or validating fixes before merge.
triggers: review, code review, debug, investigate, root cause, bug, regression, production risk
category: Quality
---

# Review And Debugging

## Trigger

Use this skill for pre-merge review, bug investigation, regression analysis,
and any fix where the cause is not already proven.

## Code Review Stance

Review for production risks that can pass ordinary tests:

- Protocol compatibility drift from upstream Signal Fish behavior.
- Missing connection states, close handling, retry limits, or idempotency rules.
- Ordering, duplicate-message, partial-failure, and reconnect edge cases.
- Godot 3 versus Godot 4 API differences hidden in shared runtime code.
- Browser export restrictions around WebSocket, storage, blocking work, and TLS.
- Sensitive values in logs, fixtures, errors, or browser-accessible persistence.
- Public GDScript API names, signals, and async behavior that are hard to change.
- Performance and reliability failures: unbounded queues, reconnect storms,
  per-frame allocations, blocking work, missing cleanup, or silent stuck states.
- Tests that prove only the happy path while missing the real failure mode.

Avoid style-only findings unless they hide a correctness, maintainability, or
developer-experience risk.

## Finding Quality Gate

Before reporting a finding:

1. Quote or cite concrete code evidence.
2. Explain the failure scenario and affected user, developer, or protocol path.
3. Assign confidence from 1-10.
4. Suppress low-confidence speculation unless the possible impact is severe.
5. Separate confirmed findings from manual checks and unverifiable concerns.

Use severity for action:

- `P1`: likely data loss, security exposure, protocol breakage, or unusable API.
- `P2`: credible reliability, compatibility, determinism, or maintainability risk.
- `P3`: cleanup that prevents confusion but does not block safe progress.

## Debugging Iron Law

No fixes without root cause investigation first.

1. Reproduce or characterize the failure with the smallest reliable signal.
2. Trace data flow across Godot API, protocol layer, transport, and upstream
   expectations.
3. State one testable root-cause hypothesis.
4. Verify the hypothesis before changing production code.
5. Fix the root cause, not the symptom.
6. Re-run the reproduction and add a regression test or fixture when practical.

If three hypotheses or fix attempts fail, stop and reassess the architecture,
scope, or missing observability before continuing.

## Health-Check Hygiene

When adding or reviewing shell health checks, remember that a non-empty
output stream is not a success signal. A command that dies on startup still
prints error lines; merging stderr into a captured value and treating any
content as "works" marks broken tools as healthy. Verdict on the exit status,
capture stdout and stderr separately, and report the first error line as the
diagnostic for the failure path. Sweep for this class whenever one instance
is found: every `$(cmd 2>&1)` whose non-emptiness gates success is suspect.

## Regression Expectations

Every confirmed bug fix should leave behind at least one guardrail:

- A protocol fixture for malformed, missing, duplicated, or reordered messages.
- A fake transport test for close, retry, timeout, and reconnection behavior.
- A Godot-facing test or minimal example for emitted signals and state changes.
- A documented manual check when automation is not yet possible.

Do not mark a bug fixed when the original scenario cannot be reproduced,
simulated, or explicitly called out as manually verified.

## Replacement Sweeps

When a mechanism is replaced or deleted, sweep for its name in the same
change across code callers, `.llm/**` skills, README/docs, workflows, and
tests. Stale guidance passes green CI silently: PR #159 removed
`ensure-env-file.ps1` with the code sweep done, yet
`devcontainer-tooling.md` kept documenting the host-shell guard it
belonged to.

## See Also

- `.llm/skills/signal-fish-protocol.md` for upstream compatibility checks.
- `.llm/skills/security-privacy.md` for secrets, logs, storage, and TLS review.
- `.llm/skills/web-export.md` for browser-specific failure modes.
- `.llm/skills/godot-gdscript.md` for public API and Godot version review.
