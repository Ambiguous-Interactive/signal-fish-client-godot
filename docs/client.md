---
description: "SignalFishClient and SignalFishConfig API reference for the Signal Fish Godot client addon."
---

# Client API Reference

The runtime addon ships two public classes under `addons/signal_fish/`:

- `SignalFishClient` (`Node`): typed connect, authenticate, join, send,
  leave, and reconnect API. One snake_case signal per server event.
- `SignalFishConfig` (`Resource`): a configuration resource you can author
  in the editor or build in code.

## Configuration fields

| Group           | Field                          | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Identity        | `app_id`                       | Required public identifier.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Identity        | `sdk_version`                  | Optional SDK version string.                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Identity        | `platform`                     | Optional platform string.                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Transport       | `endpoint_url`                 | Optional override; `connect_to_server(url)` also takes one.                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Transport       | `auto_poll`                    | Default `true`; runs `poll()` from `_process`.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Game data       | `game_data_format`             | `""` (JSON), `json`, `message_pack`, or the opaque `rkyv`/`protobuf` pass-through encodings (v3-only; fall back to JSON when unadvertised or when the server negotiates v2).                                                                                                                                                                                                                                                                                                    |
| Game data       | `decode_msgpack_payloads`      | Default `false`. Opt-in MessagePack decode.                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Limits          | `max_inbound_frame_bytes`      | Frames over this are dropped (~256 KiB default).                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Limits          | `max_buffered_bytes`           | Send backpressure threshold (~256 KiB default).                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Limits          | `max_outbound_frame_bytes`     | One outbound text/binary frame over this is refused locally (64 KiB default, the upstream server default).                                                                                                                                                                                                                                                                                                                                                                      |
| Limits          | `max_inbound_packets_per_poll` | Default `64`; overflow moves to the next tick.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Reconnect       | `reconnect_max_attempts`       | Default `5`. Budget for auto-reconnect.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Heartbeat       | `heartbeat_interval_sec`       | Default `0` (off). Seconds between automatic `Ping`s while connected + authenticated.                                                                                                                                                                                                                                                                                                                                                                                           |
| Heartbeat       | `pong_timeout_sec`             | Default `10`. A silent link past this is torn down as a failure - after a heartbeat ping, during authentication where pings are not allowed, after a mid-session authentication error, or while a close handshake pends - so auto-reconnect can engage. The authentication, post-error, and close deadlines run even with the heartbeat off. A beat refused by backpressure arms the same deadline; the beat retries each interval and the deadline clears once a `Pong` lands. |
| v3 session plan | `protocol_version`             | Set to `3` to opt in to the v3 surface.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| v3 session plan | `supported_transports`         | Capability list.                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| v3 session plan | `supported_topologies`         | Capability list.                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| v3 session plan | `requested_capabilities`       | Capability list.                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Credential      | `credential`                   | Code only. Rides `Authenticate` as `connect_token`.                                                                                                                                                                                                                                                                                                                                                                                                                             |

!!! note "Heartbeat needs the tree"

    Like the auto-reconnect backoff, the heartbeat runs from `_process`:
    keep the client node in the scene tree (or drive the ticks yourself)
    when you enable it.

!!! note "v3 fields are additive"

    The v3 session-plan fields are omitted when unset, so v2 wire bytes stay
    identical to a plain v2 client.

`credential` is set in code only. It is never exported, persisted, or
serialized by the `Resource` pipeline, and the logger redacts it.

`join_room()` takes a `SignalFishClient.JoinRoomParams` object with the
fields `game_name`, `player_name`, `room_code`, `max_players`,
`supports_authority`, `relay_transport`, and `password`.

## Lifecycle and state

