---
description: Use when planning or reviewing the runtime addon architecture, layer boundaries, state machines, polling model, or decode policy.
triggers: runtime architecture, layers, state machine, polling, transport seam, decode, backpressure, cleanup, addon layout, web-safe
category: Core
---

# Runtime Architecture

The addon (`addons/signal_fish/`) has three hard layers with one-way
dependencies: **API → protocol (pure/static) ⟂ transport (I/O)**. The client
Node is the only place protocol and transport meet. Everything is driven from
`_process()`/`poll()`; no threads, no blocking — web-safe by construction.

## Layer map

```text
addons/signal_fish/
  signal_fish_client.gd     # class_name SignalFishClient (Node) — PUBLIC API
  signal_fish_config.gd     # class_name SignalFishConfig (Resource)
  plugin.cfg / plugin.gd / icon.png / README.md / LICENSE
  protocol/                 # PURE static; no Node, no transport imports
    sf_envelope.gd          #   {type,data} <-> JSON
    sf_messages.gd          #   builders for the client messages (12 v2 + v3
                            #   signal/transport-status)
    sf_events.gd            #   server Dictionary -> SFDecodedEvent (malformed-safe)
    sf_types.gd             #   typed value objects + enums
    sf_type_utils.gd        #   shared decode depth cap + Variant coercion helpers
    sf_session_types.gd     #   v3 session-plan value objects + enums
    sf_game_data_format.gd  #   pure game-data-format negotiation
    sf_error_codes.gd       #   enum Code + string<->code + category()
    sf_binary_codec.gd      #   byte-array/base64 compatibility
    sf_binary_frames.gd     #   strict v2/v3 binary game-data envelope decode
    sf_msgpack.gd           #   MessagePack encode/decode (opt-in)
    sf_log.gd               #   leveled logger w/ token/id redaction
  transport/                # byte/text oriented; NO protocol parsing
    sf_transport.gd         #   abstract base (signals + method contract)
    sf_websocket_transport.gd  # Godot 4 WebSocketPeer impl
    sf_websocket_peer_adapter.gd  # injectable WebSocketPeer seam
    sf_fake_transport.gd    #   deterministic in-memory test double
  webrtc/                   # OPTIONAL P2P helper, out of the core path
    sf_webrtc_mesh.gd       #   session_plan + signals -> WebRTCMultiplayerPeer
```

Never let `protocol/` import transport or Node types; never parse protocol
payloads inside `transport/`.

## Polling model

- One `socket.poll()` per `poll()`, then drain up to
  `max_inbound_packets_per_poll` (default 64); overflow waits for next tick.
- No `OS.delay`, no timers with threads, no awaits in addon runtime code; use
  accumulated process deltas.
- Sends are guarded by backpressure: `get_buffered_amount() >
  max_buffered_bytes` → `ERR_BUSY` + `protocol_error`, nothing queued.
- Frames over `max_inbound_frame_bytes` are dropped pre-parse with
  `protocol_error`.

## State machines

- `ConnectionState`: DISCONNECTED (idle) → CONNECTING → CONNECTED → CLOSING →
  CLOSED (observed close frame) / FAILED (client abstraction). Keep polling
  while CLOSING to capture close code/reason; `-1` maps through as-is.
- `SessionState`: UNAUTHENTICATED → AUTHENTICATING → AUTHENTICATED →
  IN_ROOM_WAITING/LOBBY/FINALIZED or SPECTATING. Lobby transitions are
  **server-driven** (`RoomJoined`/`LobbyStateChanged`/`Reconnected`); the
  client never self-promotes. `GameStarting` does not change session state.
- Reconnect opens a fresh transport, authenticates, then sends `Reconnect`
  once `Authenticated` arrives (enforcing servers reject pre-auth messages).
  On `Reconnected`, restore cached state, decode `missed_events` through the
  normal decoder, and emit `reconnected(info, missed_events)` — no hidden
  re-emit; consumers replay.

