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
Godot 3.6 compatibility was evaluated and deferred (2026-10-06;
`.llm/research/godot-targets.md`). Per-session history: local
`progress/session-NNN-*.md` notes (git-ignored).

## Next work

- [ ] Isolate and repair Web WebSocket callback receive overflow after service
      recovery (#488; see `docs/testing.md`). Preserve the original delayed
      workload and separate byte-credit controls.
- [ ] Qualify a Godot 4.3 WebSocket receive backport or engine upgrade on
      remote networks (#485; see `docs/testing.md`). Preserve the retained
      byte/count rejections, exact delivered prefix and matched credit controls.
- [ ] Qualify active gameplay shutdown on remote networks (#482; see `docs/testing.md`). Preserve
      the browser send/close race control, distinct reset and nonresponding
      close outcomes, plus cached mesh retirement.
- [ ] Qualify native SCTP startup cancellation and terminal handling upstream
      and on remote networks (#474; see `docs/mesh-guide.md`). Preserve the
      retained startup and teardown failures.
- [ ] Qualify the native incremental-build repair on other build targets and
      coordinate upstream review (#479; see `docs/mesh-guide.md`).

- [ ] Compare uniquely enqueued initial probe expiry with transmitted gaps and
      remote-network controls (#458; see `docs/mesh-guide.md`). Keep strict
      initial-probe failures separate from reliable loss. The historical
      untraced packet's cause remains open.
- [ ] Clarify the empty-packet script API contract upstream before qualifying
      zero-byte mesh sends and safe-peer receives (#437).
- [ ] Complete upstream engine metadata repair and remote-network qualification
      for the opt-in safe RPC peer (#403).
- [ ] Qualify finite packet lifetimes on stable Godot engines after the upstream
      repair (#433).
- [ ] Complete mesh channel interoperability with the reference engines (#355),
      including full reference CLI sessions and remote-network startup
      and recovery (reliable-prefix ingress attribution: server #1244;
      zero-byte script sends: #437; original Chromium 156 receive loss: #442;
      capture heartbeat pause failures with packet interval summaries: #440).
- [ ] Repair the Web reliable receive boundary using scoped engine-rejection
      identities and matched byte-window controls (#442). Keep rejected arrivals
      separate from queued callbacks. Compare the retained source-pinned service
      startup/byte-window controls with remote-network sessions.
      Reproduce the historical
      heartbeat pause failure and compare shared-clock read latency with native
      emission and application drain delays (#440). Keep every reliable receipt
      and the original deadlines.
- [ ] Compare the three-seat held-credit control with the captured native/browser
      stream stall using matched HTTP/WebRTC credit runs, independent gameplay
      and reference-consumer pause controls,
      with independent position cadence, browser-clock HTTP state/resource joins
      and command pipe-write, request, relay,
      engine and transport timings plus matched Godot and
      reference application drain schedules and direct browser fetch versus
      HTTPRequest markers (#396; see `docs/mesh-guide.md`).
      Include the captured two-chunk 16 KiB HTTP credit-turnover limit with
      independent reference receive/send tasks before changing pacing or
      deadlines.
- [ ] Compare uniquely traced phase-1 and phase-2 finite-tail expiry with remote
      controls (#471).
      Keep the historical phase-1 tail open; preserve the failed 4 KiB/100 ms
      reader history and strict retirement checks.
- [ ] Symbolicate the retained cold-import crash at engine PC `0x19a9bd8`
      (#447), then isolate extension initialization and editor shutdown. Keep
      the original/patched-extension failures and warm/no-extension controls.

Next session: choose one item below as the sole milestone and finish its PR
and checks within about one hour. Session cadence:
`.llm/skills/architectural-planning.md`.

### Post-v1 (P7, gated)

Steam live-validation path (2026-10-06 feasibility research; the issues
carry the full data-backed plan):

- [ ] Live drills: dual-seat loopback (#321), then two machines and the
      recorded verdict closing #315 (#322), driven by the #318 harness.
- [ ] Gated follow-up: CI Steam seat exploration (#319).
- [ ] When `protocol-sync.yml` flags binding drift past the v0.9.1 wire
      commit: adopt `JoinRoom.join_only`, typed
      `ProtocolInfo.implementation_version`/`game_data_limits`, and the
      RoomOperation sender + result correlation (the v0.10.0 surface is
      already decode-tolerated; see `.llm/research/protocol-fixtures.md`).

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