```gdscript
func configure(config: SignalFishConfig) -> Error
func connect_to_server(url := "") -> Error   # auto-sends Authenticate on open
func reconnect(player_id: String, room_id: String, auth_token: String) -> Error
func set_auto_reconnect(enabled: bool) -> void  # default OFF
func poll() -> void
func close(code := 1000, reason := "") -> Error
func is_connected_to_server() -> bool
func is_authenticated() -> bool
func get_connection_state() -> ConnectionState  # DISCONNECTED/CONNECTING/CONNECTED/CLOSING/CLOSED/FAILED
func get_session_state() -> SessionState        # UNAUTHENTICATED/.../IN_ROOM_*/SPECTATING
func get_player_id() -> String
func get_room_id() -> String
func get_room_code() -> String
func get_lobby_state() -> int                   # SFTypes.LobbyState
func get_players() -> Array                     # Array[SFTypes.PlayerInfo]
func get_authority_player() -> String           # "" while nobody holds authority
func get_spectators() -> Array                  # Array[SFTypes.SpectatorInfo]
func get_buffered_amount() -> int
```

Cached rosters (players, spectators) and mesh peers stay capped at 256
entries (`SFTypeUtils.MAX_TRACKED_PEERS`). Excess entries from a hostile
or misbehaving relay are dropped: rosters surface one `protocol_error`
per event, and the mesh logs an error. The session stays live.

## Send methods

Each method returns `Error`. The 12 v2 client messages map to these
methods; `Authenticate` is sent automatically when the socket opens.
`send_signal` and `send_transport_status` are the v3 additions.
`send_game_data_binary` rides the negotiated binary-frame route.

```gdscript
func join_room(params: JoinRoomParams) -> Error
func leave_room() -> Error
func send_game_data(data) -> Error
func send_game_data_binary(bytes: PackedByteArray) -> Error
func set_ready() -> Error
func start_game() -> Error
func request_authority(become_authority: bool) -> Error
func provide_connection_info(info: SFTypes.ConnectionInfo) -> Error
func ping() -> Error
func join_as_spectator(game_name: String, room_code: String, spectator_name: String, password := "") -> Error
func leave_spectator() -> Error
func send_signal(to_peer: String, generation: String, signal_payload) -> Error
func send_transport_status(transport_kind: int, is_up: bool) -> Error
```

Room commands require an authenticated session. Sending one before
authentication emits `protocol_error`, returns `ERR_UNAUTHORIZED`, and
sends nothing.

`send_signal` and `send_transport_status` also require a negotiated v3
connection. `send_signal` further requires the latest `session_plan`:
the generation must equal the current plan's. No signal can be sent
before a plan arrives, after the room or dial ends, or after a fresh
baseline until the next plan. Each refusal emits `protocol_error`,
returns an `Error`, and sends nothing - a dropped frame would only
surface as a generic server error while the peer waits.

## State machines

```gdscript
enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, CLOSING, CLOSED, FAILED }
enum SessionState { UNAUTHENTICATED, AUTHENTICATING, AUTHENTICATED, IN_ROOM_WAITING, IN_ROOM_LOBBY, IN_ROOM_FINALIZED, SPECTATING }
```

Lobby transitions are server-driven. The client never self-promotes its
session state.

## Behavior notes

- Sends are backpressured. Over `max_buffered_bytes`, a send returns
  `ERR_BUSY`, emits `protocol_error`, and queues nothing.
- Frames over `max_inbound_frame_bytes` are dropped with `protocol_error`.
- One outbound text/binary frame over `max_outbound_frame_bytes` is refused
  with `protocol_error` and `ERR_INVALID_DATA`, and nothing is queued. The
  default matches the upstream server's default inbound cap (64 KiB): the
  server drops an oversized text frame as `MessageTooLarge` and the action
  is lost; a binary frame it cannot verify ends the session.
- Malformed input never crashes the client. Decode failures emit
  `protocol_error` and keep the connection.
- Repeated JSON keys in an inbound text frame are rejected with
  `protocol_error` (the engine's parser silently keeps the last one;
  upstream rejects duplicates).
- Duplicate keys in a decoded MessagePack payload are rejected with
  `protocol_error` (raw bytes still surface), matching the JSON rule.
- Logs redact tokens and ids by default (`sf_log.gd`).

## The `is_connected_to_server()` rename

`is_connected()` became `is_connected_to_server()`. Godot owns
`Object.is_connected(signal, callable)`, so it cannot be shadowed.
`is_connected_to_server()` reports the transport state `CONNECTED`.