## Signals are synchronous: audit every emit site

Godot signal emission re-enters consumer code before `emit` returns; a
handler may call any public API (`close`, `reconnect`, `mesh.detach`). The
review rounds that found the mesh status-boundary bugs and the exhaustion
clobber generalized into standing rules:

- Never write state after an `emit` in the same function unless the write is
  proven harmless against handler mutations. The exhaustion path once wiped
  the retained reconnect identity *after* emitting `connection_failed`,
  clobbering the fresh identity a handler had just captured by redialing
  inside the notice. Either move the write before the emit or guard it on
  the pre-emit condition still holding (e.g. "no dial is in flight").
- Every armed/deadline/latched piece of state (`_reconnect_timer_running`,
  `_reported_connected`, `_status_retry_due_msec`, per-dial latches) must be
  invalidated on three axes: the triggering edge resolving itself (state
  flap back), teardown running re-entrantly from a handler mid-operation,
  and a session swap (a fresh dial must not inherit the old session's
  deadline).
- A refused send retried from a per-frame loop (`poll`/`_process`) must
  throttle retries to one per interval — the heartbeat's backpressured-beat
  rule — with the interval injectable for deterministic tests. One refused
  send is one diagnostic; a stalled link must not flood `protocol_error`
  once per frame.
- Pin each rule with a handler-re-entry test: redial/flap from *inside* the
  handler, kill the follow-up dial pre-baseline, assert the retained
  identity and the next scheduling step. See
  `_test_redial_from_exhaustion_handler_keeps_the_fresh_identity`
  (reconnect) and the mesh backpressure/flap test.

## Decode policy

- Decode never crashes: parse failure, missing/unknown type, or wrong shapes
  emit `protocol_error` and keep the connection.
- Recursion is depth-bounded (`MAX_MESSAGE_DEPTH`); nested `Reconnected`
  entries inside `missed_events` are rejected (matches the Rust client).
- Decode output aliases one freshly parsed envelope tree; `raw` is a
  read-only view, `to_dict()` returns an independent mutable copy.
- Optional upstream values surface as stable sentinels: missing strings `""`,
  missing arrays empty, unknown enum strings `UNKNOWN`, absent error codes
  `Code.NONE`. Open payloads (`GameData.data`) preserve JSON `null`.
- Outbound optional fields are omitted when unset (never JSON `null`).

## Transport seam

- `SFTransport` (RefCounted): `opened`/`packet_received(payload, is_text)`/
  `closed(code, reason)`/`failed(error)` plus `connect_to_url`/`poll`/`send_text`/
  `send_binary`/`get_buffered_amount`/`get_ready_state`/`close`.
- `SFWebSocketTransport` wraps `WebSocketPeer` through
  `sf_websocket_peer_adapter.gd` (injectable for tests); emits `opened` once,
  emits `closed` once with code/reason, treats post-open read/send failures as
  terminal `failed`.
- `SFFakeTransport` powers deterministic client tests: injected open/text/
  binary/close/failure, recorded sends, no network or timers.

## WebRTC mesh (opt-in)

`SFWebRTCMesh` consumes `session_plan` + `signal_received`, answers with
`send_signal` (offers only when the server says `initiate`), applies
`ice_servers` as a replacement set, rebuilds peers on plan/role change, tears
down on room/peer/disconnect events, and exposes a `WebRTCMultiplayerPeer`.
Relay-only users pay nothing.

## Verification shape

| Layer | Suite |
|---|---|
| Protocol codec (F) | `tests/protocol/` fixtures, byte-pinned to upstream samples |
| Transport (K) | `tests/transport/` fake + adapter tests |
| Client (K) | `tests/client/` (incl. reconnect, binary, v3, mesh) |
| Real socket (S, opt-in) | `tests/smoke/` via `run-runtime-checks.sh smoke` |

Fast gates stay deterministic: fake transports, injected clocks, byte-pinned
fixtures, no live network.
