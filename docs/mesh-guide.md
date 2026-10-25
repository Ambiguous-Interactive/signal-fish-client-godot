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
multiplayer.multiplayer_peer = mesh.get_multiplayer_peer()
```

`attach(client)` subscribes the mesh to the client's signals and returns
`Error`. `detach()` unsubscribes.

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

Godot's local transport report can be up when the reference Engine has no
channels. Web runs also reported `addIceCandidate` errors. Keep mixed
reference-client rooms on the server relay. The Web responder probes cover
two channels; ordered traffic and full reference-client sessions still need
validation.

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

All four runs had zero gameplay receipts. Removing the reference peer cleared
its pairing. Native reference ICE candidates also caused parse errors in
both Godot runtimes; see
[issue #405](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/405).
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
The engine metadata bug still affects the high-level RPC receive path.

Add `--channel-receive` to `--metadata-probe` or `--mixed-traffic` to test this
path with the same byte, sender, mode, snapshot, and recovery checks.

The controlled probe and two seven-generation mixed runs passed on native
and Web Godot 4.3 with webrtc-native 1.2.2-stable and Chromium 154. The
engine-only control still failed the controlled probe. Native Godot 4.4.1
also reproduced that engine failure and passed the raw receive probe and
seven-generation mixed workload with a Web Godot 4.3 seat. Other engine/export
versions need separate live checks.
