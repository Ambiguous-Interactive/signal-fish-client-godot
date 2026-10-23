---
description: "How the deterministic Godot test suite works, what it covers, and how to run it locally."
---

# Deterministic Testing

The test suite has no framework dependency and no network. Custom
`SceneTree` runners under `tests/` run with `godot --headless --script` and
produce deterministic results:

- **Byte-pinned fixtures.** Codec tests compare exact bytes against
  fixture files.
- **Injected clocks.** Reconnect backoff tests step time manually. No
  sleeps, no wall-clock waiting.
- **Synchronous fake transport.** `SFFakeTransport` is an in-memory test
  double with injectors (`inject_open()`, `inject_text()`,
  `inject_server_message()`, `inject_binary()`, `inject_close()`,
  `inject_failure()`) and recorded `sent_text` / `sent_binary` buffers.

## Suites

- **Protocol fixtures.** The upstream v2 samples (server v0.9.2) are
  vendored byte-identically under `tests/fixtures/upstream/`, and the codec
  is pinned to them. Hand-built fixtures cover all 24 server message
  variants plus malformed input.
- **Transport.** The `WebSocketPeer` adapter runs against fakes for
  connect, receive, send, close, error, and backpressure behavior.
- **Client.** Connect, authenticate, join, game data, authority,
  spectators, reconnection, and the WebRTC mesh all run on fake transports
  and injected clocks.

## Run locally

```bash
python3 -E scripts/run-runtime-checks.py all
```

`all` runs the private-helper guard, GDScript and Python format/lint checks,
strict Python typing, the Prettier and markdownlint checks, and the Godot
suites. Subcommands for targeted runs:

- `static`: private-helper guard, format/lint, and Python types. No Godot install.
- `python-types`: Python format, lint, and strict types.
- `private-helpers`: the private-helper static guard.
- `format`: gdformat checks.
- `lint`: gdlint.
- `prettier`: the Prettier half of CI's Source formatting job. Needs `npm ci --ignore-scripts` first.
- `markdownlint`: the markdownlint job of CI's Docs Validation. Same `npm ci` requirement. To autofix, run `python3 scripts/check-source.py markdownlint write`. The pin matches the version bundled by the `markdownlint-cli2-action` in docs-validation.yml - when bumping that action, re-pin `package.json` to its bundled version.
- `godot`: the SceneTree suites.

### Smoke (opt-in)

```bash
python3 -E scripts/run-runtime-checks.py smoke
```

`smoke` is never part of `all`. It drives a real `WebSocketPeer` round-trip
against a local RFC 6455 test server: open, echo round-trips, close
handshakes in both directions, and refused-dial failure.

## Type strictness

Every GDScript warning class the engine matrix registers is pinned to error
level in `project.godot` except three: `:=` type inference and discarded
return values stay ignorable by style, and the 4.7-only `missing_await`
stays unpinned because a marker naming it is a parse error on engines that
lack the class. The checks apply to the addon as well:
the engine default `exclude_addons` is explicitly disabled, so a warning
regression fails CI anywhere in the repo. The small set of statements that
are not yet fully typed carry an explicit `@warning_ignore` marker naming
exactly what they trigger: grep for `@warning_ignore` in `addons/` for the
live list.

## Live server acceptance (opt-in)

`tests/smoke/run_live_server_acceptance.gd` drives real Godot clients through
`SFWebSocketTransport`. Use an isolated local server. The drill creates rooms
and changes their membership. It requires a server with `spectator_relay`
and Direct endpoint refresh support.

The measured server source is
[`182cb234`](https://github.com/Ambiguous-Interactive/signal-fish-server/tree/182cb234c7aa601be3c2aad881948b3c5b853aaa).
Build it with its pinned Rust toolchain:

```bash
git clone https://github.com/Ambiguous-Interactive/signal-fish-server.git
cd signal-fish-server
git checkout 182cb234c7aa601be3c2aad881948b3c5b853aaa
cargo build --locked --bin signal-fish-server
cp config.example.json config.json
python3 - <<'PY'
import json
from pathlib import Path
path = Path("config.json")
config = json.loads(path.read_text())
config["session"]["default_topology"] = "host"
config["session"]["enable_webrtc"] = False
config["protocol"]["enable_rkyv_game_data"] = True
config["protocol"]["enable_protobuf_game_data"] = True
config["rate_limit"]["max_room_creations"] = 1000
config["rate_limit"]["max_join_attempts"] = 1000
path.write_text(json.dumps(config))
PY
./target/debug/signal-fish-server
```

From this client repository, in a second terminal:

```bash
godot --headless --path . --script tests/smoke/run_live_server_acceptance.gd
```

An optional argument after `--` selects the server base URL, for example
`-- ws://127.0.0.1:3536`. Success prints `LIVE_SERVER_ACCEPTANCE_PASS` and
exits zero. Each wait has an eight-second deadline and the drill has a
two-minute watchdog. A failed phase exits nonzero.

Godot 4.3 on Linux arm64 passed these live checks:

- Spectator baseline state is installed before its signal. Live player
  join/leave, lobby readiness, GameStarting and gameplay preserve spectator
  role. Voluntary leave clears the room and returns to authenticated state.
- Gameplay reaches spectators with the player's sender ID: v2/v3 JSON,
  MessagePack raw bytes and decoded values, and opt-in v3 rkyv/protobuf bytes.
  Raw binary signals carry the negotiated encoding.
- Two Direct clients receive each fresh shared plan after a host endpoint
  change, endpoint loss with a successor, and loss of the final endpoint.
  The Relay reset clears host, endpoint, peers and ICE state. Relay gameplay
  still arrives. Duplicate and non-host metadata keep the current generation;
  Pong replies provide processing barriers on both connections.

Additional drills use the same server setup:

```bash
godot --headless --path . --script tests/smoke/run_room_transition_acceptance.gd
godot --headless --path . --script tests/smoke/run_live_transport_reports.gd
```

The room transition drill queues 80 real receive packets before dispatch,
then pipelines spectator leave and join on one connection. It drains one
packet per poll and checks terminal/baseline order, payload order and sender,
room identity, new roster, and fresh gameplay after rejoining the first room.
It covers v2/v3 JSON and raw MessagePack. It also overlaps Direct host endpoint
updates with another player's join and leave. Current players converge on one
fresh endpoint and generation; each observed plan uses the current roster.
These overlapping socket requests do not force internal server race barriers.

The transport report drill uses a v3 reporter, a relay-only v3 observer, and a
v2 observer. It checks both state-transition orders, duplicate suppression,
self/v2 exclusion, and fresh report state after reconnect. Gameplay on the
same connection provides a processing barrier and confirms relay delivery.
It covers serial WebSocket dispatch. Concurrent embedded-host dispatch remains
open in [#367](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/367).
The drill exposed the peer roster limitation in
[#374](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/374).

All three drills passed on Godot 4.3 Linux arm64 against the pinned server
above. They accept the same optional base URL. Each phase has an eight-second
deadline; the room transition watchdog is two minutes and the transport report
watchdog is one minute. A failed phase exits nonzero.

Server queue saturation, latest/volatile delivery, forced concurrent
publication, reconnect/authority spectator histories and injected server detach
failures remain separate acceptance work. These drills are opt-in and outside
`all`. The [mesh drill](mesh-guide.md#live-channel-drill) checks native and
browser WebRTC packet boundaries separately.
