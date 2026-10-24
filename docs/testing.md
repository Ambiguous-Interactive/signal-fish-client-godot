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

The recovery drill adds spectator authority, readiness, detach replay, and
Direct reconnect histories:

```bash
godot --headless --path . --script tests/smoke/run_live_recovery_acceptance.gd
```

Against the same pinned server, Godot 4.3 Linux arm64 passed four spectator
cases: v2/v3 observers with JSON/raw MessagePack and a v3 reconnecting player.
Observers receive authority release/transfer, current cached readiness and
peer return notifications while retaining the spectator role. After a second
player disconnect, a viewer leaves. The viewer receives one
terminal reply with room identity and reason, clears its session and retained
identity, and connected players remove it from their roster. The returning
player receives one decoded detach event in replay with the same identity,
reason and terminal roster. Replay emits no live detach signal. A fresh
spectator join receives the restored roster and gameplay from the returning
player. The pinned server pre-issues reconnect credentials only on v3; these
cases do not claim v2 directed reconnect coverage.

Two further reconnect cycles overlap a Direct host endpoint update with peer
reconnect. Both clients converge on the new endpoint and shared generation.
Each fresh plan follows the reconnect baseline, the current credential rotates,
and relay gameplay resumes. These are overlapping socket requests; they do not
force an internal publication race. The incumbent roster limitation in #374
remains open.

The recovery drill uses the same optional base URL, eight-second waits and
two-minute watchdog. Success prints `LIVE_SERVER_ACCEPTANCE_PASS`; any failed
phase exits nonzero. It passed against the pinned server above. Ordinary
voluntary detach and replay are covered. Correlated recovery results and
authoritative removal still need live fixtures for #356. The fault and drain drill below covers both local
completion panic points and terminal-before-close ordering.

