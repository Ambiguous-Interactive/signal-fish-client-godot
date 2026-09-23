---
description: Use when implementing, reviewing, or testing Signal Fish reconnection, replay, reconnection tokens, or auto-reconnect backoff.
triggers: reconnection, reconnect, replay, missed_events, reconnection_token, auth_token, auto-reconnect, backoff, reconnection-replay, retry
category: Protocol
---

# Reconnection And Replay

## Trigger

Use when touching `SignalFishClient.reconnect`, `set_auto_reconnect`, the
retained reconnection context, `Reconnected`/`ReconnectionFailed` handling, or
any test that simulates disconnect/retry timing.

## Upstream anchors (verified 2026-09-23, server `main` @ `272cfa0c`)

### Replay (`missed_events`) semantics

- Ordered oldest -> newest (server `reconnection.rs` `EventBuffer`, forward
  iteration); entries carry no wire sequence numbers (the server's global
  replay counter is internal only), so wire-level dedup is impossible — the
  client's verbatim, order-preserving replay is the correct contract.
- Only control events are buffered (`PlayerJoined`/`PlayerLeft`/
  `PlayerReconnected`/`NewSpectatorJoined`/`SpectatorDisconnected`/
  `LobbyStateChanged`/`AuthorityChanged`); `GameData` is never replayed — a
  reconnecting client resyncs from the room snapshot. The server also filters
  the replay per recipient (drops the reconnector's own join/leave deltas,
  re-projects authority).
- Ring is bounded (config default 100, hard cap 65536); truncation is
  reported v3-only via `replay: complete|truncated|unavailable` +
  `sender_watermarks` (gap recovery via `DeliveryReport`; per-sender `seq`
  starts at 1). v2 wire has no truncation flag — our client's
  `MAX_MISSED_EVENTS` decode cap + `protocol_error` sentinel is the only
  client-side guard. We do not yet decode `replay`/`sender_watermarks`
  (raw-only); tracked as issue #114.

### Server WebSocket close codes (`src/coordination/mod.rs` `CloseReason`)

`4000` shutdown, `4001` auth timeout, `4002` slow consumer, `4003` activity
timeout, `4004` idle timeout, `4005` room inactive, `4006` inbound rate
limited, `4007` kicked, plus RFC-standard `1000` (unregistered — normal) and
`1009` (outbound message too large). `4007` implies no reconnection; during
drain v3 clients get a best-effort `GoingAway` before the `4000` close.

### Handshake anchors (pinned 2026-09-19)

- Server `src/protocol/messages.rs` @ `eaae1ca3`: `RoomJoinedPayload` and
  `ReconnectedPayload` both carry `reconnection_token: Option<String>`.
- Rust client `src/client_core.rs` @ `fdab2e83`: `AutoReconnectContext`
  retains `{player_id, room_id, token}` from the freshest player baseline;
  tokenless and spectator baselines clear it; `take_auto_reconnect_operation`
  only fires when retention is on, the client is authenticated, and no room
  role is active. Every connection round (including reconnection rounds)
  authenticates first (`authenticate_message` at round start); the directed
  `reconnect` is issued after re-authentication. Voluntary room exits
  (`clear_room`) discard the context, so a policy never rejoins a room the
  caller chose to leave.
- Server `src/websocket/connection.rs` @ `eaae1ca3`: when app-ID allowlisting
  or connect tokens are enforced, `app_handshake_complete` starts false and
  any pre-auth message (including a first-message `Reconnect`) is answered
  with `Error{MissingAppId}` and the link is closed. Authenticate-first is
  therefore mandatory on enforcing deployments.
- Wire: `Authenticate` -> `Authenticated`, then
  `Reconnect{player_id, room_id, auth_token}` (client message) ->
  `Reconnected{...full baseline..., missed_events}` or
  `ReconnectionFailed{reason, error_code}`.

## Token lifecycle (client rules)

- The server issues the token inside every `RoomJoined`/`Reconnected`
  baseline (`RoomJoinedInfo.reconnection_token`, `""` when absent/null).
- Every authoritative baseline replaces the retained context; a baseline
  without a token clears it. Spectator baselines clear it — the protocol has
  no spectator reconnect. Leaving the room (`room_left`) and a user
  `close()` also clear it: nothing after a leave or clean close may silently
  rejoin a room.
