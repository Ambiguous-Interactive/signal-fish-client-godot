# Signal Fish — Godot 4 Client

A pure-GDScript client for the [Signal Fish](https://github.com/Ambiguous-Interactive) protocol:
a `SignalFishClient` node you drop into any Godot 4 scene, connect, and drive through typed methods
and signals. No C#, no native extensions, no compilation — it runs everywhere Godot runs,
including web exports.

## Status

In active development. The wire-protocol codec (all 11 client messages, 24 server messages,
error codes, fixtures pinned to upstream commits) and the core client (connect, authenticate,
join, send/receive, leave, close — with state machines, frame caps, and backpressure) are done.
Remaining roadmap: reconnection/replay, MessagePack, WebRTC helper, demo project, Asset Library
release. See [PLAN.md](PLAN.md) for the full plan and current phase.

## Requirements

- Godot 4.3 or newer (tested on 4.3; see `.github/workflows/ci.yml` for the current matrix).

## Installation

1. Copy `addons/signal_fish/` into your project (or install from the Godot Asset Library once
   listed).
2. Create a `SignalFishConfig` resource with your `app_id` and pass it to the client.

```gdscript
var config := SignalFishConfig.new()
config.app_id = "your-app-id"

var client := SignalFishClient.new()
add_child(client)
client.configure(config)
client.connect_to_server("wss://your-server.example/socket")

client.room_joined.connect(func(info) -> void:
    print("joined %s" % info.room_code))
client.send_game_data({"move": "left"})
```

## Authentication primer

- **`app_id` is a public identifier.** It is safe to ship in game builds; it identifies your game
  to the Signal Fish server and is not a secret.
- **Reconnection tokens are secrets.** The server issues them for `Reconnect`; never log them,
  never commit them, and expect the server to rotate them.
- **Log through the redacting logger.** The addon ships `sf_log.gd`, which redacts credentials and
  tokens before output. Avoid `print()`ing raw protocol envelopes: once reconnection support
  lands, payloads will contain secrets.
- Production endpoints use `wss://`. The client refuses `ws://` on web builds inside secure pages
  (browsers block mixed content) instead of failing silently.

## Development

```bash
bash scripts/run-runtime-checks.sh all   # format + lint + headless Godot tests
```

Protocol behavior is pinned to upstream Signal Fish repos and commits; see
`.llm/research/protocol-fixtures.md`.

## License

[MIT](LICENSE)
