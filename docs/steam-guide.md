---
description: "SFSteamIdentityBootstrap: put Steam P2P relay traffic on a Signal Fish room - the room is the membership fence, Steam carries the game."
---

# Steam P2P

`SFSteamIdentityBootstrap` is an opt-in helper that puts Steam P2P traffic on
a Signal Fish room. Steam has no matchmaking to lean on, so the room itself
is the fence: the Signal Fish room owns membership, heartbeats, and
reconnection-ready sessions, while Steam's relay network carries the game
traffic. The bootstrap establishes and fences the Steam connections, and the
game owns what flows over them.

The wire contract mirrors the dotnet client's Steamworks.NET adapter, so a
room can mix bindings in principle: the two SteamId64s ride the game-data
lane under the exact keys `signal_fish_steam_host` and
`signal_fish_steam_peer`, as decimal strings that survive every JSON decoder
losslessly.

## Requirements

- The GodotSteam GDExtension. Desktop platforms only: the Steamworks SDK
  ships no browser library, so web exports keep the relay-only client.
- Steamworks initialized before `start()`, with callbacks pumped each frame
  (`Steam.run_callbacks()` in `_process`, or GodotSteam's embedded mode).
  The bootstrap never pumps them itself, so it stays honest about who owns
  the frame.

## Using the bootstrap

Host:

```gdscript
var bootstrap := SFSteamIdentityBootstrap.new()
add_child(bootstrap)
bootstrap.role = SFSteamIdentityBootstrap.Role.HOST
bootstrap.attach(client)
bootstrap.start()
```

The host publishes its SteamId64 when the room session goes live and
re-publishes on every later join, so late joiners never depend on timing. It
also requests the authority: the fence needs a stable holder, and authority
leaving the host fails the coordination.

Peer:

```gdscript
bootstrap.role = SFSteamIdentityBootstrap.Role.PEER
bootstrap.attach(client)
bootstrap.start()
bootstrap.steam_host_connected.connect(func(host_id: String) -> void:
    # The session to the host is up; send game traffic to host_id over
    # your own P2P channels from here.
)
```

The peer publishes its own id, consumes the host id, and dials it by itself.
`start()` returns `ERR_UNAVAILABLE` when GodotSteam is missing or Steamworks
is uninitialized, so a silent no-op can never look like a fenced session.

## The fence

Steam's rendezvous authenticates the connecting identity (the claim is
Steam's, not the peer's), so the host only checks that the connecting id was
advertised on the room's lane. An unknown requester waits `accept_grace_sec`
(default 5 s) for its advertisement and is refused when it never comes; zero
refuses every requester that was not already advertised. The advertised set
only grows during a session: a member that leaves keeps its entry until the
session ends.

## Channels

The classic Steam P2P API is session-less: there is no listen call and no
connect-success callback. The dial is a one-byte poke on the bootstrap
channel (`steam_channel`, default 1), and the host's reply is the
"connected" event. Run game traffic on your own channels; keep payloads off
the bootstrap channel.

## Signals

| Signal                              | Meaning                                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------------------- |
| `steam_host_id_received(steam_id)`  | The published host id arrived (peer side). Informational; the bootstrap dials by itself. |
| `steam_host_connected(steam_id)`    | The peer's session to the host is up.                                                    |
| `steam_peer_connected(steam_id)`    | The host accepted a fenced peer.                                                         |
| `steam_peer_disconnected(steam_id)` | A fenced peer's session went down (best effort).                                         |
| `coordination_failed(reason)`       | A live-session failure stopped the coordination.                                         |

## Configuration

| Member                      | Meaning                                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------------------ |
| `role`                      | `HOST` fences the accepts; `PEER` dials the published host id.                                   |
| `accept_grace_sec`          | How long the host waits for an unknown requester's lane advertisement. Zero refuses immediately. |
| `host_id_timeout_sec`       | How long a peer waits for the host id before failing. Zero waits forever.                        |
| `steam_connect_timeout_sec` | How long the dial may take before failing. Zero waits forever.                                   |
| `steam_channel`             | The P2P channel the handshake uses. The game owns the rest.                                      |
| `steam`                     | Injectable Steam seam; tests substitute a fake, games leave it null.                             |

## Failure modes

`coordination_failed` fires and the coordination stops when the room
connection closes, the room session ends, the authority leaves the host, the
published host id changes mid-session, the host Steam session closes, or a
dial times out or fails. A dial
that never completed closes its half-open session; an established session
always belongs to the game. `stop()` closes every session the bootstrap
established. Membership enforcement beyond the accept fence (room leave and
rejoin races, the host leaving while peers hold connections) stays the
game's job.

Because the classic P2P API has no session-closed callback, disconnects are
detected by watching `getP2PSessionState` during `poll()` - best effort, and
worth a fallback in the game's own protocol.

## Validation status

CI runs the full bootstrap against a deterministic fake Steam seam (fake
time, fake transport, no GodotSteam). The GodotSteam call surface was
authored against the GodotSteam 4.x sources and docs; live two-client
validation with the Steam client running is the follow-up runbook item
(issue #312).
