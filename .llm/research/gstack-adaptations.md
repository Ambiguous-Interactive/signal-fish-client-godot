---
description: Practical gstack practices adapted for this repo's lightweight LLM harness.
triggers: gstack, workflows, roles, review, planning, adversarial, verification
category: Research
---

# GStack Adaptation Notes

Source analyzed: https://github.com/garrytan/gstack

These notes capture practical practices worth adapting without importing
gstack's large command system or Claude-specific installation model.

## Useful Practices To Adapt

- Planning, diagrams, and plan-to-test handoff map to
  `.llm/skills/architectural-planning.md`.
- Structural review, confidence-gated findings, and root-cause debugging map to
  `.llm/skills/review-debugging.md`.
- Red/green roles, zero-knowledge review, deterministic hardening, and release
  gates map to `.llm/skills/adversarial-verification.md`.
- Harness and documentation freshness remain owned by
  `.llm/skills/agent-harness.md` and `.llm/skills/testing-automation.md`.
- QA maps to deterministic tests and adversarial gates for now; broader live QA
  is deferred until runtime code and demo scenes exist.
- Retro and persistent memory are deferred. They need real commit/test history
  before they are worth encoding.

## Local Adaptation

- Keep `.llm/context.md` canonical and concise.
- Keep reusable guidance in `.llm/skills`, `.llm/code-samples`, or
  `.llm/research`.
- Prefer small task-triggered skills over slash-command routing.
- Preserve existing required checks:
  `scripts/generate-llm-index.ps1` and `scripts/lint-llm.ps1`.
- Anchor protocol behavior to Signal Fish upstream repositories before runtime
  implementation.
- Point implementation examples to `.llm/code-samples` and domain skills so
  GDScript, Godot web export, and Signal Fish boundaries stay in their owning
  files.

## Ideas Not Copied

- Browser automation stack, telemetry, memory sync, and deployment automation are
  too heavy for this bootstrap repo.
- Claude-specific global install and slash-command routing conflict with the
  repo's generalized pluggable `.llm` approach.
- Continuous auto-commit/checkpoint behavior should remain a user or tool choice,
  not a repository rule.
- 100% coverage as a blanket goal is less useful than deterministic coverage of
  protocol, transport, state, and public API invariants.
- Live network QA should not be mandatory until fake transports and fixtures
  cover the core behavior reliably.

## Follow-Up Candidates

- Add runtime test fixtures once upstream Signal Fish wire semantics are pinned.
- Add a review-readiness artifact only if plans and runtime code become large
  enough to justify persistent per-branch state.
- Add Godot smoke projects after the addon structure exists.
- Add security-specific checks if credentials, persistence, or live endpoints are
  introduced.

