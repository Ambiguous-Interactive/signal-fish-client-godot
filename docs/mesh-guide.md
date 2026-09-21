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
- It tears down on `room_left`, `player_left`, `disconnected`,
  `connection_failed`, `reconnected`, and node exit. A replayed plan
  inside `missed_events` cannot revive an old mesh.
- It calls `send_transport_status` on the client only at the aggregate
  0↔1 connected-peer boundaries.
- Peer ids derive deterministically from player UUIDs.

## Related signals

| Signal | Arguments |
| --- | --- |
| `session_plan(plan)` | The negotiated plan (`SFSessionTypes.SessionPlanInfo`). |
| `new_peer(peer_id, you_initiate)` | A peer joined the mesh plan. |
| `signal_received(from_player, generation, signal_payload)` | Signaling payload from another peer. |
| `peer_transport_status(peer_id, transport, connected)` | A peer's transport went up or down. |

## Platform note

Godot 4 ships WebRTC on every platform through the built-in libdatachannel
module. Browser exports use the browser's own WebRTC. The mesh needs no
extra dependencies or GDExtensions.

## Demo

`demo/p2p.tscn` is the working example. It connects with a v3 config,
attaches the mesh, and chats over mesh RPCs once a session plan lands. Run
two instances joining the same room to see the peer connection form.