Server queue saturation, latest/volatile delivery and forced concurrent
publication remain separate acceptance work.
These drills are opt-in and outside
`all`. The [mesh drill](mesh-guide.md#live-channel-drill) checks native and
browser WebRTC packet boundaries separately.

The pressure drill adds two-sender fan-in and selected-host departure:

```bash
godot --headless --path . --script tests/smoke/run_live_pressure_acceptance.gd
```

It passed on Godot 4.3 Linux arm64 against server `182cb234`. Four v2/v3
JSON/raw MessagePack cases queue 80 real socket frames at an incumbent
spectator while a second spectator joins. Dispatch drains one frame per poll.
Checks cover exact sender counts, per-sender order, one membership delta,
baseline-before-data, cached rosters and fresh gameplay. v2 carries the full
roster in membership deltas; v3 carries compact deltas with an empty roster
array (`src/websocket/sending.rs` at the pinned server commit). This measures client
receive backlog. Server queue saturation and latest/volatile delivery remain
open in #368.

A three-player Direct case removes the selected host. Both survivors receive
a fresh shared generation and the successor's endpoint. Removing the remaining
endpoints produces a shared Relay reset with no host, endpoint, peers or ICE.
Plan callbacks see the reset and relay gameplay succeeds. Controlled publication is covered by the drill below. Game-owned Direct
socket teardown remains open in #358.

For #356, apply the local-only
[`spectator_detach_fault.patch`](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/2c6224599a4460e18bbc00ed0872138d60b43be0/tests/fixtures/spectator_detach_fault.patch)
to an isolated checkout of server
`182cb234c7aa601be3c2aad881948b3c5b853aaa`. Build with Rust 1.94.0. The patch
inserts assertions inside the existing caught local-completion transaction.
Use it only for acceptance. It adds no fault switch to the shipped addon.

```bash
# From the isolated server checkout, with the config above:
git apply /path/to/signal-fish-client-godot/tests/fixtures/spectator_detach_fault.patch
cargo build --locked --bin signal-fish-server
SF_GODOT_DETACH_FAULT=after_remove SIGNAL_FISH__SERVER__DRAIN_GRACE_SECS=2 \
  target/debug/signal-fish-server
# In another terminal, from the Godot client checkout:
godot --headless --path . --script tests/smoke/run_live_recovery_acceptance.gd
```

Repeat with `SF_GODOT_DETACH_FAULT=after_local`. Each mode passed all four
spectator recovery cases and the two Direct reconnect cycles. Server logs
confirmed the chosen fault and local recovery. The existing recovery oracle
checks exactly one terminal reply, live roster removal and replay detach,
room identity, reason, retained identity cleanup and fresh spectator gameplay.
These injections exercise the upstream repair; a request-triggered panic is
unproven. The controlled drill below covers registration retry/exhaustion.
Authoritative removal remains open.

The same isolated server can then run the drain case:

```bash
godot --headless --path . --script tests/smoke/run_live_pressure_acceptance.gd \
  -- ws://127.0.0.1:3536 drain
```

When it prints `LIVE_DRAIN_READY`, send SIGTERM to that server process within
eight seconds. The drill has already queued the spectator terminal reply at
the engine peer. Both fault modes passed the exact signal order
`SpectatorLeft`, `GoingAway`, `disconnected` with close code 4000 and cleared
room/identity state. The server uses a two-second grace for this drill.
Correlated recovery payloads retain their deterministic client coverage;
correlated live admission remains unsupported. These drills are opt-in.

## Controlled lifecycle publication

`tests/smoke/run_controlled_lifecycle_acceptance.gd` adds local server barriers
for #356, #358 and #367. Use an isolated server checkout at
`182cb234c7aa601be3c2aad881948b3c5b853aaa`, the config above, and Rust 1.94.0.
Apply only `tests/fixtures/controlled_lifecycle.patch` for this drill.

```bash
# From the isolated server checkout:
git apply /path/to/signal-fish-client-godot/tests/fixtures/controlled_lifecycle.patch
cargo build --locked --bin signal-fish-server
export SF_GODOT_BARRIER_DIR="$(mktemp -d)"
printf '%s\n' "$SF_GODOT_BARRIER_DIR"
SF_GODOT_BARRIER_DIR="$SF_GODOT_BARRIER_DIR" target/debug/signal-fish-server
# In another terminal, from the Godot client checkout, set the printed path:
export SF_GODOT_BARRIER_DIR=/path/printed/above
godot --headless --path . --script tests/smoke/run_controlled_lifecycle_acceptance.gd
```

Run one drill per server and barrier directory. The server consumes `.arm`
files, writes `.reached` files and waits for `.release` files. Each server
wait has a 15-second limit. Each client wait has an eight-second limit and
the full drill has a watchdog. Client cleanup releases held publication
barriers. After testing, stop the server, remove the barrier directory and
reverse the patch with `git apply -R`. Rebuild before using that checkout
for ordinary server runs. The patch is acceptance instrumentation.

The drill checks these new boundaries on Godot 4.3 Linux arm64:

- #367: two real reports from one socket call the public server dispatcher
  concurrently. The first pauses after state acceptance and before fanout.
  The second reaches the report lock before release. Both true/false orders
  reach the v3 observer in acceptance order; v2 receives no transport events.
  Server assertions under the report lock check stored state at each queue
  admission. A duplicate is suppressed. Both observers receive later gameplay.
  The ordinary transport-report drill above covers reconnect generations.
- #358: a Direct metadata transaction pauses inside the commit hook before
  storing the endpoint. Join and leave each reach the room mutation lane
  while it is held. No plan or membership change appears before release.
  Clients converge on the fresh endpoint and generation; plan callbacks see
  peers in the current roster, and relay gameplay succeeds afterward.
- #356: the first registration attempt returns failure at the existing result
  seam. A successful retry preserves terminal identity, reason, roster removal,
  replay and fresh gameplay. A panic on retry exhausts publication and closes
  the viewer once with `1000/unregistered`. No terminal acknowledgement is
  sent through the unregistered generation. Room members still receive one
  removal. Fresh authentication and spectator admission restore gameplay.
  Both recovery and exhaustion run with v2 and v3 viewers.

The server's normal WebSocket reader dispatches serially. The fixture starts
transport-report tasks through the public library entry point to reproduce
embedded-host concurrency. It preserves the production report, lifecycle,
room and queue gates. The injected registration failures qualify recovery
behavior at that seam; the drill does not establish a request-triggered
coordinator failure. Authoritative spectator removal and correlated live
admission remain open in #356. Controlled Direct reconnect publication and
game-owned socket teardown remain open in #358. Browser interop is separate.
