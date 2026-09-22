---
description: "Every Signal Fish server event as a snake_case signal, with typed payloads and decoded sentinels."
---

# Events

The client emits one snake_case signal per server event. Connect handlers,
then let the poll loop deliver events. Nothing arrives outside `poll()`.

```gdscript
var client := SignalFishClient.new()
add_child(client)

client.authenticated.connect(
    func(app_name, _org, _limits):
        print("authenticated: %s" % app_name)
        # Room commands require an authenticated session.
        var params := SignalFishClient.JoinRoomParams.new()
        params.game_name = "reef-rally"
        params.player_name = "Alice"
        client.join_room(params)
)
client.room_joined.connect(func(info): print("joined room %s" % info.room_code))
client.game_data_received.connect(func(from_player, data): print("%s: %s" % [from_player, data]))
```

## Lifecycle and transport

```gdscript
connected, disconnected(code, reason), connection_failed(error), protocol_error(error)
```

`protocol_error` is local and non-fatal; it never carries a server code.

## Authentication

```gdscript
authenticated(app_name, organization, rate_limits)
protocol_info(info)
authentication_error(error, error_code)
```

The `protocol_info` payload (`SFTypes.ProtocolInfo`) carries the server's
capability statement: `game_data_formats`, `player_name_rules`,
`capabilities`, the v3 `protocol_version` / `min_protocol_version` /
`max_protocol_version` / `transports` fields, and
`max_outbound_message_size` — the maximum complete encoded outbound
payload in bytes when the server states one (v3+; `0` = absent).

## Room lifecycle and presence

```gdscript
room_joined(info), room_join_failed(reason, error_code), room_left
player_joined(player), player_left(player_id), player_reconnected(player_id)
```

## Game data

```gdscript
game_data_received(from_player, data)
game_data_binary_received(from_player, encoding, payload: PackedByteArray)
```

## Authority and lobby

```gdscript
authority_changed(authority_player, you_are_authority)
authority_response(granted, reason, error_code)
lobby_state_changed(lobby_state, ready_players, all_ready)
game_starting(peer_connections)
```

## Heartbeat

```gdscript
pong
```

## Reconnection

```gdscript
reconnected(info, missed_events: Array)
reconnection_failed(reason, error_code)
```

## Spectators

```gdscript
spectator_joined(info), spectator_join_failed(reason, error_code)
spectator_left(room_id, room_code, reason, current_spectators)
new_spectator_joined(spectator, current_spectators, reason)
spectator_disconnected(spectator_id, reason, current_spectators)
```

## Generic server errors

```gdscript
server_error(message, error_code)
```

## v3 session plan

```gdscript
signal_received(from_player, generation, signal_payload)
new_peer(peer_id, you_initiate)
session_plan(plan)
peer_transport_status(peer_id, transport, connected)
```

These four signals only fire when `SignalFishConfig.protocol_version` is
set to a positive version (opt-in; `0` omits the capabilities and keeps the
v2 wire bytes) and the server negotiates a v3 session plan.

## Typed payloads and sentinels

- Structured payloads are typed `RefCounted` objects in `SFTypes` and
  `SFSessionTypes`, such as `PlayerInfo`, `RoomJoinedInfo`,
  `ConnectionInfo`, and `SessionPlanInfo`. Each is built from the wire
  dictionary on decode and exposes `to_dict()` plus a `raw` dictionary
  with the exact wire details.
- Closed sets are enums: `SFTypes.LobbyState`, `GameDataEncoding`,
  `RelayTransport`, `SpectatorReason`, `SFErrorCodes.Code`, and
  `SFSessionTypes.Topology` / `SFSessionTypes.TransportKind`.
- User game data stays `Variant`. Binary payloads are `PackedByteArray`.
- `raw` may share structure across `missed_events`, so treat it as
  read-only. `to_dict()` returns the independent mutable copy.

Optional wire values decode to stable sentinels:

| Wire value | Decoded as |
| --- | --- |
| Missing string | `""` |
| Missing array | Empty array |
| Unknown enum string | The owning enum's `UNKNOWN` member |
| Absent error code | `SFErrorCodes.Code.NONE` |
