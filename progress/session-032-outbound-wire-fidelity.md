# Session 032 - Outbound wire fidelity + issue debt sweep

Date: 2026-09-22. Scope: one focused surface - outbound payload correctness
(the encode path), filed and fixed as issues #76-#79, plus a concurrent
`run_godot` step for CI wall time. Drift check first: main green on
`220a24d`, local == origin/main, zero open issues/PRs (issue debt was
already at zero after session 031), protocol-sync OK (upstream server
0.9.1 pin unmoved), no in-progress work.

## Issue debt

No open issues existed, so this session hunted, filed, and fixed four:

- **#76 (P1):** outbound float payload corruption - three verified
  defects: nested floats serialized at reduced precision
  (`JSON.stringify`'s `full_precision` does not reach container values),
  `nan`/`inf` passed validation onto the wire as unparseable JSON, and
  `send_game_data` lacked `peer_signal`'s JSON-shape guard (a `Vector2`
  silently became the string `"(1, 2)"`).
- **#78 (P2):** `player_name_rules.max_length`/`min_length` validated
  unbounded then collapsed via `int()` (1e30 -> I64_MAX) - the lone
  surviving instance of the #73.4 class; rate limits are u32-bounded,
  port/client_id u16, max_players u8.
- **#79 (P3):** format-downgrade diagnostics printed coerced enum ints
  (`[0, -1, 1]`) instead of wire tokens.
- **#77 (P3):** docs drift - broken quick-start (join before
  `authenticated`, always refused), missing manual-dial semantics in
  reconnection.md, undocumented `max_outbound_message_size`, v2-only
  message/event counts in README, mesh teardown list missing
  `room_joined`, "protocol_version set to 3" wording.

## Delivered

1. **Round-trip-exact encoder (`sf_envelope.gd`).** A recursive JSON
   serializer replaces `JSON.stringify`: floats go through
   `String.num(v, 17)` (+ ".0" normalization so an integral float never
   flips JSON number type), verified by parse-back, with the engine's
   top-level full-precision writer as fallback candidate. Empirical
   basis: 0/50000 random doubles in +/-1e15 fail round-trip with this
   scheme; some very small magnitudes do not survive the engine's
   formatters, so any float neither candidate proves exact **refuses
   the frame** - reject-never-collapse, the #73 policy. Depth is
   bounded by `MAX_MESSAGE_DEPTH` like the decoder, and the builder
   whitelist starts at the payload's envelope-relative depth so both
   layers refuse at the same point. Byte-pinned encoder fixtures stay
   green (no fixture carries floats).
2. **Whitelist + builder guard (`sf_messages.gd`).** `_is_json_value`
   accepts floats only when finite; `game_data` validates its payload
   (top-level null stays allowed - upstream `Value::Null`, decoder-pinned).
3. **Boundary net (`signal_fish_client.gd`).** `_send_envelope` checks
   the encoded text: a payload that skips builder validation
   (e.g. a `Vector2` inside `ConnectionInfo.custom.data`) now surfaces
   as `ERR_INVALID_DATA` + `protocol_error` instead of sending an empty
   text frame. `send_transport_status(transport_kind, ...)` renames the
   parameter that shadowed the `transport` member.
4. **i64 bound for name-rule lengths (`sf_types.gd`)** via
   `_has_i64_integer`; dead `_has_nonnegative_integer` removed.
5. **Diagnostics (`sf_game_data_format.gd`):** downgrade reasons render
   `[json, unknown]`-style token labels.
6. **Docs (issue #77):** quick-start joins inside `authenticated`;
   reconnection.md documents last-dialed URL + credential-context
   refresh; events.md documents `ProtocolInfo` (incl.
   `max_outbound_message_size`); README counts 14/28; mesh-guide lists
   `room_joined`; events.md wording on the protocol-version gate.
7. **CI wall time.** `run_godot` runs its 7 engine invocations
   concurrently (per-worker cold project copies avoid `.godot` cache
   races), aggregating each suite's output verbatim - the `run_static`
   pattern from session 031. Local godot step: 8.0s -> 4.5s; full local
   `all`: 12.1s -> ~8.5s. Coverage unchanged.

## Validation

- Probes (offline, headless) pinned the pre-fix behavior: reduced float
  precision with and without `full_precision`, `nan` on the wire after a
  passing whitelist check, 1e30 -> I64_MAX collapse, `"(1, 2)"` game-data
  stringification.
- All five suites + demo boots green; smoke green; `gdformat`/`gdlint`
  clean; new tests data-driven (float vectors, refusal matrix, i64
  boundaries, downgrade cases).
- Adversarial review loop on the full diff (see below).

## Leftovers / follow-ups

- A few very small float magnitudes cannot be round-tripped by any
  Godot formatter; the encoder refuses them with a diagnostic rather
  than sending altered values. If upstream ever needs that range in
  game data, the fix is a custom shortest-round-trip formatter - deferred until a real need exists.
- Remaining PLAN items: the manual Asset Library bootstrap (human) and
  gated P7 work.
