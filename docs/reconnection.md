---
description: "Reconnection tokens, directed reconnect with missed-event replay, and opt-in auto-reconnect backoff."
---

# Reconnection & Replay

Signal Fish rooms survive disconnects. The server issues a reconnection
token when you join a room, and a directed reconnect restores your seat
plus every event you missed.

## Reconnection tokens

The server mints a `reconnection_token` in the `RoomJoined` payload and
hands out a fresh one in every `Reconnected` payload. The latest token is
the only valid one. The value surfaces on `RoomJoinedInfo.reconnection_token`.

## Directed reconnect

`reconnect(player_id, room_id, auth_token)` opens a fresh transport and
restores your seat:

```gdscript
client.reconnect(player_id, room_id, saved_token)
```

The client authenticates first and sends the `Reconnect` message once
`Authenticated` arrives. Enforcing servers reject any pre-auth message, so
this handshake order is not optional.

Two dial details matter when you rotate tokens:

- The dial retargets the **last-dialed URL**, not `config.endpoint_url`.
- The dialed credentials become the retained auto-reconnect identity, so a
  rotated token always wins over a stale one if auto-reconnect later fires.

## Replay

On success the client emits `reconnected(info, missed_events)`:

- `info` carries the full room state, the same shape as `room_joined`.
- `missed_events` is decoded through the same decoder as live traffic.

On protocol v3, `info` also carries the server's replay contract:

- `info.replay_status` is `COMPLETE`, `TRUNCATED`, `UNAVAILABLE`, or
  `UNKNOWN` (v2 sessions; the server did not state a contract).
- `TRUNCATED`/`UNAVAILABLE` mean `missed_events` is a suffix or empty - resync from the `info` snapshot fields instead of replaying.
- `info.sender_watermarks` lists each sender's `(epoch, seq)` game-data
  tail, so a gap after reconnect is attributable to your absence or replay
  truncation, never silent relay loss.

You replay missed events yourself. The client never re-emits them as live
signals. Nested `Reconnected` entries inside `missed_events` are rejected
as non-replayable, and decode recursion is depth-bounded, so a hostile
server cannot overflow the script stack.

On failure the client emits `reconnection_failed(reason, error_code)`.

## Auto-reconnect

Auto-reconnect is off by default. Turn it on per client:

```gdscript
client.set_auto_reconnect(true)
```

When enabled:

- Retries use exponential backoff with jitter: base `0.5s`, factor `2`,
  cap `15s`.
- `reconnect_max_attempts` (default `5`) bounds the retry budget. Timing
  comes from `_process` deltas, so no threads or timers are involved.
- Only abnormal terminations are retried: a non-user-initiated close or a
  transport failure. A clean `close()` never starts the loop.
- A `4007` close (`kicked`) never retries and drops the saved identity: the
  server removes your reconnection record on kick, so a retry can never
  rejoin.
- Terminal codes stop retrying: `RECONNECTION_TOKEN_INVALID` and
  `RECONNECTION_EXPIRED`.
- A `ReconnectionFailed` tears the link down, so consumers always observe a
  terminal `disconnected` instead of a silent retry loop.
- Exhausting the budget ends in `connection_failed`.

## Token safety

Reconnection tokens are server-issued secrets. Every token the client sees
flows through its redacting logger (`sf_log.gd`), so tokens never reach
default logs. Keep them out of your own `print()` calls too, and persist
them only with an explicit, documented decision.
