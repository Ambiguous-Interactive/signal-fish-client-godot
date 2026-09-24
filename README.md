<p align="center">
  <img src="https://raw.githubusercontent.com/Ambiguous-Interactive/signal-fish-client-godot/main/docs/assets/logo-banner.svg" alt="Signal Fish Client SDK for Godot" width="640">
</p>

<p align="center">
  <a href="https://ambiguous-interactive.github.io/signal-fish-client-godot/"><img src="https://img.shields.io/badge/docs-GitHub%20Pages-blue?logo=github" alt="Documentation"></a>
  <a href="https://github.com/Ambiguous-Interactive/signal-fish-client-godot/releases"><img src="https://img.shields.io/github/v/release/Ambiguous-Interactive/signal-fish-client-godot" alt="Release"></a>
  <a href="https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/workflows/ci.yml"><img src="https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Godot-4.3%2B-478CBF?logo=godot-engine&logoColor=white" alt="Godot 4.3+">
  <a href="https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

A pure-GDScript client for the [Signal Fish](https://github.com/Ambiguous-Interactive/signal-fish-server)
protocol. Drop the `addons/signal_fish` folder into any Godot 4 project — no C#, no
GDExtension, no compilation — and it runs everywhere Godot runs, including web exports.

> **AI disclosure:** This project was developed with substantial assistance
> from Claude and Codex. Humans created the protocol concepts and core design
> and retained oversight of architecture and code review.

- **Protocol codec** for the Signal Fish v2 wire plus the v3 session-plan
  signaling surface: 14 client messages, 28 server events, the full v0.9.1
  error-code table (62 codes), MessagePack game data, strict binary game-data
  frames, and opt-in v3 peer-to-peer session plans — all pinned to upstream
  commits and covered by deterministic fixture tests.
- **Transport seam** with a `WebSocketPeer` adapter and a synchronous fake transport.
- **`SignalFishClient`** (`Node`): typed connect/authenticate/join/send/leave/reconnect
  API with one snake_case signal per server event. Polling model — no threads, web-safe.
- **Optional `SFWebRTCMesh`** (`Node`): v3 session plans in, `WebRTCMultiplayerPeer`
  mesh out — server-assigned offerer roles, ICE replacement, and teardown handled.

| | |
|---|---|
| Engine | Godot 4.3+ (GDScript) |
| Protocol | Signal Fish v2 + v3 session-plan signaling (fixtures pinned to upstream; drift-checked weekly) |
| License | [MIT](LICENSE) |

## Documentation

The [full guide](https://ambiguous-interactive.github.io/signal-fish-client-godot/)
covers everything from first connection to the P2P mesh:

- [Getting started](https://ambiguous-interactive.github.io/signal-fish-client-godot/getting-started/)
  and the [client API](https://ambiguous-interactive.github.io/signal-fish-client-godot/client/)
- [Events](https://ambiguous-interactive.github.io/signal-fish-client-godot/events/)
  and [errors](https://ambiguous-interactive.github.io/signal-fish-client-godot/errors/)
- [Game data](https://ambiguous-interactive.github.io/signal-fish-client-godot/game-data/)
  and [reconnection + replay](https://ambiguous-interactive.github.io/signal-fish-client-godot/reconnection/)
- [Web export](https://ambiguous-interactive.github.io/signal-fish-client-godot/web-export/)
  and the [mesh guide](https://ambiguous-interactive.github.io/signal-fish-client-godot/mesh-guide/)

## Installation

**Manual:** copy `addons/signal_fish/` into your project's `addons/` folder.

**Release archive:** every [release](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/releases)
tag ships the addon as a downloadable archive.

Asset Library listing: planned for the v1 release (one-time human submission;
the repo automates updates after that).

## Authentication primer

Signal Fish has two credentials and they are **not** the same kind of thing:

- **`app_id` is a public identifier**, not a secret — it routes the connection to your
  app's lobby namespace and is safe to ship in game builds.
- **Reconnection tokens are server-issued secrets.** The server mints one when you join
  a room and rotates it on every successful reconnect. Never log them, never commit
  them, never persist them without an explicit decision; treat them like session keys.
  `SignalFishClient` feeds every token it sees through its redacting logger
  (`addons/signal_fish/protocol/sf_log.gd`) — don't grow `print()` habits that leak
  envelopes containing tokens.

## Quick start

Add a `SignalFishClient` node, configure it, and drive it from signals:

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

var config := SignalFishConfig.new()
config.app_id = "my-app"                       # public identifier
config.endpoint_url = "wss://signal-fish.example/ws"
client.configure(config)
client.connect_to_server()
# The client auto-sends Authenticate when the socket opens; drive the
# session from signals from here on.
```

Once in the room: `client.send_game_data({"action": "move", "x": 30, "y": 40})`.

Prefer protocol-only use (no Node)? The codec is pure and static:

```gdscript
var envelope := SFMessages.authenticate("my-app")
var text := SFEnvelope.encode(envelope)                 # wire text frame
var event := SFEvents.decode_text(server_text_frame)    # -> typed event, never crashes
```

Optional features: MessagePack payload decoding (`config.decode_msgpack_payloads`),
binary game data (`send_game_data_binary`), directed reconnect with replay
(`reconnect()`), opt-in auto-reconnect with backoff (`set_auto_reconnect(true)`),
the v3 peer-to-peer signaling surface (set `config.protocol_version = 3`
plus `supported_transports`/`supported_topologies`), and the `SFWebRTCMesh`
node that turns those session plans into a working `WebRTCMultiplayerPeer`
mesh — signaling, offers, and ICE are handled for you; the server decides who
offers:

```gdscript
var mesh := SFWebRTCMesh.new()
add_child(mesh)
mesh.attach(client)
# Once a webrtc plan lands, run RPCs over the mesh:
multiplayer.multiplayer_peer = mesh.get_multiplayer_peer()
```

Godot 4 ships WebRTC on every platform (browser exports use the browser's own),
so the mesh needs no extra dependencies. The core server-relayed client stays
zero-native either way.

## Demo

`demo/main.tscn` is a runnable connect → join → game data → leave scene. Open
this project in the editor, press Play, fill in your server endpoint and app
id, then Connect → Join room. It is also the target of the "Web" export preset,
so it exports straight to a browser build.

`demo/p2p.tscn` is the same flow over the opt-in WebRTC mesh: it connects with
a v3 config, attaches `SFWebRTCMesh`, and chats over mesh RPCs once a webrtc
session plan lands. Run two instances (open the scene in the editor and play
the current scene) joining the same room to see the peer connection form.

## Development

```bash
bash scripts/run-runtime-checks.sh all    # private-helper guard, format, lint, 7 Godot suites
bash scripts/run-runtime-checks.sh smoke  # opt-in: real WebSocketPeer round-trip vs a local test server
```

Requires Godot 4.3+ and Python 3 with `requirements-ci.txt` (`gdtoolkit`). AI/agent
context lives in [.llm/context.md](.llm/context.md).
