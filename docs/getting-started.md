---
description: "Install the Signal Fish Godot client addon and make your first connect, join, and game-data exchange."
---

# Installation & Quick Start

Signal Fish is a pure-GDScript addon for Godot 4. There is no C#, no
GDExtension, and nothing to compile. The client runs everywhere Godot runs,
including web exports.

## Install

Copy `addons/signal_fish/` into your project's `addons/` folder.

An Asset Library listing is planned for the v1 release; until then, use a
manual copy.

!!! note "Enabling the plugin is optional"

    The addon ships an editor plugin for convenience only. The runtime
    classes are global as soon as the files are in your project, so you can
    use them without enabling anything in Project Settings.

## Configure

Create a `SignalFishConfig` resource and set the fields you need:

- `app_id`: required. A public identifier that routes the connection to
  your app's lobby namespace. It is not a secret and is safe to ship in
  game builds.
- `endpoint_url`: the WebSocket endpoint, for example
  `wss://signal-fish.example/ws`. You can also pass a URL to
  `connect_to_server()` at dial time.
- `game_data_format`: optional. Leave it unset (`""`) for JSON game data,
  or request `message_pack` for binary game data.

See [Client API Reference](client.md) for the full field list.

## Quick start

Add a `SignalFishClient` node, configure it, and drive the session from
signals:

```gdscript
var config := SignalFishConfig.new()
config.app_id = "my-game"
config.endpoint_url = "wss://signal-fish.example/ws"

var client := SignalFishClient.new()
add_child(client)
client.game_data_received.connect(func(from_player, data) -> void: print(data))
# Join only after `authenticated` fires: room commands are refused while the
# session is still unauthenticated, and the dial + Authenticate round-trip
# takes at least one poll cycle.
client.authenticated.connect(func() -> void:
    var params := SignalFishClient.JoinRoomParams.new()
    params.game_name = "checkers"
    params.player_name = "ana"
    client.join_room(params)
)
client.connect_to_server()  # dials endpoint_url, auto-sends Authenticate on open
```

Once in the room, send game data as plain JSON:

```gdscript
client.send_game_data({"action": "move", "x": 30, "y": 40})
```

## Polling model

The client is polled, not threaded:

- When `auto_poll` is `true` (the default), `poll()` runs from `_process`.
- Call `poll()` yourself in headless tools or custom loops.
- There are no threads and no blocking calls. The model is web-safe.

## Authentication primer

Signal Fish has two credentials, and they are not the same kind of thing:

- `app_id` is a public identifier. It routes the connection to your app and
  is safe to ship in game builds.
- Reconnection tokens are server-issued secrets. The server mints one when
  you join a room and rotates it on every successful reconnect. Never log
  them, never commit them, and never persist them without an explicit
  decision. Treat them like session keys.

`SignalFishClient` feeds every token it sees through its redacting logger
(`addons/signal_fish/protocol/sf_log.gd`). Do not grow `print()` habits
that leak envelopes containing tokens.

## Demo scenes

The demo project in this repository has two runnable scenes:

- `demo/main.tscn`: connect -> join -> game data -> leave. Open the project in
  the editor, press Play, fill in your server endpoint and app id, then
  Connect -> Join room. This scene is also the target of the "Web" export
  preset.
- `demo/p2p.tscn`: the same flow over the opt-in WebRTC mesh. It connects
  with a v3 config, attaches `SFWebRTCMesh`, and chats over mesh RPCs once
  a session plan lands. Run two instances joining the same room to see the
  peer connection form.

Both scenes run in the editor or headless. CI boots them headless on every
run.
