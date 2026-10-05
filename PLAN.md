# Signal Fish - Godot 4 GDScript Client Bindings - Plan

Living plan: **in-progress and future work only.** Completed work is logged in
the local `progress/` notes (git-ignored; never committed), durable rules in
`.llm/context.md` + `.llm/skills/`, the shipped
API map in `.llm/code-samples/gdscript-client-shape.md` (see
`.llm/skills/architectural-planning.md`, "Plan File Hygiene").

**Status:** P0-P6 are complete - protocol codec + fixtures (pinned to
upstream v0.9.1), transport seam, core client/config/state machines,
authority, spectators, reconnection + replay, MessagePack/binary game data,
v3 session-plan signaling + WebRTC mesh, demo + Web export smoke, MkDocs
docs site, CI matrix (Godot 4.3/4.4.1/4.7.2), and release automation.
Per-session history: local `progress/session-NNN-*.md` notes (git-ignored).

## Next work

Next session: choose one item below as the sole milestone and finish its PR
and checks within about one hour. Session cadence:
`.llm/skills/architectural-planning.md`.

### Automation

- [ ] #307: Stop the red auto-merge job that back-to-back Dependabot merges
      leave behind (first observed live 2026-10-05). Bounded retry on the
      racing-merge recheck in `scripts/dependabot-auto-merge.py`, pinned by
      a test.

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
