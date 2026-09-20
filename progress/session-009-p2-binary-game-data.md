# Session 009 - P2 Binary Game Data (MessagePack + binary frames)

Date: 2026-09-20

## Scope

- One focused surface: the last open P2 milestone - binary game data.
  Pure-GDScript MessagePack codec, strict binary game-data envelope decoding,
  `send_game_data_binary`, and unblocking `message_pack`/`rkyv` negotiation in
  `SignalFishConfig`. This completes every P2 checkbox in `PLAN.md`.

## Drift check

- `main` up to date with `origin/main` (tip: PR #19, P2 reconnection).
- No open PRs; open issues #12/#13 (P2), #15/#20/#21 (P3, deferred by design).

## Upstream anchors (fetched fresh, not assumed)

- server `src/websocket/sending.rs` @ `main` (v0.9.1): v2-route
  `message_pack` frames are a MessagePack named map (`LegacyBinaryGameDataFrame`);
  v2-route `json`/`rkyv` frames are raw payload bytes, no envelope; v3 frames
  (`V3BinaryGameDataFrame`) add non-zero `seq`/`epoch` and wider encoding
  tokens, and only ever arrive on the separate v3 WebSocket route.
- server `src/websocket/connection.rs`: client→server binary = raw payload
  bytes; the server tags inbound binary with the negotiated format and drops
  binary on `json` connections with `InvalidInput`.
- rust client `src/protocol/binary.rs` @ `main` (ported from server v0.4.0):
  strict decode rules - string keys, no duplicate/unknown fields, no trailing
  bytes, 16-byte binary UUID `from_player`, any unsigned marker width for
  stamps. `PlayerId = uuid::Uuid` serializes as 16 raw bytes in MessagePack
  (non-human-readable serde).

## What landed

- `addons/signal_fish/protocol/sf_msgpack.gd` - pure-GDScript MessagePack
  decode/encode over `StreamPeerBuffer` (big-endian native, web-safe):
  fix/8/16/32 str + bin, fix/16/32 array + map, all integer widths, float32/64
  (u64 above i64 max surfaces as float, serde-parity), depth-capped recursion
  (mirrors `SFEvents.MAX_MESSAGE_DEPTH`), strict trailing-byte rejection;
  encode covers null/bool/int/float/string/bin/array/map with string keys only
  (server decodes payloads as JSON values).
- `addons/signal_fish/protocol/sf_binary_frames.gd` - strict v2/v3 envelope
  decoder: canonical lowercase UUID string for `from_player`, v2 allows only
  `message_pack`, v3 requires both non-zero stamps, hostile inputs rejected
  with specific diagnostics. Hand-rolled map reader so duplicate-key rejection
  is exact (a Dictionary decode would silently collapse duplicates).
- `signal_fish_config.gd` - `game_data_format` now accepts `message_pack` and
  `rkyv` (rkyv documented as pass-through for games bringing their own
  reader); new opt-in `decode_msgpack_payloads`.
- `signal_fish_client.gd` - `send_game_data_binary(bytes)` (session guard,
  non-empty, refused with `ERR_UNAVAILABLE` under JSON negotiation since the
  server drops binary there anyway, backpressure-aware, raw bytes on the
  wire); binary receive path dispatches per negotiated format:
  `message_pack` → strict envelope → bytes signal (default) or decoded
  `game_data_received` (opt-in, with a raw-bytes fallback + `protocol_error`
  when a payload is undecodable), `rkyv` → raw pass-through with `from_player
  = ""` (no envelope exists upstream), JSON/unset → dropped with
  `protocol_error`, link stays up.
- Tests: `tests/protocol/binary_frame_tests.gd` (hand-pinned canonical v2
  envelope bytes, variant matrix incl. map16 header/shuffled order/empty
  payload, hostile matrix: duplicate key, unknown field, trailing bytes,
  short/oversized/string UUID, string payload, v2 json/rkyv/unknown tokens,
  v3 half/zero/negative/string stamps, msgpack decode/encode width vectors,
  round-trip matrix, depth bomb) wired into `run_protocol_tests.gd`; client
  suite `tests/client/run_client_tests.gd` gains `_test_binary_game_data_paths`
  (send guards + wire bytes, envelope → bytes event, hostile envelope keeps
  the link up, opt-in decode + fallback, rkyv pass-through) and updated config
  validation for the unblocked formats.
- Docs: `PLAN.md` P2 marked complete (all five checkboxes), `send_game_data_binary`
  signature corrected to upstream parity (no client-side encoding parameter -
  the server tags inbound binary with the negotiated format; rust
  `send_binary_game_data(payload)` parity), `.llm/research/protocol-fixtures.md`
  binary wire notes with fresh upstream pins.

## Verification

- `bash scripts/run-runtime-checks.sh all` green (private-helpers guard,
  gdformat, gdlint, all 5 Godot suites), including the cold-project path.
- `pwsh -NoProfile -File scripts/agent-check.ps1` green after `.llm` edits.
- Adversarial review round 1 (zero-knowledge sub-agent, upstream-verified):
  1 P1 / 5 P2 / 6 P3 findings, all addressed:
  - P1 (json binary frames): verified against current server `sending.rs`
    cohort match - a json-negotiated v2 recipient only receives game data as
    TEXT (`BinaryFallbackV2`), and json senders cannot originate binary (the
    server drops it), so binary on a json connection is hostile input, not
    lost game data. Behavior kept (drop + `protocol_error`, link stays up);
    the wire note and refusal diagnostics were made precise instead.
  - P2: u64 stamps above i64 max no longer mis-rejected (wrapped-negative is
    a valid huge stamp); binary frames now honor the CLOSING/CONNECTED guard
    like text events; effective game-data format is tracked and reconciled
    against `ProtocolInfo.game_data_formats` + `Error{
    UnsupportedGameDataFormat}` so a server-downgraded negotiation refuses
    binary sends/drops frames instead of dead-sending; the vacuous deep-decode
    assertion was replaced with crafted byte vectors exercising the decode
    depth cap; binary-send backpressure is now covered.
  - P3: opt-in MessagePack decode gated on `encoding == message_pack`;
    refusal/label messages precise for unset formats; truncated map32
    headers report cleanly; str8-form encoding tokens, u64-max stamps,
    float/bin stamp rejection covered by vectors; strictness claim scoped to
    well-formed frames; UTF-8 leniency documented in `sf_msgpack.gd`.
- Client binary tests moved to their own suite `tests/client/run_binary_tests.gd`
  (gdlint 1200-line cap) wired into `scripts/run-runtime-checks.sh`.

## Follow-ups / deferred

- Issue #12 (fixture re-pin to current upstream + sync automation) stays open:
  this session pinned the binary-frame surface to current upstream, but the
  vendored JSONL fixtures still point at 2026-05-29 commits.
- Issue #13 (user-facing README/auth primer) remains the top P2 usability item.
- P3 WebRTC helper and P4 demo + web-export smoke + docs are the next PLAN
  phases; #15/#20/#21 remain deferred P3 hardening.
