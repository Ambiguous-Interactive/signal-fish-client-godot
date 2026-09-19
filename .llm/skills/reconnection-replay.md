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

## Upstream anchors (pinned 2026-09-19)

- Server `src/protocol/messages.rs` @ `eaae1ca3`: `RoomJoinedPayload` and
  `ReconnectedPayload` both carry `reconnection_token: Option<String>`.
- Rust client `src/client_core.rs` @ `fdab2e83`: `AutoReconnectContext`
  retains `{player_id, room_id, token}` from the freshest player baseline;
  tokenless and spectator baselines clear it; `take_auto_reconnect_operation`
  only fires when retention is on, the client is authenticated, and no room
  role is active.
- Wire: `Reconnect{player_id, room_id, auth_token}` (client message) ->
  `Reconnected{...full baseline..., missed_events}` or
  `ReconnectionFailed{reason, error_code}`.

## Token lifecycle (client rules)

- The server issues the token inside every `RoomJoined`/`Reconnected`
  baseline (`RoomJoinedInfo.reconnection_token`, `""` when absent/null).
- Every authoritative baseline replaces the retained context; a baseline
  without a token clears it. Spectator baselines clear it — the protocol has
  no spectator reconnect.
- Tokens are secrets: capture appends them to the client's redaction list;
  never log, serialize, persist, or echo them. Note the token also rides in
  consumer-visible `RoomJoinedInfo.raw`/`to_dict()` and `DecodedEvent.raw`;
  document to game teams that logging whole payloads leaks it.

## Manual reconnect

- `reconnect(player_id, room_id, auth_token)` opens a fresh transport and
  sends `Reconnect` on open instead of `Authenticate`. Guards: unconfigured,
  active connection, empty args, missing endpoint.
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
- Backoff (PLAN §4.7 constants): base 0.5s, factor 2, cap 15s, jitter
  fraction 0.25, budget `config.reconnect_max_attempts` (default 5). A failed
  dial emits `connection_failed` (the transport failure) and then arms the
  next attempt; when the budget is exhausted, a final "auto-reconnect
  exhausted" `connection_failed` follows the last attempt's failure and
  retrying stops. A successful baseline resets the budget; so does any fresh
  dial (`connect_to_server`/`reconnect`).
- Terminal `ReconnectionFailed` codes (`RECONNECTION_TOKEN_INVALID`,
  `RECONNECTION_EXPIRED`) clear the context and stop retrying;
  `RECONNECTION_FAILED` and other codes stay retryable. After any
  `ReconnectionFailed` the client tears the link down itself (emits
  `disconnected(-1, "reconnection failed")`), so consumers always observe a
  terminal disconnect and retryable auto-reconnects keep a clean scheduling
  point.
- All timing accumulates `_process(delta)` — no threads, no `OS.delay`, web
  safe. Tests inject deltas (`client._process(dt)`), never wall clocks.

## Testing rules

- Suite: `tests/client/run_reconnect_tests.gd` (wired into
  `scripts/run-runtime-checks.sh`).
- Backoff values are plan-locked: assert the scheduled delay against the
  `DELAY_BOUNDS` table instead of real time.
- Reconnect fixtures use placeholder tokens only (`TOKEN_V1`/`TOKEN_V2` in
  tests); never commit realistic tokens (PLAN §12).
- The vendored wire fixtures pre-date `reconnection_token`; decode tests cover
  presence, absence, and JSON null inline instead of editing the pinned
  fixtures (re-pin is tracked by issue #12).

## Open items

- `missed_events` ordering/dedup guarantees are not pinned to server source
  yet (PLAN §13.2); the client replays verbatim and dedups nothing.
- Upstream close-code conventions are unresolved (PLAN §13.8); auto-reconnect
  currently keys off "close was not user-initiated", not close codes.
