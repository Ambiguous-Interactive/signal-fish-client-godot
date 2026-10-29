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
On the older pinned server, this drill exposed the missing peer metadata.
The [roster recovery drill](#roster-recovery-contract) qualifies the repair.

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
force an internal publication race. The [roster recovery drill](#roster-recovery-contract)
checks incumbent metadata on the newer server.

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

### Active gameplay shutdown

Use this POSIX-only local control for #482, #403 and #355. It starts and stops
its own server processes. It runs native and Web seats with 4 KiB relay bodies
and exact mesh packets with 4 KiB bodies in all three transfer modes.

Build server commit `ee20b51ee605b09cdb448615f7500f6877d8c6e1` or a later
source containing [the shutdown close repair](https://github.com/Ambiguous-Interactive/signal-fish-server/pull/1294).
Keep the build log and source state with the executable hash. Native runs need
Godot and the native WebRTC extension. Web runs need matching Godot Web export
templates and Playwright Chromium. The default `all` runtime needs both sets.
Use a local server config with WebRTC enabled and empty ICE servers, as in
`docs/mesh-guide.md`.

```sh
python scripts/check-active-shutdown.py \
  --server-binary /path/to/signal-fish-server \
  --server-config /path/to/local/config.json \
  --server-revision ee20b51ee605b09cdb448615f7500f6877d8c6e1 \
  --native-extension /path/to/webrtc_native \
  --godot /path/to/godot --chromium /path/to/chromium \
  --output /tmp/active-gameplay-shutdown
```

The output directory must be new. `--runtime native|web` and
`--mode graceful|reset|stall` select a control. The driver copies the config,
selects a local port and sets a three-second server drain. Other config values
remain supplied by the caller. The declared server revision is recorded beside
the executable hash; the driver cannot prove how an executable was built.
The default relay rate is four packets per frame per seat.
`--relay-packets-per-frame 1` selects a slower comparison. Keep its result
separate from the original offered rate.

Each control first exchanges 32 exact mesh packets per mode and direction.
The RPC peer caches an unreliable packet before a later reliable arrival.
The drill checks both packets' bytes and modes, then caches another packet
for retirement. Relay sends stay active through graceful drain.

- `graceful`: SIGTERM must yield `GoingAway`, then one
  `disconnected(4000, "server_shutdown")` per client.
- `reset`: SIGKILL must yield an abnormal close or a send-side transport
  failure. Native and Web raw close values can differ.
- `stall`: SIGSTOP holds the server while each client calls `close()`.
  The two-second close watchdog must emit `heartbeat close timeout`.

Every control checks that the mesh is empty, the cached receiver cannot return
or send data, and terminal signals stay single. Graceful and reset controls
check automatic retry eligibility, then disable retries for a controlled fresh
login. User close must leave retries stopped. After server restart, a new plan
and receiver must exchange every mesh packet again. The old receiver stays empty.

Check every send result. A Web send can return `ERR_UNCONFIGURED` while a close
frame is pending. The drill records that refusal and stops application sends
for that seat. Graceful shutdown still requires the exact semantic close.
Relay receives require exact bytes, sender and sequence for the delivered
prefix. Shutdown may discard the remaining relay tail.

Each case retains `godot.log`, `server/server.log`, `assessment.json`, import
logs and effective config. Web cases also retain export logs. Root provenance
records source and executable hashes. Failed attempts remain in their original
output directories. These are local acceptance controls; remote networks,
engine versions and extension builds need separate qualification.

On Linux ARM64, one six-case cohort passes with official Godot 4.7.2, Chromium
156.0.8078.4 and server `ee20b51e`. Native seats use the opt-in repaired
extension described in `docs/mesh-guide.md`. The server executable SHA-256 is
`4f9c94a766864be0a151263b43230518e62910c4dfe9b7b8d4defbcde82fbdd3`.
The local reports are under `/tmp/session452-final-matrix`.
Later cold-editor imports abort before gameplay (#447). Those driver attempts
remain failed. Direct runtime boots of the exact prepared projects pass the
native graceful and nonresponding controls. The import failure remains open.

A Godot 4.3 native control with the earlier extension preserves shutdown
metadata and fresh mesh gameplay, but fails on a WebSocket receive-buffer
overflow and relay sequence gap (#485). Its reset and nonresponding controls
pass. The original failure remains under `/tmp/session452-native43-original`.
A separate one-packet-per-frame control passes every check. The slower pass
leaves the original reliable receive failure open. These results establish
the semantic closes on those local paths. A delayed browser control below
exposes a separate send/close race. Engine coverage and remote qualification
remain open in #482, #403 and #355.

### Native WebSocket receive boundary

Issue #485 is reproducible with `WebSocketPeer` and the local smoke server.
This native control needs no Signal Fish server or WebRTC extension:

```sh
godot --headless --path . \
  --script tests/smoke/run_websocket_receive_boundary.gd
```

It writes 64 exact 4096-byte messages, holds client polling for 100 ms, then
drains. A later sentinel exposes an interior gap after a dropped burst tail.
Every write must succeed. Every received packet must match its bytes, string
mode and sequence. The final count must be 65. Engine errors remain failures.
The watchdog covers the five-second connection window, each batch hold/read
window and the final sentinel read. It is opt-in because the original Godot
4.3 failure must remain visible.

Use `-- --credit=32768` to split the same finite work into batches bounded by
local consumer body bytes. Use `-- --capacity=524288` for a larger byte buffer,
or add `--max-queued-packets=2` to isolate the packet-count boundary.
Credit uses direct local consumer observations; it adds no network ACK protocol.
The script prints each poll, packet and final verdict. Keep logs, commands,
source hashes and engine hashes for every attempt.

On Linux ARM64, the new controls retain these results:

| Engine       | Default buffer | 512 KiB buffer | 512 KiB, two packets | 32 KiB body credit |
| ------------ | -------------- | -------------- | -------------------- | ------------------ |
| 4.3          | Fails: 16/65   | Pass: 65/65    | Fails: 3/65          | Pass: 65/65        |
| 4.4.1        | Pass: 65/65    | Pass: 65/65    | Pass: 65/65          | Pass: 65/65        |
| 4.7.2        | Pass: 65/65    | Pass: 65/65    | Pass: 65/65          | Pass: 65/65        |
| 4.3 backport | Pass: 65/65    | Pass: 65/65    | Pass: 65/65          | Pass: 65/65        |

The default byte setting is 65535 in all three engines. Matching the newer
engines to 2048 queued packets also passes. The changed default packet count
alone does not explain the repair. Godot's
[unbuffered receive repair](https://github.com/godotengine/godot/commit/3114bda4e1ee88f04f55451697f24c9ee79be54f)
limits socket reads to remaining queue space. Godot 4.4.1 includes this repair
and later fragmented-message fixes. An SDK drain cannot recover bytes already
dropped inside a Godot 4.3 engine poll. A larger finite buffer only moves that
boundary. The retained 4.3 failure still needs an engine upgrade or qualified
backport for a receive-boundary repair.

Add `-- --fragment-bytes=127` to split each message into WebSocket TEXT and
CONTINUATION frames. Zero preserves single-frame messages. Message bytes,
credit, capacity and the later sentinel stay unchanged. TCP may coalesce the
writes. Godot 4.4-beta1 passes the original control but truncates fragmented
messages: a 512 KiB run receives 65/65 messages with 127-byte bodies instead of
4096 bytes. The exact-byte check fails from packet zero. Godot 4.4.1 and 4.7.2
pass the same fragmented controls. Add `--message-type=binary` for bodies
containing all byte values, or `--message-type=alternating` to alternate text
and binary messages. Both bytes and packet type must match the offered order.
The default text workload stays unchanged. A 4.3 backport also needs the
[message-completion callback repair](https://github.com/godotengine/godot/commit/d798068a0816a66b80b8096aa77212468c0155c4),
the
[fragmented-message assembly repair](https://github.com/godotengine/godot/commit/a2f5eb9cf095a8d942d9518a2ef5848cd47ce8f1),
and the
[closing-buffer lifetime repair](https://github.com/godotengine/godot/commit/81181c594170057612eb1bf3224858a474f19722).
The assembly change alone still commits individual fragments. Clearing the
receive buffers before the close handshake blocks its socket reads.
The beta is a historical negative control; it adds no support promise.

Add `--fragment-control=ping` or `--fragment-control=pong` with a positive
fragment size to place a nonempty control frame inside each fragmented
message (#491). Control bytes must stay out of the delivered text. Official Godot
4.4.1 and 4.7.2 fail this exact-byte control even when all 65 packets arrive.
The buffered Godot 4.3 capacity control preserves the message bytes.

Apply the experimental native backport to a clean Godot 4.3-stable source
checkout with:

```sh
python scripts/backport-websocket-43.py --source /path/to/godot \
  --report /tmp/websocket-backport.json
```

The script pins the source revision and all four upstream commits. It records
patch and source hashes, rejects conflicting edits, and supports `--check`.
Build the engine separately and retain its command, log and binary hash.
The experimental patch also keeps interleaved Ping/Pong bytes out of the
fragmented message and clears pending assembly on connection replacement.
This patch does not change the Web callback receive boundary.
Issue #492 covers a separate direct-peer reuse failure. Run
`godot --headless --path . --script tests/smoke/run_websocket_fragment_reuse.gd`
to replace a closing peer after an unfinished fragment. The fresh text must
be exactly five bytes. Official 4.4.1/4.7.2 retain stale assembly length and
return an empty packet with a buffer error. The SDK creates a fresh engine peer
for each session; this direct-reuse result does not establish an SDK reconnect
defect. Pass script options after Godot's `--` separator:

```sh
godot --headless --path . \
  --script tests/smoke/run_websocket_fragment_reuse.gd -- \
  --partial-type=binary --fresh-type=binary
```

Choose the partial and fresh message types independently. The fresh binary
body includes zero and non-UTF-8 bytes.

Separate experimental patches target Godot 4.4.1-stable
`49a5bc7b616bd04689a2c89e89bda41f50241464` and 4.7.2-stable
`ed1daf0bf001b61586d9930840f2f1394092c079`:

```sh
python scripts/repair-websocket-stable.py --source /path/to/godot-stable \
  --report /tmp/websocket-assembly.json
```

Each patch changes only frame assembly and replacement cleanup. The applicator
checks the exact revision, selects its patch, rejects conflicting changes and
records source and patch hashes. `--check` leaves source unchanged. Build and
qualify the patched engine before use. Official 4.4.1 and 4.7.2 still fail
the mixed binary interleaved controls and every partial/fresh text/binary reuse pair. Upstream adoption,
other engine builds and remote gameplay remain open.

For 4.7.2 template builds, add `disable_path_overrides=no` to the SCons command
to enable `--path` and `--script` for these fixtures. Use the matching official
editor to import the test project before running a template build.

The locally built 4.4.1 native template passes 31 controls with no engine
errors: text, binary and alternating messages across no-control/Ping/Pong,
default byte limits, two queued packets and local 32 KiB credit, plus all
four partial/fresh message-type pairs. Every burst delivers 65 exact packets
with matching types. Reuse delivers exactly five fresh bytes. The same build
passes the standard WebSocket smoke with client/server close handshakes.
Its active SDK drill passes semantic shutdown, reset and nonresponding controls
with the original uncredited four-per-frame sends, 50 ms TCP delay, 127-byte
proxy writes and a 100 ms polling hold. Exact relay prefixes, cached mesh
retirement and fresh gameplay receipts remain required. These results qualify
the pinned Linux ARM64 build and local workload.

The locally built 4.7.2 native template passes the same 31 controls, close
smoke and all three active SDK shutdown modes with the same uncredited sends,
TCP delay, proxy writes and polling hold. Every burst delivers 65 exact
4096-byte packets; each reuse pair delivers five fresh bytes with the correct
type. A matched official 4.7.2 run passes nine no-control burst cases and fails
all 18 interleaved-control cases and four reuse pairs. Its active shutdown
controls pass. These results qualify the tested Linux ARM64 build and local
workload. Remote paths, other targets and upstream adoption remain open.

Use `--import-godot /path/to/official-godot-4.3` in the active-shutdown driver
to import with an editor and run a native template build via `--godot`.
Both engine binaries are hashed in the retained results.

The locally built 4.3 template passes all three active-shutdown modes with
the original uncredited four-per-frame sends, 50 ms TCP delay, 127-byte proxy
writes and a 100 ms polling hold. Receive capacity stays at 65535 bytes.
Exact relay prefixes, semantic/reset/nonresponding close outcomes, cached
mesh retirement and fresh exact gameplay remain required. This qualifies
the tested native build and local workload; upstream and remote qualification
remain open. A new matched official 4.3 shutdown control also passes;
that passing comparison does not explain the retained overflow history.
The finite burst controls keep the native receive-boundary failure explicit.

### Web WebSocket receive boundary

Issue #488 has a separate engine-only browser control. It needs Godot Web
export templates and Playwright Chromium. It uses a local Python server and
`WebSocketPeer`, with no Signal Fish service or WebRTC extension:

```sh
python scripts/check-websocket-web-receive.py \
  --godot /path/to/godot --chromium /path/to/chromium \
  --output /tmp/websocket-web-receive
```

The output directory must be new. The server sends 64 exact 4096-byte text
messages and a later sentinel. The script holds polling for 100 ms after each
burst command, then checks every delivered byte, type and sequence. Results
retain commands, engine/export/source hashes, browser version, poll intervals,
every callback and every delivered sequence. This opt-in control preserves
engine overflow failures outside the deterministic gates.

Use `--credit-bytes 32768` for local consumer body-byte batches,
`--capacity 524288` for a larger byte buffer, `--max-queued-packets 2` to isolate
the packet-count boundary, or `--hold-ms 1000` for a longer polling hold.
Credit uses local observations and adds no network acknowledgement protocol.
Zero capacity or packet count keeps the engine default. Keep each control
separate from the original uncredited workload.

For a receipt carried on the tested WebSocket, use
`--credit-transport app-ack --credit-bytes 32768`. The receiver acknowledges
only the cumulative exact prefix after checking bytes, order and message type.
The server releases that many consumed bytes and keeps all receipts. Each
complete callback body is 4096 bytes; the byte window covers the entire body.
The later sentinel waits for a receipt covering all 64 burst bodies. Use
`--ack-delay-ms 100` to hold receipts after consumption. The existing local
batch control remains the default. This experiment needs a cooperating sender;
it adds no delivery guarantee to the SDK or the uncredited workload. The window
must also fit the packet-count limit: on a two-packet queue, a 32 KiB window
still overflows, while an 8192-byte window admits exactly two bodies. Failed
byte or order checks release no receipt or credit.

With Chromium 156 on Linux ARM64, all three supported engines deliver 65/65
exact messages with a 32 KiB application window, 100 ms polling holds and
100 ms delayed receipts. No callback is rejected and outstanding bodies stay
within 32768 bytes. The matched uncredited 4.7.2 run delivers 31/65 messages;
34 scoped rejections account for every missing receipt. The later sentinel
arrives. These local measurements preserve the original overflow verdict.

Linux ARM64 and Chromium 156 controls retain these results on Web:

| Engine | Default buffer | 512 KiB buffer | 512 KiB, two packets | 32 KiB body credit |
| ------ | -------------- | -------------- | -------------------- | ------------------ |
| 4.3    | Fails          | Passes         | Fails                | Passes             |
| 4.4.1  | Fails          | Passes         | Fails                | Passes             |
| 4.7.2  | Fails          | Passes         | Fails                | Passes             |

Every finite control observes all 65 browser callbacks. The failed byte/count
controls retain unique engine rejection identities matching the missing script
receipts; the later sentinel is delivered. A larger finite buffer and local
credit qualify those controls. The original uncredited receive loss remains
open. These are local controls; remote networks remain unqualified.

The test-only observer wraps the engine's assigned browser `onmessage` handler.
Each rejection records the physical connection, callback ordinal, byte length,
bounded prefix, rejection reason and browser clock while that handler is active.
Payload-capacity and packet-count rejections stay distinct. An error outside
the handler has no callback identity. Callback arrival alone does not prove
engine acceptance. A complete trace must account for omitted records before
comparing rejected identities with script receipts.

The active-gameplay driver also accepts these comparison controls:

- `--relay-packets-per-second 240`: use elapsed time to set the offered target,
  with at most 16 sends per frame to catch up. Zero keeps the original frame rate.
- `--relay-credit-bytes 32768`: cap outstanding 4096-byte bodies using the other
  local seat's receive count. JSON framing and other protocol traffic add bytes.
- `--receive-pause-ms 100`: hold engine polling after each mesh generation opens.
  Other application and mesh work continues. Zero leaves polling unchanged.
- `--inbound-buffer-bytes` and `--max-queued-packets`: set the engine capacities.
  Zero preserves each engine's default. A Web property value does not establish
  the browser's backing queue capacity.

Add `--relay-credit-transport app-ack --relay-credit-bytes 32768` for an
application ACK comparison. Each receiver sends a cumulative exact-prefix
receipt through `GameData`. Only a validated receipt from the current remote
player, room and gameplay generation advances the sender's byte window.
A missing or corrupt data packet stops new ACK progress. The default `local`
credit mode keeps the shared-process receipt counter. ACK records retain
physical connections, sent/received prefixes and window peaks.

Application ACKs add protocol traffic and change the transmitted schedule.
This is an opt-in drill control, with unchanged 4096-byte data bodies. It
establishes no SDK-wide delivery guarantee. Preserve the original uncredited
failures and qualify real remote paths separately.

On Linux ARM64, the 32 KiB application ACK control passes all three shutdown
cases on native Godot 4.3 and Web Godot 4.4.1/4.7.2 with 50 ms TCP delay, 127-byte
proxy writes and a 100 ms initial polling hold. All exact mesh, cached
retirement and fresh-gameplay checks pass. A matched uncredited Web run
retains a scoped rejected callback and relay gap from 151 to 152; both seats
still preserve the semantic shutdown close. The engine receive defect remains
open. The application ACK control qualifies its bounded local workload.

Logs identify the seat and physical connection, reported capacities, poll
intervals and duration, queued packet peaks, total received frame bytes, first
relay gap, offered target, credit blocks and peak outstanding body bytes.
All original shutdown, cached-packet and exact mesh checks remain required.
Keep rate, credit, pause and capacity changes separate in reports.

A 240-packet/s native 4.3 run with a 100 ms poll hold fails on an engine overflow
and a first delivered gap from 15 to 24. Its matched 32 KiB body-credit control
passes all gameplay checks. The credit result qualifies that local control;
it leaves the original uncredited workload failed. A new six-case Godot 4.4.1
native/Web cohort passes graceful shutdown, reset, nonresponding close, cached
metadata, retirement and fresh mesh recovery at the original four-per-frame
rate. Three new Godot 4.3 Web shutdown controls also pass. Remote-network
and Godot 4.3 native receive qualification remain open.

### Delayed relay shutdown

Add `--network-delay-ms 50` to the active-shutdown command to delay each TCP
direction by 50 ms. This includes relay data and signaling. Mesh UDP and HTTP
control stay local. The workload, close deadlines and exact gameplay checks
stay unchanged. This is local network emulation; real remote paths need their
own qualification.

Use `--network-chunk-bytes 127` to bound each proxy read and write. TCP may
coalesce these writes before Godot reads them. This does not promise a matching
engine read size or WebSocket frame fragmentation. Queue slots use a 1 MiB
payload budget per direction, capped at 8192 chunks. Reports retain the
effective byte/count bounds, bytes, chunk counts, peak queue size and observed
delay for each physical connection. A full queue can add TCP backpressure.
EOF follows queued data. Socket errors and cleanup cancellations stay visible.
Each passing case must forward both directions on at least four connections
and meet the requested minimum delay.

The proxy's loopback integration tests are opt-in:
`python -m unittest tests.test_delayed_tcp_proxy`. They cover large exact
binary streams, half-close replies, actual delay, reset and idle teardown.

Browser logs include socket state reads and close callbacks. On the original
4.4.1 delayed run, both browser sockets were CLOSING while the engine reported
OPEN. A send returned FAILED; the SDK discarded the peer before close 4000
arrived about 80 ms later. The transport now refuses further sends and polls
for that callback for at most one second, then falls back to one failure.
Text and binary refusals use the same rule. All strict receipt, shutdown,
cached metadata, retirement and fresh-gameplay checks remain required.

One repaired 4.4.1 native/Web 50 ms cohort passes all six shutdown cases.
Native 4.3 still fails exact relay receipts in all three delayed controls;
its matched 32 KiB local body-credit controls pass. The 4.7.2 small-write
cohort preserves shutdown and mesh checks, but its Web graceful case drops
relay packets after restart (#488). Both seats expect sequence 24 and receive
26/27 after engine buffer errors. Its matched 32 KiB body-credit cohort passes
all three cases. Later final-source 4.4.1 Web graceful and reset runs also fail
on receive overflow. The graceful gap is from sequence 535 to 536 during the
first generation; its close, retirement and fresh mesh remain exact. Credit
changes the local offered work; it does not repair or
qualify the original uncredited receive boundary. Every failure stays retained.

Add `--trace-receive` to retain scoped browser callback and rejection records
for the active-shutdown drill. The driver freezes the observer source per
cohort, copies it per case, and records its hash. Generated relay bodies also
get a parsed `relay_sequence`; other messages leave it null. Snapshots are
collected before the browser closes, including failed controls.

A new uncredited 4.7.2 Web run with 50 ms delay and 127-byte proxy reads fails
with a scoped rejection and a generation-one relay gap from 21 to 22. A
separate 100 ms polling-hold control identifies rejected relay sequence 23 and
the matching application gap from 23 to 24. Both retain GoingAway, one close
4000/server_shutdown per seat, retry eligibility, cached retirement and exact
fresh mesh receipts. Their overall verdicts stay failed. Matched 32 KiB
body-credit controls pass. Passing attempts and every failure stay separate;
this evidence leaves engine repair and remote qualification open.

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

The pressure drill below covers server delivery pressure. The
[roster recovery drill](#roster-recovery-contract) covers observer metadata.
This native TCP fixture provides no
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
room reset, bounded roster/departure history and mesh incarnation retirement.

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
