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
  `disconnected`, `connection_failed`, `reconnected`, and node exit. A
  replayed plan inside `missed_events` cannot revive an old mesh.
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
down even when its peer connection stays connected. A new plan generation
can create a replacement link. Applications still drive their
`MultiplayerAPI` or poll the multiplayer peer to deliver gameplay packets.

These channel names and negotiated ids are Godot's multiplayer contract.
Compatibility with clients that create their own channel layout requires a
separate interop check.

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
must restore gameplay, and a Relay plan must remove old links. Success prints
`WEBRTC_CHANNEL_DRILL_PASS`. This drill uses local signaling and does not
validate a live Signal Fish server or cross-client channel compatibility.
