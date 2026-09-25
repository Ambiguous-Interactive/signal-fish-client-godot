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

- Identifiers are `Uuid`: `PlayerId`, `RoomId`, `SessionGeneration`,
  `RoomOperationId`. Empty cannot deserialize upstream, and `""` collides
  with the retired negotiated-rkyv "sender unknowable" sentinel. Rule: a
  present empty id is malformed -> `protocol_error`, frame dropped, link
  stays up (matches the binary path's 16-byte UUID rule).
- Free-text `String` fields (`error`, `reason`, `message`, `app_name`,
  names, `room_code`, `relay_type`, ICE url entries) pass empty through:
  upstream serde permits it and there is no sentinel ambiguity.
- Optional id fields keep their null sentinel: `AuthorityChanged.authority_player`
  wire null still decodes to `""` ("no authority"); `SpectatorLeft.room_id`
  null -> `""`; `Signal.generation` absent -> `""` (legacy Server 0.4 plan).
  A present empty string is refused so only null can produce the sentinel.

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
  `_test_non_empty_wire_strings`: 22-case data-driven table (one per swept
  surface, incl. replay watermarks and all four SessionPlan id shapes) plus
  boundary positives - wire-null authority keeps the `""` sentinel and an
  empty `RoomJoinFailed.reason` still decodes (pins the free-text boundary).
- Red-green verified: with the decoder changes stashed, all 22 cases fail;
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
