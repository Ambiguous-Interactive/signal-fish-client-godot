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

```
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
