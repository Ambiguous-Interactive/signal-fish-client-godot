# Signal Fish - Godot 4 GDScript Client Bindings - Plan

Living plan: **in-progress and future work only.** Completed work lives in
`progress/`, durable rules in `.llm/context.md` + `.llm/skills/`, the shipped
API map in `.llm/code-samples/gdscript-client-shape.md` (see
`.llm/skills/architectural-planning.md`, "Plan File Hygiene").

**Status:** P0-P6 are complete - protocol codec + fixtures (pinned to
upstream v0.9.1), transport seam, core client/config/state machines,
authority, spectators, reconnection + replay, MessagePack/binary game data,
v3 session-plan signaling + WebRTC mesh, demo + Web export smoke, MkDocs
docs site, CI matrix (Godot 4.3/4.4.1/4.7.2), and release automation.
Per-session history: `progress/session-NNN-*.md`.

## Next work

Next session: choose one item below as the sole milestone and finish its PR
and checks within about one hour. Session cadence:
`.llm/skills/architectural-planning.md`.

### Automation

- [ ] #234: Record the next Dependabot auto merge in the issue (main SHA plus
      Runtime CI, LLM Harness, Docs Validation, and Docs Deploy run links),
      confirm the deploy used the validated artifact, then close it. The
      dispatch chain is pinned by tests; deferred-dispatch behavior covers
      back-to-back merges.

### Asset Library settings (#194)

- [ ] Add the Asset Library username and password as repository secrets.
      Confirm the asset ID variable stays `5489`, then close #194. Runbook:
      `.llm/skills/asset-library-release.md`.

### Post-v1 (P7, each gated)

- [ ] Godot 3.6 compat (`WebSocketClient` adapter behind the seam + smoke
      tests) - only after the separate compatibility decision (context.md
      MVP rule).
- [ ] Revisit Rkyv (stays pass-through unless upstream offers a
      JSON-equivalent).

## Definition of done (v1)

- The full protocol is implemented and adversarially verified (per
  `.llm/skills/adversarial-verification.md`): all 12 client messages / 26
  events, authority, spectators, reconnection + missed-event replay,
  MessagePack (opt-in) + binary pass-through, and the optional WebRTC mesh.
- All context.md "first usable client" DoD items hold; tests deterministic
  and green; `gdformat`/`gdlint` clean; `ci.yml` green across the Godot
  matrix; `llm-harness.yml` still green.
- The demo runs in editor and exports to web; README/docs stay accurate.
- The first Godot Asset Library entry is published, and tagging a release
  auto-submits a pending update.
