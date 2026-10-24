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
pairings; direct mesh interoperability with those engines is unverified.

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
Each seat takes a turn as offerer. A Relay plan
removes each old link before the next generation restores gameplay. Final
detach removes the multiplayer peer.

Godot 4.3 on Linux arm64 with webrtc-native 1.2.2-stable and Chromium 154
passed this native-to-browser drill. This covers local connectivity; TURN,
wide-area networking and the server reference engines need separate drills.
Success requires `WEBRTC_INTEROP_PASS` from both seats and a zero native
exit code. The runner retains native and browser logs with the projects.

To investigate intermittent failures, use `--repeat 3` and retain `--output`.
Add `--baseline /path/to/baseline-checkout` to compare that checkout's addon
with the current addon. Both use the current drill, export settings, engine,
extension, and browser. Trials alternate which version runs first. Each
trial starts fresh seats and signaling queues. `summary.json` records each
result, elapsed time, and log directory. A failed trial keeps the remaining
comparisons running and makes the final command fail. Per-seat logs include
the failure stage and channel states, sent and received packet counts, and
peak queued packets. These queue peaks describe the drill workload.

The earlier intermittent timeout still needs a captured recurrence and
baseline comparison. Successful repeated trials establish the tested runs;
they do not identify that timeout's cause.
