---
description: Use when hardening plans, implementations, tests, or reviews with independent adversarial checks.
triggers: adversarial, red team, green team, zero knowledge, handoff, verification, deterministic, quality gate
category: Quality
---

# Adversarial Verification

## Trigger

Use this skill for high-risk protocol work, release readiness, test strategy,
or anytime an independent reviewer should challenge a plan or implementation.

## Roles

- Green team: implements the smallest complete version that matches the plan.
- Red team: tries to break assumptions with edge cases, invalid input, ordering
  issues, compatibility gaps, and security/privacy risks.
- Zero-knowledge reviewer: receives only intent, constraints, upstream anchors,
  tests, and the diff or plan. They should not inherit the implementer's
  rationale unless needed to resolve ambiguity.
- Release gate: checks whether required plans, reviews, tests, docs, and manual
  verifications are complete enough to ship.

## Handoff Packet

For hardening reviews, pass a compact packet:

- Intent and non-goals.
- Files or modules in scope.
- Upstream paths and commits for protocol facts.
- Compatibility targets and web export constraints.
- Invariants that must not break.
- Test matrix and commands already run.
- Known unknowns, manual checks, and intentionally deferred work.

The reviewer classifies each requirement as `DONE`, `PARTIAL`, `NOT DONE`,
`CHANGED`, or `UNVERIFIABLE`. Be conservative with `DONE`; a touched file is not
proof that the requirement is satisfied.

In a single Cursor session, simulate zero-knowledge review by reading only the
handoff packet and diff first. Do not reuse the implementer's rationale until
after findings are classified or ambiguity blocks progress.

## Review Loop

For high-risk work, run the loop until no blocking findings remain:

1. Green team implements or revises the smallest complete change.
2. Red team reviews with the handoff packet and classifies findings.
3. Green team fixes confirmed findings or records a defer/unverifiable rationale.
4. Red team re-checks only the changed behavior and unresolved findings.
5. Release gate ships only when all `P1`/`P2` findings are fixed, deferred with
   owner and rationale, or marked unverifiable with a manual check.

## Red-Team Checklist

Challenge these categories before merging:

- Positive path: normal connect, send, receive, close, and cleanup.
- Negative input: malformed messages, missing fields, wrong types, bad close
  codes, invalid endpoints, and unsupported protocol versions.
- Error path: network drop, reconnect failure, auth failure, parse failure,
  server refusal, duplicate messages, and partial writes.
- Extreme path: large payloads, rapid reconnect loops, repeated sends during
  state transitions, slow frames, and browser tab suspension.
- Compatibility: Godot 3/4 API drift, web export restrictions, TLS/CORS, and
  storage differences.
- Privacy/security: token leaks, unsafe logs, long-lived browser storage, and
  untrusted upstream or page-derived content.

## Determinism Rules

Prefer deterministic checks before integration checks:

- Fake transports over live network services.
- Seeded or fixed fixture data over random data.
- Explicit time providers or short controlled timers over wall-clock sleeps.
- Local upstream fixtures with recorded source paths and commits.
- Stable assertions on state and emitted signals, not incidental log text.

If a test must be nondeterministic or manual, label it clearly and keep it out of
mandatory fast gates until it can be made reliable.

## Mandatory Gates

Before implementation:

- Architectural plan exists for multi-file or protocol-affecting work.
- Unknown upstream behavior is researched or explicitly blocked.

Before review:

- Positive, negative, error, and edge cases are mapped to tests or manual checks.
- Sensitive data and web export risks have been considered.

Before release:

- Required generated files are fresh.
- Fast deterministic checks pass.
- Review findings are fixed, deferred with rationale, or marked unverifiable
  with a manual check.
- Documentation reflects public API, compatibility, and known limitations.

## See Also

- `.llm/skills/architectural-planning.md` for the plan and test matrix source.
- `.llm/skills/review-debugging.md` for finding severity and root-cause rules.
- `.llm/skills/testing-automation.md` for generated-file and CI checks.

