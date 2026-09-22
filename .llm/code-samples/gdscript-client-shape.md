---
description: Map of the shipped GDScript-facing Signal Fish client API (mirrors the runtime addon).
triggers: gdscript, client, runtime client, SignalFishClient, connect, connection, client api, signals, websocket, WebSocketPeer, Godot 4, example, config, addon
category: Code Sample
---

# GDScript Client Shape

The runtime addon ships `SignalFishClient` (Node) and `SignalFishConfig`
(Resource) under `addons/signal_fish/`. This page maps the shipped API for AI
context; PLAN.md §4.2 is the design record. Everything is polled: call `poll()`
(or leave `auto_poll` on) — no threads, no blocking, web-safe.

## Minimal usage

```gdscript
var config := SignalFishConfig.new()
config.app_id = "my-game"
config.endpoint_url = "wss://signal-fish.example/ws"

var client := SignalFishClient.new()
add_child(client)
client.room_joined.connect(func(info) -> void: print("joined ", info.room_id))
client.game_data_received.connect(func(from_player, data) -> void: handle(data))
client.connect_to_server()  # dials endpoint_url, auto-sends Authenticate on open
# Room commands are refused until the server answers Authenticate: join from
# the `authenticated` signal, not synchronously after the dial.
client.authenticated.connect(func(_app, _org, _limits) -> void:
    var params := SignalFishClient.JoinRoomParams.new()
    params.game_name = "checkers"
    params.player_name = "ana"
    client.join_room(params)
)
```

## Config (`SignalFishConfig`)

- Identity: `app_id` (required), `sdk_version`, `platform`.
- Transport: `endpoint_url` (optional override), `auto_poll` (default true).
- Game data: `game_data_format` (`""`/`json`/`message_pack`/`rkyv`),
  `decode_msgpack_payloads` (default false).
- Limits: `max_inbound_frame_bytes`, `max_buffered_bytes` (backpressure),
  `max_inbound_packets_per_poll` (all default ~256 KiB / 64).
- Reconnect: `reconnect_max_attempts` (default 5).
- Heartbeat (off by default): `heartbeat_interval_sec` (0 = off),
  `pong_timeout_sec` — a silent link past the deadline is torn down as a
  transport failure, so opt-in auto-reconnect can engage.
- v3 session plan (omit to keep v2 wire bytes identical): `protocol_version`,
  `supported_transports`, `supported_topologies`, `requested_capabilities`.
- `credential`: set in code only (never exported/persisted/serialized); rides
  `Authenticate` as `connect_token`.

## Lifecycle & state (`SignalFishClient`)

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
func get_spectators() -> Array                  # Array[SFTypes.SpectatorInfo]
func get_buffered_amount() -> int
```

`is_connected()` is `is_connected_to_server()`: Godot's `Object.is_connected`
cannot be shadowed. The static `insecure_scheme_error(url, is_web_platform,
secure_page)` predials `ws://`-from-HTTPS checks so browser mixed-content is a
loud local error.

## Send methods

Each returns `Error`; room commands require authentication (pre-auth emits
`protocol_error` and returns `ERR_UNAUTHORIZED`, nothing is sent). The 12 v2
client messages map to these (Authenticate is sent automatically on open);
`send_signal`/`send_transport_status` are the v3 additions, and
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
func send_transport_status(transport_kind: int, connected: bool) -> Error
```

## Signals (one per server event)

```gdscript
# lifecycle / transport-derived
connected, disconnected(code, reason), connection_failed(error), protocol_error(error)
# authentication
authenticated(app_name, organization, rate_limits), protocol_info(info)
authentication_error(error, error_code)
# room lifecycle + presence
room_joined(info), room_join_failed(reason, error_code), room_left
player_joined(player), player_left(player_id), player_reconnected(player_id)
# game data
game_data_received(from_player, data)
game_data_binary_received(from_player, encoding, payload: PackedByteArray)
# authority + lobby
authority_changed(authority_player, you_are_authority)
authority_response(granted, reason, error_code)
lobby_state_changed(lobby_state, ready_players, all_ready)
game_starting(peer_connections)
pong
# reconnection
reconnected(info, missed_events: Array), reconnection_failed(reason, error_code)
# spectators
spectator_joined(info), spectator_join_failed(reason, error_code)
spectator_left(room_id, room_code, reason, current_spectators)
new_spectator_joined(spectator, current_spectators, reason)
spectator_disconnected(spectator_id, reason, current_spectators)
# generic
server_error(message, error_code)
# v3 session plan (opt-in config capabilities)
signal_received(from_player, generation, signal_payload)
new_peer(peer_id, you_initiate)
session_plan(plan)
peer_transport_status(peer_id, transport, connected)
```

## Value objects & enums

- Typed `RefCounted` payloads in `SFTypes`/`SFSessionTypes` (`PlayerInfo`,
  `RoomJoinedInfo`, `ConnectionInfo`, `SessionPlanInfo`, ...) built from the
  wire dictionary on decode, with `to_dict()` and a `raw` dictionary for
  exact wire details.
- Closed sets are enums: `SFTypes.LobbyState`, `GameDataEncoding`,
  `RelayTransport`, `SpectatorReason`; `SFErrorCodes.Code`;
  `SFSessionTypes.Topology`/`TransportKind`.
- Optional wire values surface as decoded sentinels: missing strings → `""`,
  missing arrays → empty, unknown enum strings → `UNKNOWN`, absent error codes
  → `SFErrorCodes.Code.NONE`.
- User game data stays `Variant`; binary is `PackedByteArray`.

## Behavior notes

- Sends are backpressured: over `max_buffered_bytes` → `ERR_BUSY` +
  `protocol_error`, nothing queued.
- Frames over `max_inbound_frame_bytes` are dropped with `protocol_error`.
- Malformed input never crashes: decode failures emit `protocol_error` and
  keep the connection.
- Auto-reconnect (opt-in) retries abnormal terminations with exponential
  backoff + jitter; terminal codes stop retrying; a `ReconnectionFailed` tears
  the link down so consumers always observe a terminal disconnect.
- The optional heartbeat (`heartbeat_interval_sec`) pings while connected +
  authenticated; a missing `pong` past `pong_timeout_sec` is treated as a
  dead link (silent link death produces no WebSocket close).
- Logs redact tokens/ids by default (`sf_log.gd`).
