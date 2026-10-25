---
description: "SFWebRTCMesh: opt-in v3 session plans, WebRTC signaling handled for you, and a WebRTCMultiplayerPeer mesh."
---

# Mesh (v3)

`SFWebRTCMesh` is an opt-in layer that turns negotiated v3 session plans
into a working `WebRTCMultiplayerPeer` mesh. The core server-relayed client
stays zero-native; relay-only users pay nothing.

## Opt in through config capabilities

Set the v3 capability fields on `SignalFishConfig`:

- `protocol_version`: set to `3`.
- `supported_transports`: transports you can handle.
- `supported_topologies`: topologies you can handle.
- `requested_capabilities`: extra capability tokens.

These fields are omitted when unset, so v2 wire bytes stay identical.

## Using the mesh

```gdscript
var mesh := SFWebRTCMesh.new()
add_child(mesh)
mesh.attach(client)
# Once a webrtc plan lands, run RPCs over the mesh:
multiplayer.multiplayer_peer = mesh.get_safe_multiplayer_peer()
```

`attach(client)` subscribes the mesh to the client's signals and returns
`Error`. `detach()` unsubscribes.

`get_safe_multiplayer_peer()` returns an opt-in `MultiplayerPeerExtension`
for RPCs. It keeps received bytes, sender, channel and transfer mode together
when channels overlap (#403). It uses the existing three negotiated channels
and delegates sends to Godot. Use it as the sole receiver. The original
`get_multiplayer_peer()` still returns the engine peer.

Assign the safe peer after a WebRTC plan creates the mesh. It discovers
already-connected peers on its first poll. When a plan replaces the engine
peer, assign the new safe peer to `multiplayer.multiplayer_peer`. Old adapters
stay disconnected after teardown. Closing the adapter tears down its mesh.
Room plans and player-left events can replace links while the same safe
peer stays assigned. Lifecycle callbacks may change other links or poll
again; closed links are excluded and each incarnation is announced once.
Only the three default channels are supported. Godot's GDScript packet hook
reports empty datagrams and read errors as `ERR_UNAVAILABLE`; use
`receive_packet()` when your raw protocol needs those distinctions.

## How the mesh behaves

- It consumes `session_plan` and `signal_received` and answers with
  `send_signal`.
- The server decides who offers. The `new_peer(peer_id, you_initiate)`
  signal carries that decision; roles are never computed locally.
- It applies `ice_servers` by replacing the previous list, never merging.
  An empty list is authoritative. The server pre-gathers ICE servers on
  `RoomJoined`/`Reconnected` (`RoomJoinedInfo.ice_servers`).
- It rebuilds retained peers on a generation or role change, and drops
  peers absent from the latest plan.
- It tears down on `room_joined` (a fresh baseline), `spectator_joined`, `room_left`,
  `disconnected`, `connection_failed`, `authentication_error`, `reconnected`,
  and node exit. A replayed plan inside `missed_events` cannot revive an old mesh.
  `player_left` only drops the leaving peer; the rest of the mesh
  survives.
- A fresh `player_joined` or `player_reconnected` epoch closes that peer's
  old link and waits for a new plan generation. Duplicate known epochs keep
  the link. Missing epochs cause the link to close and wait for a new plan.
- Spectators never open mesh links. Public `game_starting` events leave
  viewing on the relay.
- It calls `send_transport_status` on the client only at the aggregate
  0<->1 connected-peer boundaries.
- A signaling relay refused by backpressure or rate-limited by the server
  is re-queued and redelivered in order (retries wait out one interval
  each) instead of being lost, so congestion cannot stall negotiation
  silently.
- Offer, SDP description, and poll errors close only the failed peer and log
  the engine error. A later plan can open a fresh link. A refused ICE
  candidate logs a warning and leaves the link available for other candidates.
- Failed, disconnected, and closed connections, closed required channels, and
  engine-removed peers release their links. A later plan can retry the same peer.
- Status retry delays end when the room resets or its plan generation changes.
- Peer ids derive deterministically from player UUIDs.

## Direct plan updates

Handle each `session_plan` signal when your game owns Direct sockets.
A host can publish a replacement endpoint without a membership change.
Stop using the previous endpoint and apply the new host, endpoint, and
generation together. A Relay plan clears the endpoint and peer obligations;
switch gameplay to the server relay. `SFWebRTCMesh` drops its links on
Direct and Relay plans. It does not manage game-owned Direct sockets.

`peer_transport_status` emits reports in received wire order, including
duplicates. Consumers that cache status should replace it on each report.
Replay reports arrive in `reconnected.missed_events` for the consumer to
apply; they do not also emit as live status signals.

## Related signals

| Signal                                                     | Arguments                                               |
| ---------------------------------------------------------- | ------------------------------------------------------- |
| `session_plan(plan)`                                       | The negotiated plan (`SFSessionTypes.SessionPlanInfo`). |
| `new_peer(peer_id, you_initiate)`                          | A peer joined the mesh plan.                            |
| `signal_received(from_player, generation, signal_payload)` | Signaling payload from another peer.                    |
| `peer_transport_status(peer_id, transport, connected)`     | A peer's transport went up or down.                     |

## Platform note

Native Godot exports need a WebRTC GDExtension such as
[webrtc-native](https://github.com/godotengine/webrtc-native). Browser exports
use browser WebRTC.

Godot's mesh creates three negotiated channels: `reliable` (id 1), `ordered`
(id 2), and `unreliable` (id 3). Transport reports require all three channels
to be open. Closing any required channel reports the last connected link
down and releases the link even when its peer connection was connected. A later
plan can create a replacement link. Applications still drive their
`MultiplayerAPI` or poll the multiplayer peer to deliver gameplay packets.

Use the same Godot channel layout at both ends. The server's
[browser](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/182cb234c7aa601be3c2aad881948b3c5b853aaa/clients/browser/src/page/engine.ts)
and
[native](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/182cb234c7aa601be3c2aad881948b3c5b853aaa/clients/native/src/engine.rs)
reference engines create two in-band channels, `reliable` and `unreliable`.
Their responders adopt remote channel announcements. Godot's negotiated
channels do not send these announcements. Use server relay for these
pairings. Full reference-client gameplay sessions remain unverified.

## ICE candidate formats

The mesh accepts raw candidate lines and JSON-encoded `RTCIceCandidateInit`
strings inside `IceCandidate`. Raw lines stay unchanged. Envelopes supply
`candidate`, `sdpMid`, and `sdpMLineIndex` to Godot's `add_ice_candidate()`.
Missing or null media/index fields use Godot's existing defaults: `""` and
`0`. Godot's API has no `usernameFragment` argument.

The server's
[native Engine](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/native/src/engine.rs)
(`LocalCandidate`, `handle_remote_candidate`) and
[browser Engine](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/browser/src/page/engine.ts)
(`onicecandidate`, `handleRemoteCandidate`) emit envelopes and accept raw-line
fallbacks. The Godot mesh emits raw lines. Candidate parsing preserves these
formats; it does not change data-channel negotiation.

## Browser reference engine assessment

A local check relayed signaling between `SFWebRTCMesh` and the server's
[browser Engine at b264ec7](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/browser/src/page/engine.ts).
It used Godot 4.3, Linux arm64 with webrtc-native 1.2.2-stable for native
Godot, and Chromium 154. Each engine kept its outgoing signaling format.

| Offerer          | Godot runtime  | Result                                              |
| ---------------- | -------------- | --------------------------------------------------- |
| Godot            | Native and Web | SCTP connected; reference gameplay channels absent. |
| Reference Engine | Native         | Reference channels closed; Godot released the link. |
| Reference Engine | Web            | Reliable and unreliable probes passed both ways.    |

After the ICE envelope fix (#405), all four pairings were repeated with the
same tools and reference commit. All had zero candidate errors; the channel
and gameplay results in the table were unchanged. Godot's local transport
report can be up when the reference Engine has no channels. Keep mixed
reference-client rooms on the server relay. The Web responder probes cover
two channels; ordered traffic and full reference-client sessions still need
validation.

### Repeat the browser Engine assessment

Run the opt-in assessment against a compiled browser Engine module:

```bash
python scripts/check-webrtc-reference.py \
  --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-assessment
```

The module directory must contain `engine.js` and its imported modules.
From a server checkout at the supplied revision, build the module:

```bash
npx --yes --package esbuild@0.25.12 esbuild \
  /path/to/server/clients/browser/src/page/engine.ts \
  --bundle --format=esm --platform=browser \
  --outfile=/tmp/reference-modules/engine.js
```

The report records the supplied source revision and module SHA256.

The runner checks native and Web Godot with both offer roles. Each pairing
rebuilds its link for a second generation and checks reliable and unreliable
probe bytes in both directions. Each seat then streams 128 reliable snapshot
chunks of about 1 KiB. Each chunk carries its generation, sender and sequence;
receivers compare its exact UTF-8 bytes. A 32-packet acknowledgment window
bounds the stream. Both seats start a second snapshot with four chunks before
the reference seat closes its reliable channel after sending one more packet.
Godot must remove the link before its local reset. The next generation must
pass the same checks with fresh bytes.

`assessment_complete` means both generations were observed and torn down.
`gameplay_passed` requires every probe, all 128 snapshot chunks, the four
partial-transfer chunks, and remote channel closure in both generations.
Add `--safe-receive` to select the RPC-safe peer's packet API. It must keep
the retirement packet selected until remote closure, then discard its cached
bytes. The default checks raw channel reads. Add `--require-gameplay` to fail when
any selected pairing lacks those probes. Use `--runtime native|web` and
`--offerer godot|reference` to select one pairing; both default to all pairings.
Safe-receiver assessments keep one adapter through both generations and
record `same_receiver`. A relay plan retires each generation's links.
Reference phase totals are refreshed at teardown. The `observation` field
keeps the earlier six-second snapshot, including transfers still in progress.
Keep mixed reference-client rooms on server relay until their pairing passes.
These local Engine checks leave full service sessions for a separate drill.

Each assessment retains `browser_observations` for the reference page and,
when used, the Godot Web page. Each page records signaling request timings,
progress ages, and the last 16 WebRTC transport samples. Reference progress
includes snapshot send, receive and acknowledgment counts, partial-transfer
counts, and channel-close stages. Compare an old progress record with fresh
transport samples and an aging HTTP request to locate a signaling wait.
These diagnostics also remain in an incomplete assessment.

The Web responder passed the safe-receiver checks on Godot 4.3, 4.4.1 and
4.7.2 with Chromium 154 and reference b264ec7. Both generations passed remote
closure, selected-packet discard and exact snapshot recovery. The other
three pairings in each engine assessment remained unsupported.

### Concurrent positions and consumption credit

Add `--mixed-traffic` to interleave 32 unreliable position samples with each
128-chunk snapshot in both directions. Each sample contains its generation,
sender and sequence. The local assessment requires every sample, exact bytes,
and matching channel metadata. It does not simulate packet loss.

The default `--credit-transport http` returns consumption credit through the
signaling relay. Use `--credit-transport webrtc` to return the same credit over
the reliable gameplay channel. Both keep the same 32-chunk window, snapshot
bytes, position cadence and generation/closure checks. For example:

```bash
python scripts/check-webrtc-reference.py --safe-receive --mixed-traffic \
  --credit-transport webrtc --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-mixed-webrtc
```

Phase and progress records retain `credit_transport`, `snapshot_acknowledged`,
`positions_sent`, `positions_received`, `peak_outstanding`,
`credit_wait_age_ms` and `transfer_ms`. Transfer time starts at the first
probe send and ends when both full snapshots and outgoing snapshot credit
are complete; it excludes partial snapshots, closure and recovery barriers.
`assessment.json.godot_evidence` keeps the last progress and failure snapshot,
including the same counts under `reference`.

Compare repeated HTTP and WebRTC credit runs with the same engine and receiver.
Fresh gameplay progress during an HTTP credit wait helps isolate relay or HTTP
scheduling. A credit-transport timing difference alone cannot prove the cause
of the intermittent stall in #396. Full service sessions and remote-network
qualification remain open.

### Paused Godot reader

Add `--slow-receiver` to pause Godot packet reads for 1,500 ms after
eight snapshot chunks arrive. Engine polling, signaling and sends continue.
The browser reference sender keeps its 32-chunk credit window. Use
`--mixed-traffic` to queue unreliable positions alongside reliable chunks.
Run both HTTP and WebRTC credit controls with the same receiver and engine.

```bash
python scripts/check-webrtc-reference.py --runtime web --offerer reference \
  --safe-receive --mixed-traffic --slow-receiver --require-gameplay \
  --credit-transport webrtc --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-slow-reader
```

Godot phase and progress records retain `receive_pause`: elapsed pause time,
consumed chunks, queued reliable and unreliable packet counts, and resume
state. A gameplay pass requires unchanged consumption during the pause, at
least 24 queued reliable packets, and queued unreliable packets when mixed
traffic is requested. All bytes, metadata, final credit, partial transfers,
remote closure and next-generation recovery must still pass. Reference records
retain `max_credit_wait_ms` to compare the known reader pause with HTTP waits.
Add `--credit-transport http --http-credit-delay-ms 4000` to hold one
first-generation reference credit GET after 32 chunks for four seconds. The report records
whether the hold occurred. The hold consumes the phase deadline. The six-second `observation` remains a snapshot;
Godot keeps an active transfer running until all chunks and credit complete
within the existing deadline. This catches premature teardown during a
progressing HTTP wait.

These opt-in local controls keep the existing deadlines. They do not simulate
WebRTC network delay or establish the cause of #396.

## Native reference engine assessment

A local check paired the native
[Engine at b264ec7](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/native/src/engine.rs)
with Godot 4.3, Linux arm64 with webrtc-native 1.2.2-stable, and Chromium 154.
It used `EngineSettings::default()`, relayed each engine's outgoing signaling
unchanged, and observed each link for 12 seconds before the Godot snapshot.

| Offerer          | Godot runtime  | Result                                                                |
| ---------------- | -------------- | --------------------------------------------------------------------- |
| Godot            | Native and Web | Godot reported up; reference gameplay channels were absent.           |
| Native reference | Native         | Godot released the link after a stream-id collision warning.          |
| Native reference | Web            | Godot reported up; reference open callbacks and gameplay were absent. |

After the ICE envelope fix (#405), all four pairings were repeated with the
same tools and reference commit. Both Godot runtimes and the native reference
reported zero candidate errors. All four still had zero gameplay receipts;
the channel observations in the table were unchanged. Removing the reference
peer cleared its pairing in every run.
A connected peer connection or a local transport-up report cannot prove
cross-client gameplay. Keep these pairings on the server relay. This check
uses the native Engine API with local signaling; full service sessions and
remote-network pairings remain open in #355.

## Demo

`demo/p2p.tscn` is the working example. It connects with a v3 config,
attaches the mesh, and chats over mesh RPCs once a session plan lands. Run
two instances joining the same room to see the peer connection form.

## Live channel drill

Run `godot --path . tests/smoke/webrtc_channel_drill.tscn` with a native
WebRTC extension installed. For Web, export that scene as the main scene
with `tests/smoke/webrtc_channel_drill.gd` included in a temporary export
preset. The default Web preset excludes tests.

The drill creates two real loopback peers, sends gameplay packets, closes
each required channel while the peer connection stays connected, and checks
transport reports before and after multiplayer polling. Each new generation
must restore gameplay, and a Relay plan must remove old links.

The drill also queues real packets before fresh `PlayerJoined` and
`PlayerReconnected` epochs. It checks packets visible through the multiplayer
peer and packets waiting in the data channel before multiplayer polling.
Fresh membership removes both queues from the mesh. Duplicate epochs keep
the live peer. Delayed old-generation work stays fenced until a new plan
restores gameplay. Packets already read by the application remain under
application control.

Godot 4.3 passed these controls on Linux arm64 with webrtc-native
1.2.2-stable and in Chrome 154. A reference-style responder reached SCTP
connection with zero in-band channel announcements from the Godot offerer.
This checks the channel-layout boundary; it does not run either full
reference client. Cross-client gameplay with the reference engines remains
unverified.

Success prints `WEBRTC_CHANNEL_DRILL_PASS`. This drill uses local signaling;
live Signal Fish server delivery and remote-channel resource limits require
separate acceptance.

## Native and browser interoperability

Run the opt-in cross-runtime drill with the installed native extension:

```bash
python scripts/check-webrtc-interop.py --native-extension /path/to/webrtc_native
```

Install the matching Godot Web export templates and
`requirements-docs-accessibility.txt`, then run `playwright install chromium`.
Use `--godot` or `--chromium` to select local executables. `--output` selects
the directory for the isolated projects and logs. The runner exports a
temporary Web project, starts a native seat and Chromium, and relays local
signaling over HTTP. Gameplay flows over real WebRTC channels.

Both seats send and receive reliable, ordered-unreliable, and unreliable
packets. The drill checks payloads, sender ids, transfer modes, negotiated
channel labels and ids. Each seat also streams 256 directed reliable
binary packets, from 1 to 1200 bytes, in batches of four per frame. The
receiver checks exact bytes, sequence, sender, transfer mode, and channel.
With `--mixed-traffic`, each seat sends 32 position updates on each unreliable
mode. Receivers check exact bytes and metadata, reject duplicate sequences,
and require increasing sequences for ordered updates. Gaps are allowed;
each mode must deliver at least one sample in this local drill.
This strict optional scenario can fail on Godot 4.3 due to the packet
metadata limitation below. The default drill sends its transfer modes
separately.
Each generation also sends a MessagePack snapshot of 1,024 players in
1,200-byte reliable chunks. The receiver checks each chunk, reassembles the
snapshot, and compares its exact bytes and decoded values. Chunking belongs
to this drill's application code; the mesh sends packets unchanged.
Seven generations alternate the offerer. In the first six, each seat closes
each required channel once during a second, incomplete snapshot. Each seat
sends 12 chunks, consumes eight and leaves four queued. Both seats must
release those queued packets with the link and report it down before the
next generation restores gameplay. The final generation uses
a Relay plan to remove the link. Each generation must produce one up report
and one down report per seat. Final detach removes the multiplayer peer.

The stream allows at most 32 packets without a receiver acknowledgment.
This bounds queued traffic when one runtime polls more slowly. An earlier
unpaced run filled the browser receive buffer and dropped reliable packets
while the browser waited for a signaling marker. Games should drain incoming
packets each frame and pace sustained sends for their receiver's capacity.

Godot 4.3 on Linux arm64 with webrtc-native 1.2.2-stable and Chromium 154
passed this native-to-browser drill. This covers local connectivity; TURN,
wide-area networking and the server reference engines need separate drills.
Success requires `WEBRTC_INTEROP_PASS` from both seats and a zero native
exit code. The runner retains native and browser logs with the projects.
A failed browser seat still allows the native seat to finish its diagnostic.
Each trial writes `seats.json` with both verdicts, the last stage, the last
completed wait, any failure
snapshot, the native exit code, and any driver error. `diagnostic` stores the
parsed failure snapshot beside its raw log line. The report also records the
browser version and receive scenario. Partial-transfer
failures include sent, received and queued chunk counts plus the received
and expected snapshot byte counts.
The driver reports its 60-second browser observation timeout separately
from the engine's per-stage timeout. Only a browser completion or failure
marker ends browser observation; unrelated console text keeps it running.

To investigate intermittent failures, use `--repeat 3` and retain `--output`.
Add `--baseline /path/to/baseline-checkout` to compare that checkout's addon
with the current addon. Both use the current drill, export settings, engine,
extension, and browser. Trials alternate which version runs first. Each
trial starts fresh seats and signaling queues. `summary.json` records each
result, elapsed time, and log directory. A failed trial keeps the remaining
comparisons running and makes the final command fail. Per-seat logs include
the failure stage and its elapsed time, channel states, sent and received
packet counts, and peak queued packets. Successful stage timings are also
retained. These queue peaks describe the drill workload.

A paired three-trial run captured a baseline stall on 2026-10-25. Current
addon e3c075f passed 3/3; baseline eadc00e passed 2/3. Both used Godot 4.3,
webrtc-native 1.2.2-stable, Chromium 154, and the same drill. The failed
baseline native seat timed out in phase 6 while streaming reliable gameplay:
92 packets received, 192 sent, zero queued, and all three channels open.
The browser seat stopped logging in that stage and had no failure snapshot.
A Rust build ran concurrently during the failed trial. These observations
do not establish whether load, browser scheduling, or transport caused the
stall. Keep the timeout policy unchanged while tracing #396.

Failure snapshots now include the pending stream acknowledgment marker,
per-channel queued packets and buffered bytes, and the largest observed
frame gap in the current wait. Use these to separate an acknowledgment wait
from a receive backlog or stalled frame loop.

Each running seat also logs `WEBRTC_INTEROP_PROGRESS` about once per second.
`seats.json` retains its last valid snapshot as `last_progress`, including
when the seat produces no terminal snapshot. Compare `tick_ms`, stage elapsed
time, packet counts, pending acknowledgment and frame gaps across progress
lines. Signaling counters, last sent/received markers and in-flight HTTP
request ages help distinguish a quiet data channel from delayed signaling.
Progress records contain the same channel state as terminal diagnostics.
A missing terminal record leaves that seat failed.

`browser_observation` records request timings outside the engine loop: completed
and failed signaling requests, current request ages, the last 16 completions,
and ages of the last console message and progress record. Compare these with
`last_progress` to separate delayed HTTP delivery from missing engine progress.
Renderer crashes and engine error output fail the trial.

Use `--safe-receive --metadata-probe` to check metadata through the RPC adapter's
packet API. Use `--safe-receive --mixed-traffic --rpc-traffic` to add actual
`SceneMultiplayer` RPCs: unreliable positions, ordered positions, and a reliable
byte-exact snapshot of 1,024 players in each generation. Both seats release
the RPC receiver before the raw packet checks resume. `--safe-receive` and
`--channel-receive` select separate receive paths; choose one. Baselines used
with the new scenarios must provide `get_safe_multiplayer_peer()`.

Use `--safe-receive --rpc-recovery` to keep one `SceneMultiplayer` and RPC
node across seven link generations. Each generation checks a full snapshot,
unreliable positions and ordered positions, then starts a second snapshot
with four exact chunks. Both seats pause RPC polling, send one more RPC and
select its queued packet. Closing a required channel must discard that packet
and emit one RPC peer-disconnected signal. The same API receives the next
generation through its replacement safe peer. Each channel closes from each
seat in the first six generations; the seventh repeats reliable closure.
This scenario replaces `--rpc-traffic` and the raw stream workload.

`WEBRTC_RPC_RECOVERY_PHASE` records completed generations in both logs and
`seats.json` (`rpc_recovery_phases`). Progress and failure snapshots record
RPC poll counts, polling state, connection/disconnection counts, selected-packet
state and partial snapshot counts. These distinguish a paused receiver from
a missing disconnect callback or stalled snapshot. The original intermittent
stall in #396 still needs a captured root cause.

Use `--safe-receive --rpc-plan-recovery` to keep the same assigned RPC peer
and API through seven generations. Relay plans, empty replacement generations
and player-left events retire links with an RPC selected. Each retirement must
discard selected bytes and emit one disconnect before the next generation
restores exact snapshots and positions. Phase records include `retirement`
and `same_rpc_peer`; failure snapshots include `rpc_retirement`. This scenario
injects service events locally. Full reference service sessions remain open.

Use `--multi-peer` for one native seat and two independent Web seats. It uses
one safe receiver per seat. Both Web engines must report startup within 60
seconds before the native seat starts and the driver releases gameplay. Each
network wait keeps its 15-second deadline. Each peer sends 64 exact 1,200-byte reliable chunks
and 32 exact samples on each unreliable mode to each connected peer. The local
qualification requires every sample, including its sender, destination, mode,
channel and sequence. It does not model network loss.

Before closing the link between seats 0 and 1, the drill queues eight
snapshot chunks and eight samples per unreliable mode on every directed link.
Seats 0 and 1 select a packet from the link that will close. Seat 2 selects a
packet from a surviving link. All seats wait for their 48 queued packets.
Closure must discard the retired sender's selected packet and remaining queue.
Every surviving sender must retain all eight exact packets per mode, its
connection identity and its metadata. Seat 2 must keep its selected packet.
Traffic continues through seat 2. A fresh generation restores the triangle
through the same safe receivers, then relay plans release all links.

Add `--retirement-matrix` to `--multi-peer` to run 18 independent cases.
Each seat closes each required channel toward each other seat. Each case
checks queued mixed-mode snapshots, surviving connection identity and exact
packets, hub traffic, and a fresh triangle through the same safe receivers.
Cases include Web-to-Web links and closure by both offerers and responders.
The three required channels keep their existing negotiation and labels.

Reports live under `trial-NNN/current/case-NN/` (or `baseline`). `summary.json`
records every case, including failures; later cases still run. A seat must
report all gameplay phases and the requested case to pass. Seat progress,
failure and interruption records include `retirement_case`, `closing_seat`,
`remote_seat`, `closing_channel` and `hub_seat`. Channel indices are `0`
(reliable), `1` (ordered) and `2` (unreliable). Each case keeps the usual
startup and network deadlines.

With `--slow-receiver`, full triangles still prove delayed-reader independence.
Hub traffic uses that pause only when the independent native/Web-2 pair
remains connected. Other hub cases keep every reader active; their records
set `delayed_reader_active` to false.

On peer disconnection, discard that peer's partial snapshot assembly in your
game. Keep other peers' assemblies and consumption windows separate. A fresh
link needs a fresh snapshot and a new consumption window.
Native plus two Web seats passed on Godot 4.3, 4.4.1 and 4.7.2 with
webrtc-native 1.2.2-stable and Chromium 154 on Linux arm64. This covers local
Godot mesh pairings. Full reference service sessions remain open.

`WEBRTC_MULTIPEER_PHASE` and `seats.json.multi_peer_phases` retain completed
phases. Progress and failure records include counts per sender and mode,
directed targets and the last packet's metadata.
`WEBRTC_MULTIPEER_INTERRUPTION` and `seats.json.multi_peer_interruptions` retain
completed interruption checks. Their `interrupted_snapshot` includes queue
counts before and after closure, selected metadata at both boundaries and
consumption counts per surviving sender and mode. Progress and failure records
carry the same fields, so a missing arrival, retirement failure or later
recovery stall can be traced separately.
Channel diagnostics include the Godot peer id. `browser_2_observation` and
`browser-2.log` retain the second Web seat's HTTP and transport evidence.
Every seat must complete; a missing terminal or engine error fails the trial.

Keep snapshot sends bounded while receivers poll. The three-seat drill limits
each sender to eight unacknowledged reliable chunks per recipient. Each
recipient acknowledges consumed chunks through the drill's signaling relay. An
unbounded 64-chunk burst on native/Web Godot 4.3 filled the Web receive buffer:
its WebRTC stats recorded all 64 messages, while Godot emitted `Buffer full!
Dropping data.` and the byte checks failed after 55 chunks. Reliable transport
delivery alone does not prove that the game consumed each chunk. Applications
should acknowledge consumed chunks and limit outstanding bytes per recipient.

Add `--slow-receiver` to `--multi-peer` to delay reads on Web seat 1.
Seats 0 and 2 must finish their directed snapshots and position updates before
seat 1 resumes reading. Its queued packets must then pass the same byte,
sender, channel and mode checks. This repeats after selective link retirement
and after the triangle is rebuilt. Each destination has its own credit window;
a delayed recipient leaves the other pair free to finish. The independent
pair and delayed-reader catch-up have separate bounded waits. Each keeps
the existing per-stage limit.

`independent_pair_proof` retains sent, consumed and acknowledged counts when
the fast pair finishes. Seat 1 records `reader_resumed`. Phase reports also
retain `sent_by_target`, `acknowledged_by_target`,
`peak_outstanding_by_target` and `credit_wait_age_ms_by_target`. A rising
credit-wait age with fresh engine progress and browser transport samples
identifies an application waiting for consumption credit. These counts describe
the drill's application pacing; the mesh sends packets unchanged.

Add `--rpc-traffic` to `--multi-peer` to run actual `SceneMultiplayer` RPCs
after each raw-packet phase:

```bash
python scripts/check-webrtc-interop.py --multi-peer --rpc-traffic --slow-receiver \
  --native-extension /path/to/webrtc-native \
  --output /tmp/multi-peer-rpc
```

One assigned RPC API and safe peer stay in place through selective link loss
and the fresh triangle. Each directed pair exchanges 64 snapshot chunks and
32 positions per unreliable mode. RPC handlers check sender, destination,
generation, sequence and exact bytes. This local check requires every sample;
it does not simulate packet loss. Combine it with `--retirement-matrix` to
repeat the RPC stages for every required-channel closure. The driver allows
120 seconds per Web seat for this added workload. Each engine wait still
uses its existing 15-second deadline.

The RPC workload returns credit through reliable gameplay RPCs. Each target
has an eight-chunk window. With `--slow-receiver`, seat 1 pauses RPC polling
while seats 0 and 2 finish their own exchanges. Their
`rpc_independent_pair_proof` must show zero credit and eight outstanding chunks
for seat 1. The paused reader then catches up. A failed or disconnected peer's
assembly and credit are cleared before the next phase; surviving links keep
the same connections.

Phase reports include `rpc.received_by_peer_and_mode`, sent and acknowledged
counts, peak outstanding chunks, and `credit_round_trip_us_by_peer`. These
round trips include receiver scheduling and consumption. They are application
measurements. `rpc_service_poll_count`, `rpc_service_poll_total_us` and
`rpc_service_poll_max_us` measure the explicit RPC polls inside the transfer
wait, including dispatch and acknowledgment work. They exclude setup, barriers
and the raw-packet stage. Use repeated runs on an idle machine to compare
costs; these live measurements are outside the deterministic gate.

The raw stage retains HTTP consumption markers. The RPC stage uses HTTP for
readiness and completion barriers. Comparing the two stages helps separate
HTTP credit delays from WebRTC gameplay progress (#396). Keep their workloads
and timing scopes in view; a faster RPC stage alone cannot identify an earlier
timeout's cause.

`--web-godot /path/to/godot` selects a separate engine for Web import and
export. `--godot` still selects the native engine. Install the Web engine's
matching export templates. Each seat report retains its actual engine banner.
Native and Web Godot 4.4.1 passed the safe metadata probe and seven generations
of safe-peer RPCs, mixed traffic, exact snapshots and interrupted-link recovery
with webrtc-native 1.2.2-stable and Chromium 154 on Linux arm64. The engine-only
metadata control failed on both seats. Godot 4.7.2 passed the safe metadata
probe and the persistent RPC recovery scenario on both native and Web with the same extension and browser. The raw
engine metadata probe failed on both seats. Remote networks still need live
qualification.

`browser_observation.webrtc_stats` retains the last 16 browser transport
samples, with sample ages and per-connection ids. Samples include channel
message/byte counts, ICE/SCTP/DTLS state, nominated candidate-pair byte counts
and round-trip time from the
[WebRTC statistics API](https://www.w3.org/TR/webrtc-stats/#dom-rtcdatachannelstats).
Closed connections leave the observer. A stats request that takes over 750 ms
records an error; other peers and state samples continue. The observer waits
for that request to finish before requesting its stats again.

Signaling request records include the drill `marker` when present. Match a
pending `consumed-PHASE-SEAT-COUNT` marker to the sender's credit wait to
trace delayed consumption acknowledgements. Other signaling records leave
`marker` null.

`relay_observation` records server queue timing for markers in both the mesh
drill and reference assessment. `pending_markers` shows markers waiting for a
destination GET. `recent_dequeues` records their `queue_ms` until that GET
removed them. This measures server queue dwell; the receiving engine may
process the response later. Match each marker and destination with the Web
request timings and the receiving seat's last marker.

Each Godot progress/failure snapshot also retains the last 16 `marker_posts`,
with destination, request result, HTTP code and duration through the engine's
completion callback. A long callback duration with short browser request and
relay queue times points to engine scheduling or HTTP polling. Long queue dwell
points to delayed destination polling. Compare fresh frame/transport samples
before attributing a delay. These timings alone do not prove marker consumption.
Relay histories retain at most 128 pending markers and 128 dequeues. Totals
cover the full trial; `evicted_pending_records` reports missing detail, and
`queue_ms` is null when its enqueue record was evicted.

These samples run outside Godot's frame loop. In a controlled stopped-frame
run, the engine heartbeat aged over 14 seconds while browser stats stayed
fresh. A held HTTP request instead aged over 2.5 seconds while engine progress
and stats continued. A paused browser main thread can stop both timers;
compare both sample ages with HTTP request ages. These controls validate the
diagnostics. The cause of the original intermittent stall remains open.

### Mixed-mode packet metadata

Godot 4.3 can return packet bytes from a different channel than the mode
reported by `WebRTCMultiplayerPeer.get_packet_mode()`. A queued unreliable
packet can keep the cached mode selected when a reliable packet arrives;
the next read then returns the reliable bytes. This was reproduced on
native Linux arm64 with webrtc-native 1.2.2-stable and Chromium 154.
See [issue #403](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/403).

Use `--metadata-probe` for the controlled reproduction. Both seats queue an
unreliable packet, wait for its selection, then queue a reliable packet
before reading. A mode/payload mismatch fails the drill and retains both
seat logs. Use `--mixed-traffic` for the concurrent snapshot workload.
Choose one of these options per run. Both work with `--repeat` and
`--baseline`.

The [Godot 4.3 source](https://github.com/godotengine/godot/blob/4.3/modules/webrtc/webrtc_multiplayer_peer.cpp)
caches the selected channel for metadata, then scans channels again during
the packet read. The addon exposes this engine peer directly. Concurrent
mixed-mode reads through that peer remain affected. The raw packet receive
path below avoids its cached selection. An engine-only run can pass when
packets arrive in a different order.

### Raw packet receive workaround

For manual gameplay packets, use `mesh.receive_packet()` to read bytes and
metadata from the same physical channel. It returns a `ReceivedPacket` with
`peer_id`, `transfer_mode`, `channel` (always `0`), `data`, and `error`.
An empty queue returns `null`. Empty packets remain valid when `error == OK`.
Peers and their three default channels receive turns in round-robin order.

```gdscript
func _process(_delta: float) -> void:
    mesh.poll()
    for _read in range(64):
        var packet = mesh.receive_packet()
        if packet == null:
            break
        if packet.error != OK:
            handle_read_error(packet.error)
            break
        handle_gameplay(packet.peer_id, packet.transfer_mode, packet.data)
```

Use this as the sole receive path. Keep this mesh outside `MultiplayerAPI`
and do not read packets through its `WebRTCMultiplayerPeer`. Sending still
uses that peer's `put_packet`, target, and transfer mode. Poll the mesh each
frame. The reader waits until the connection and all three channels are open;
teardown discards pending packets. It keeps the channel layout unchanged.
High-level RPCs can use `get_safe_multiplayer_peer()` to avoid that selection.

Add `--channel-receive` to `--metadata-probe` or `--mixed-traffic` to test this
path with the same byte, sender, mode, snapshot, and recovery checks.

The controlled probe and two seven-generation mixed runs passed on native
and Web Godot 4.3 with webrtc-native 1.2.2-stable and Chromium 154. The
engine-only control still failed the controlled probe. Native Godot 4.4.1
also reproduced that engine failure and passed the raw receive probe and
seven-generation mixed workload with a Web Godot 4.3 seat. Other engine/export
versions need separate live checks.

### Receive throughput benchmark

Run `godot --headless --path . --script tests/client/mesh_receive_bench.gd`
to measure the raw receiver with 1, 16, 64 and 256 simulated peers. Add
`-- --safe` to measure the safe peer's count, metadata and packet reads.
The benchmark covers dense traffic, one active sender and empty queues.
Dense raw traffic queues 200 packets per channel per peer; dense safe
traffic uses four to bound the exact-count scan workload. Sparse traffic
queues 200 per channel on the last peer. Empty-queue cases measure polling.

Compare repeated runs on the same engine and machine, with the same benchmark
file on each revision. Keep other workloads stopped during measurement.
Readiness checks run when queued bytes are found, so empty peers avoid repeated
channel-state calls. Every actual read still checks all required channels;
safe selected-packet metadata keeps its live lifecycle checks. This measures
script receive work; real network throughput requires the live drills above.
