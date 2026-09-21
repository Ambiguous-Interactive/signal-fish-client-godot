# Signal Fish (Godot 4)

Pure GDScript client for the [Signal Fish](https://github.com/Ambiguous-Interactive/signal-fish-server) protocol.

- `SignalFishClient` node: connect, join, send/receive game data, leave.
- Reconnection + missed-event replay, MessagePack game data (opt-in).
- Optional `SFWebRTCMesh` for P2P play on negotiated v3 plans.
- No threads, no blocking calls: works in web exports.

## Install

Copy `addons/signal_fish/` into your project, then enable the plugin in
Project Settings → Plugins (or use the classes directly — no enable needed).

## Quick start

```gdscript
var config := SignalFishConfig.new()
config.app_id = "my-game"
var client := SignalFishClient.new()
add_child(client)
client.configure(config)
client.connect_to_server("wss://your-server.example/ws")
```

Full docs, demo scenes, and tests live in the
[repository](https://github.com/Ambiguous-Interactive/signal-fish-client-godot).

## License

MIT — see [LICENSE](LICENSE).