- Tokens are secrets: capture appends them to the client's redaction list;
  never log, serialize, persist, or echo them. Note the token also rides in
  consumer-visible `RoomJoinedInfo.raw`/`to_dict()` and `DecodedEvent.raw`;
  document to game teams that logging whole payloads leaks it.

## Manual reconnect

- `reconnect(player_id, room_id, auth_token)` opens a fresh transport,
  authenticates, and sends `Reconnect` once `Authenticated` arrives (upstream
  parity: enforcing servers reject a pre-auth `Reconnect`). The dial target
  is the URL the most recent dial targeted (an explicit `connect_to_server`
  override wins over `endpoint_url`); reconfiguring does not retarget a
  retained reconnection identity because tokens are endpoint-bound. The
  dial's credentials become the retained auto-reconnect identity (issue #73):
  a manual dial with a rotated token replaces a stale context, so a later
  retry never reuses the old token. Guards:
  unconfigured, active connection, empty args, no dial target (no prior
  `connect_to_server` URL and empty `endpoint_url`). On dials the
  `authenticated` signal stays consumer-silent (re-authentication is
  internal): the visible flow is `connected` -> `reconnected` /
  `reconnection_failed`, and a join-on-auth handler cannot race the
  handshake with a fresh `JoinRoom`. Inbound events are ignored entirely
  while `CLOSING` (late packets must not resurrect a cleared identity).
- On `Reconnected`, restore state from the baseline, hand the decoded
  `missed_events` array to the consumer, consume the dial credentials, and
  reset the retry budget. Replay is the consumer's job (no hidden re-emit).

## Auto-reconnect (opt-in, off by default)

- `set_auto_reconnect(true)` arms retry after an abnormal termination only:
  any server-initiated transport close or transport failure (dead dial,
  dropped link) counts; a user `close()` is clean and cancels a pending
  retry, including one armed mid-dial (a close while connecting surfaces as
  `failed` and must not retry). Consumers dialing from a `disconnected`
  handler win: the scheduler never arms against a live dial.
- Backoff (plan-locked constants): base 0.5s, factor 2, cap 15s, jitter
  fraction 0.25, budget `config.reconnect_max_attempts` (default 5). A failed
  dial emits `connection_failed` (the transport failure) and then arms the
  next attempt; a dial refused synchronously re-enters scheduling so the
  episode never stalls — it either arms the next backoff window or ends with
  the exhaustion notice. When the budget is exhausted, a final
  "auto-reconnect exhausted" `connection_failed` follows the last attempt's
  failure, the retained token is dropped, and retrying stops. The budget
  resets only when an authoritative baseline (`RoomJoined`/`Reconnected`)
  re-establishes a session.
- Terminal `ReconnectionFailed` codes (`RECONNECTION_TOKEN_INVALID`,
  `RECONNECTION_EXPIRED`) clear the context and stop retrying;
  `RECONNECTION_FAILED` and other codes stay retryable. After any
  `ReconnectionFailed` the client tears the link down itself (emits
  `disconnected(-1, "reconnection failed")`), so consumers always observe a
  terminal disconnect and retryable auto-reconnects keep a clean scheduling
  point.
- Close code `4007` (`kicked`) ends the episode without retrying and clears
  the retained identity: the server removes the reconnection record on kick.
  All other codes keep the "not user-initiated -> retry" rule.
- All timing accumulates `_process(delta)` — no threads, no `OS.delay`, web
  safe. Tests inject deltas (`client._process(dt)`), never wall clocks.

## Testing rules

- Suite: `tests/client/run_reconnect_tests.gd` (wired into
  `scripts/run-runtime-checks.sh`).
- Backoff values are plan-locked: assert the scheduled delay against the
  `DELAY_BOUNDS` table instead of real time.
- Reconnect fixtures use placeholder tokens only (`TOKEN_V1`/`TOKEN_V2` in
  tests); never commit realistic tokens (`security-privacy.md`).
- The vendored wire fixtures pre-date `reconnection_token`; decode tests cover
  presence, absence, and JSON null inline instead of editing the pinned
  fixtures (re-pin is tracked by issue #12).
