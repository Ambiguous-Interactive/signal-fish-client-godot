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
It covers serial WebSocket dispatch. The controlled lifecycle drill below
covers concurrent embedded-host dispatch.
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
voluntary detach and replay are covered. The publication drill below covers correlated recovery results and
authoritative removal for #356. The fault and drain drill below covers both local
completion panic points and terminal-before-close ordering.

The controlled publication and server delivery-pressure drills below cover
concurrent publication and queue policies. These drills are opt-in and
outside `all`. The [mesh drill](mesh-guide.md#live-channel-drill) checks native and
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
receive backlog. The server delivery-pressure drill below covers queue
saturation and latest/volatile delivery.

A three-player Direct case removes the selected host. Both survivors receive
a fresh shared generation and the successor's endpoint. Removing the remaining
endpoints produces a shared Relay reset with no host, endpoint, peers or ICE.
Plan callbacks see the reset and relay gameplay succeeds. Controlled publication is covered by the drill below. The publication drill below checks game-owned Direct
socket replacement and teardown.

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
The publication drill below covers authoritative removal.

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
The publication drill below covers recovered correlated payload decoding;
SDK room-operation admission remains unsupported. These drills are opt-in.

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
coordinator failure. The publication drill below adds authoritative spectator
removal, correlated result decoding and controlled Direct reconnect publication. Browser interop
is separate.

### Gameplay publication boundaries

Using the same patched server and barrier directory, run:

```bash
godot --headless --path . --script tests/smoke/run_publication_boundary_acceptance.gd
```

This drill passed with Godot 4.3 Linux arm64, client base `5abec3c` and
server `182cb234` plus the checked-in `controlled_lifecycle.patch`:

- #368: pause spectator admission before baseline registration while holding
  the room mutation lane. A player join reaches that lane and waits. Gameplay
  continues to an incumbent player. The new viewer receives no traffic before
  publication. After release, it receives one baseline then one player delta,
  a complete roster and fresh gameplay. Prior gameplay is absent from the
  new viewer's history. The drill covers v2/v3 JSON and raw MessagePack.
- #356: an administrative detach with reason `removed` recovers after the
  first registration failure. v2/v3 viewers receive one terminal with the
  original room identity and reason. A connected member receives one removal;
  an absent v3 player receives that removal once in decoded replay. Replay
  requires consumer dispatch. Readmission and gameplay succeed.
- #356: a fixture sends one raw v3 `RoomOperation/LeaveSpectator` after
  negotiating `room_operation_ids`. Recovery preserves operation identity,
  `SpectatorLeft` payload, room identity, reason and roster. The SDK emits
  one informational result and leaves its cached session unchanged. The
  server removes the viewer from routing. This fixture adds no room-operation
  API or admission support. The ordinary SDK uses `leave_spectator()`.
- #358: pause a Direct endpoint commit while reconnect reaches the mutation
  lane. Two reconnect cycles receive their baseline before fresh plans,
  rotate the credential and converge on the new endpoint and generation.
  A game-owned `StreamPeerTCP` connects to a real loopback listener. It sends
  payloads after reconnect and running endpoint refresh. Service disconnect,
  endpoint replacement and Relay reset close the prior socket; the listener
  observes EOF. Relay gameplay continues after teardown.

The added barriers are `spectator-baseline` and `reconnect-enter`.
`spectator-remove.arm` makes the next spectating client's Ping call the
existing administrative detach path with reason `removed`, then process the
Ping normally. Combine it with `detach-error.arm` for recovery. This trigger
is local acceptance instrumentation; it is absent from ordinary builds.
The mutation, routing, registration retry and publication paths remain intact.
The drill releases held barriers and closes application sockets on failure.
All waits and the overall watchdog retain the bounds described above.

The pressure drill below covers server delivery pressure. The observer
roster repair remains open in #374. This native TCP fixture provides no
browser Direct-socket contract; browsers require supported transports.

### Server delivery pressure

`tests/smoke/run_delivery_pressure_acceptance.gd` covers #368 at the server
outbound queue. Use the isolated server, config and toolchain above. Apply
`controlled_lifecycle.patch`, then `tests/fixtures/delivery_pressure.patch`.
Set `websocket.send_queue_capacity` to `4` and keep
`websocket.slow_consumer_timeout_ms` at `5000`. Rebuild the server and start
it with a fresh `SF_GODOT_BARRIER_DIR`, shared with the client process:

```bash
godot --headless --path . --script tests/smoke/run_delivery_pressure_acceptance.gd
```

The added barrier is `writer-<spectator-id>`. After writing a control frame,
the server writer waits before selecting another queue entry. The client
arms only its spectator's writer and wakes it with Ping. The sender's Pong
then proves that the server processed every ingress frame while the writer
was held. The production queue admission, coalescing and reporting paths
remain active. The drill releases the writer on failure. Reverse both patches
and restore the queue config after testing.

- v3 JSON latest: eight updates to one key produce the final value, exact
  `latest_superseded` ranges for sequences 1-7 and matching typed counters.
- v3 JSON volatile: a full four-entry queue evicts sequences 1-4 and delivers
  the newest four values in order. Exact `volatile_dropped` ranges and typed
  counters match. Both lossy cases publish the report before surviving data,
  preserve the spectator role and receive fresh reliable gameplay afterward.
- Reliable: five frames fill the four-entry queue and trigger one spectator
  close with code 4002. The sender stays in its room. The viewer clears its
  state, authenticates on a fresh connection, rejoins and receives fresh data.
  The matrix covers v2/v3 JSON and raw/decoded MessagePack, plus v3 opaque
  rkyv/protobuf. Opaque test bytes remain application-owned.

Latest and volatile sends use a raw v3 text fixture. The public SDK send
methods currently use reliable delivery. This drill adds no lossy-send API
or binary delivery-metadata API. The v2 verdict applies to the pinned server
build; v2 has no `spectator_relay` capability token.

### Roster recovery contract

`tests/smoke/run_roster_recovery_acceptance.gd` is an opt-in regression for
issue #374. It needs the ordinary fixed server above, with no instrumentation:

```bash
godot --headless --path . --script tests/smoke/run_roster_recovery_acceptance.gd
```

Use server
[`b264ec7`](https://github.com/Ambiguous-Interactive/signal-fish-server/tree/b264ec739400b299182eaa918dd6828fd611f3b9)
with the ordinary config above. Godot 4.3 Linux arm64 passed six cases: v2/v3
observers with JSON and raw/decoded MessagePack. A seated observer, an incumbent
spectator and a spectator admitted during absence restore the current name,
readiness and authority before each reconnect callback. Each case includes two
reconnect cycles, exact resumed gameplay, spectator role and terminal leave.
Reconnect emits no synthetic player join. Success prints
`LIVE_SERVER_ACCEPTANCE_PASS`.

Server `182cb234` omits the metadata and fails this drill. The new single-frame
contract shipped in
[server PR #1169](https://github.com/Ambiguous-Interactive/signal-fish-server/pull/1169).
The deterministic client suite also covers missing/malformed metadata,
ID/epoch/sequence matching, duplicates, older epochs, replay baseline precedence,
room reset, bounded roster growth and mesh incarnation retirement.

### Expired reconnect cleanup

`tests/smoke/run_expired_cleanup_acceptance.gd` covers issue #357. In an isolated
server checkout at `b264ec7`, use the config above with
`server.reconnection_window` set to `1`. Apply this repository's
`tests/fixtures/expired_cleanup.patch`, then rebuild:

```bash
# From the isolated server checkout:
git apply /path/to/signal-fish-client-godot/tests/fixtures/expired_cleanup.patch
cargo build --locked --bin signal-fish-server
export SF_GODOT_EXPIRY_DIR="$(mktemp -d)"
SF_GODOT_EXPIRY_DIR="$SF_GODOT_EXPIRY_DIR" target/debug/signal-fish-server
```

In another terminal, set `SF_GODOT_EXPIRY_DIR` to the same directory and run:

```bash
godot --headless --path . --script tests/smoke/run_expired_cleanup_acceptance.gd
```

A Ping with `prepare.arm` captures the server regression's controlled residue:
the server removes a seat while retaining its socket, registers a pending
reconnect, waits for expiry and snapshots its real cleanup candidate. It then
sends `RoomLeft` and Pong. The client joins the same room with the same socket
identity and receives a new `RoomJoined` credential. A Ping with `cleanup.arm`
runs the saved candidate through the production cleanup method before Pong.
The `cleaned` file reports zero removed seats.

Godot 4.3 Linux arm64 passed four cases with v2/v3 observers and JSON/decoded
MessagePack. The fresh seat becomes ready, sends exact gameplay and reconnects
with its current credential. An ordinary expiry control refuses the expired
membership and permits a fresh login/join. The actor uses v3 because this server
pre-issues reconnect credentials on v3. V2 observer results qualify this tested
server build. They do not imply v2 credential issuance.

The fixture forces a server-side residue seam. It does not establish that
ordinary remote messages can create the stale record. Candidate capture has a
four-second deadline; client phases wait eight seconds, and the runner has a
two-minute watchdog. Run one drill per server and directory. Stop the server,
remove the directory, restore its config and reverse the patch after testing.
The fixture is local acceptance instrumentation.
