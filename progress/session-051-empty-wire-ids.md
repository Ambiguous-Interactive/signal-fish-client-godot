# Session 051: Empty wire identifiers are off-contract (issue #149)

Session branch: `fix/empty-from-player-sweep` (from `origin/main` @ `bf0adc7`).
PR: one aggregate PR for the session's work.

## Scope

Open issues, gameplay-impact order (correctness > usability > performance):

- #149 (correctness): JSON `GameDataBinary` accepted an empty `from_player`
  and emitted `game_data_binary_received("", ...)` verbatim - **fixed**, with
  the issue's sweep applied across every string-typed identifier.
- #145 (performance): behavioral self-test CI wall fork-tax bound - **left
  open** (deferred in session 050; unchanged this round).

## #149 - sweep decision and rule

Anchored to the pinned upstream types (`types.rs` @ server v0.9.1):

- Identifiers are `Uuid`: `PlayerId`, `RoomId`, `SessionGeneration` (and
  `RoomOperationId`, whose envelopes this client does not decode - listed as
  upstream anchoring only). Empty cannot deserialize upstream, and `""`
  collides with the retired negotiated-rkyv "sender unknowable" sentinel.
  Rule: a present empty id is malformed -> `protocol_error`, frame dropped,
  link stays up (matches the binary path's 16-byte UUID rule).
- Free-text `String` fields (`error`, `reason`, `message`, `app_name`,
  names, `room_code`, `relay_type`, ICE url entries) pass empty through:
  upstream serde permits it and there is no sentinel ambiguity. Non-id
  optional strings (`connected_at` `Option<DateTime<Utc>>`,
  `reconnection_token`) stay length-agnostic the same way: "" is meaningless
  but collides with no sentinel.
- Optional id fields keep their null sentinel: `AuthorityChanged.authority_player`
  wire null still decodes to `""` ("no authority"); `SpectatorLeft.room_id`
  null -> `""`; `Signal.generation` absent or null -> `""` (legacy Server 0.4
  plan). A present empty string is refused so only null/absence can produce
  the sentinel.

## Decoder changes

- `sf_events.gd`: empty-id refusals on `GameData.from_player`,
  `GameDataBinary.from_player`, `PlayerLeft.player_id`,
  `PlayerReconnected.player_id`, `NewPeer.peer_id`,
  `PeerTransportStatus.peer_id`, `SpectatorDisconnected.spectator_id`,
  `SpectatorLeft.room_id`, `Signal.from`, `Signal.generation`,
  `AuthorityChanged.authority_player`, and `LobbyStateChanged.ready_players`
  entries (helper renamed `_array_contains_non_empty_strings`).
- `sf_types.gd`: `_has_id` helper; `validate_player_info`/`validate_spectator_info`
  `id`, `validate_peer_connection_info.player_id`, `validate_room_joined_info`
  `room_id`/`player_id`, `validate_spectator_joined_info`
  `room_id`/`spectator_id` must be non-empty; `ready_players` uses a new
  `_has_non_empty_string_array` (replaces the single-use `_has_string_array`);
  `_is_optional_watermarks_array` requires a non-empty watermark `player_id`.
- `sf_session_types.gd`: `SessionPlan` `generation`/`host` present values
  must be non-empty; `direct_endpoint.host` refuses empty (upstream
  `DirectEndpoint` construction rejects it); `SessionPeer.player_id` must be
  non-empty.
- Replay path inherits the hardening: `missed_events` re-enters
  `decode_envelope`.
- Outbound builders untouched (empty outbound ids remain the server's
  rejection problem).

## Tests

- `tests/protocol/protocol_hardening_tests.gd`
  `_test_non_empty_wire_strings`: 25-case data-driven table covering every
  swept decode surface (incl. replay watermarks, spectator ids through
  rosters, and all four SessionPlan id shapes) plus boundary positives -
  wire-null authority and absent signal generation keep their `""` sentinels,
  and an empty `RoomJoinFailed.reason` still decodes verbatim (pins the
  free-text boundary).
- Red-green verified: with the decoder changes stashed, all 25 cases fail;
  with them applied, the suite is green.

## Docs

- `.llm/skills/signal-fish-protocol.md` + `.llm/research/protocol-fixtures.md`:
  the non-empty rule recorded once (ids malformed, free text passes) so the
  next sweep question is already answered.
- `CHANGELOG.md`: Fixed entry.
- `docs/` unchanged: `errors.md` already states the generic "malformed frame
  emits `protocol_error` and keeps the connection alive" contract.

## Verification

- `bash scripts/run-runtime-checks.sh changed` - green.
- `pwsh -NoProfile -File scripts/agent-check.ps1` after `.llm` edits - green.
- Red-green proof via stash + `godot protocol` suite (above).
- Adversarial review round 1 applied: spectator-id + spectator-room-id cases
  added (the `_has_id` validator had no test), absent-generation sentinel
  pinned, empty-reason value asserted verbatim, direct_endpoint comment
  re-anchored to `DirectEndpoint::from_connection_info` (src/protocol/
  validation.rs), ready_players messages name the non-empty rule, a mirrored
  `_has_id` in `sf_session_types.gd`, progress-note counts corrected.
- Adversarial review round 2 (independently reproduced the 25-failure red
  run) applied: skill doc now splits failure `reason` (free text) from
  spectator `reason` (enum token, empty malformed), changelog names the
  direct-endpoint gate separately from the UUID rule, generation comment
  says "absent or null", and the `SpectatorLeft` null-room sentinel is
  pinned.
