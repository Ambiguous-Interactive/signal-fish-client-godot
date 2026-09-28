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

### Automation (#168)

- [ ] #234: Verify that a later Dependabot merge dispatches Docs Deploy and
      publishes the validated main artifact without a manual CI rerun.
- [ ] #168: Move suitable automation to Python and uv while preserving the
      PowerShell harness and the runtime gate behavior.

### Asset Library moderation (P6 remainder)

- [ ] Wait for moderation of edit #24434 on Asset Library entry #5489.
      Verify the live entry shows `0.1.0`, Scripts, Godot 4.3, and the
      `v0.1.0` tag commit. Check the download contents. Runbook:
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
