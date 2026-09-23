---
description: Use when planning runtime architecture, protocol boundaries, state machines, or multi-file features.
triggers: planning, architecture, design doc, state machine, data flow, feature plan, technical plan
category: Planning
---

# Architectural Planning

## Trigger

Use this skill before implementing non-trivial runtime behavior, public API
shape, protocol semantics, compatibility policy, or multi-file changes.

## Planning Stance

- Make the idea buildable before making it bigger.
- Prefer the repo's existing boundaries: Godot-facing API, protocol encoding,
  transport adapter, security/storage policy, and version-specific adapters.
- Keep `.llm/context.md` as the entry point; put durable detail in focused
  skills, samples, or research notes.
- Do not invent Signal Fish wire, auth, reconnect, or error semantics. Anchor
  them to upstream paths and commits before implementation.

## Required Plan Shape

For substantial work, write or update a plan that answers:

- Intent: what user-visible or developer-visible capability changes?
- Scope: which files or modules should change, and which are explicitly out?
- Ground truth: which upstream repo, path, commit, or Godot API defines behavior?
- Boundaries: what belongs in Godot API, transport, protocol, storage, and tests?
- State: what connection, retry, close, and failure states exist?
- Trust: what inputs are untrusted, sensitive, persistent, or browser-visible?
- Compatibility: which Godot versions and web export constraints are affected?
- Performance: what per-frame work, payload size, buffering, backpressure, and
  reconnect-loop limits keep the client responsive?
- Reliability: what retry limits, timeout behavior, cleanup paths, and failure
  observability prevent stuck or runaway states?
- Verification: which positive, negative, error, edge, and deterministic tests
  prove the plan?

## Diagrams And Matrices

Use compact ASCII diagrams when they clarify behavior:

- Component diagram for module boundaries.
- Sequence diagram for connect, send, receive, close, retry, and reconnect flows.
- State diagram for connection lifecycle and failure transitions.
- Test matrix mapping requirements to fixtures, fake transports, and smoke tests.

## Plan File Hygiene

`PLAN.md` is a going-forward roadmap, not a log or a knowledge base. Keeping
the three functions in separate files is what prevents context rot; merging
them is how plans bloat (PLAN.md once grew 689 → 1019 lines without a single
shrinking commit).

- `PLAN.md` holds only: a short status line, in-progress/next work with
  checkboxes, open questions to resolve, and the definition of done.
- Completed work is recorded once, in `progress/session-NNN-*.md`, and is
  deleted from `PLAN.md` in the same session that finishes it. Never append
  session summaries or status paragraphs to `PLAN.md`.
- Durable rules and facts live in `.llm/skills`, `.llm/code-samples`, and
  `.llm/research`; `PLAN.md` links to them instead of copying (copies drift).
- Before adding anything to `PLAN.md`, ask: is this about work that has not
  happened yet? If not, it belongs in `progress/` (it happened) or `.llm/`
  (it is durable). A section whose deletion would not change anyone's next
  action does not belong in the plan.
- Keep `PLAN.md` around 100 lines or fewer; growth past that is a signal to
  move content to its function-appropriate home, not to restructure.

## Decision Gates

Stop and ask before choosing among materially different options for:

- Public GDScript API shape or signal names.
- Protocol behavior not yet anchored upstream.
- Godot version support promises.
- Secret storage, logging, telemetry, or browser persistence.
- New dependencies or generated artifacts committed to the repo.
- Changes that make tests depend on network timing, wall clock time, or live
  upstream services.

## Plan-To-Test Handoff

Every plan should leave the implementer with a verification checklist:

- Unit fixtures for protocol encode/decode and malformed input.
- Fake transport tests for ordering, close codes, retry, and reconnection.
- Godot API tests or examples for signal behavior and documented states, checked
  against `.llm/code-samples/gdscript-client-shape.md`.
- Compatibility smoke tests only after deterministic lower-level coverage exists.
- Manual checks called out separately when the repo cannot verify them.

## See Also

- `.llm/skills/signal-fish-protocol.md` for protocol source-of-truth rules.
- `.llm/skills/godot-gdscript.md` for GDScript API and addon shape.
- `.llm/skills/web-export.md` for browser export constraints.
- `.llm/skills/testing-automation.md` for validation and CI guidance.
- `.llm/code-samples/gdscript-client-shape.md` for the current API sketch.
