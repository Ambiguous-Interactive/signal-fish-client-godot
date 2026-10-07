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
re-publishes on every later join and whenever a peer's advertisement arrives
(a peer can start coordinating after the host's publish), so late joiners
never depend on timing. It also requests the authority: the fence needs a
stable holder, and authority leaving the host fails the coordination.

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
dial times out or fails. A dial that never completed and a fence request
still pending close their Steam sessions; an established session always
belongs to the game. `stop()` closes every session the bootstrap opened.
Membership enforcement beyond the accept fence (room leave and
rejoin races, the host leaving while peers hold connections) stays the
game's job.

Because the classic P2P API has no session-closed callback, disconnects are
detected by watching `getP2PSessionState` during `poll()` - best effort, and
worth a fallback in the game's own protocol. A session only reports a drop
after it was seen active: Steam reports connection setup as `connecting`, so
setup never reads as a drop, and a session that never came up fails through
`p2p_session_connect_fail` instead.

## Live drill runbook

CI proves the bootstrap against a fake Steam seam. A live drill proves the
real thing: two Steam seats, two accounts, one relay room, and the checklist
as data (`run_steam_live_drill.gd`, issue #318). Run it before trusting the
bootstrap in a shipped game.

### Seats

- Host seat: a machine with the native Steam client.
- Peer seat: a second machine, or a container image with a desktop Steam
  client (Steam-Headless is a common one) on the same machine.
- Accounts: two Steam accounts. The first login on a seat is interactive
  (Steam Guard), so use burner accounts and keep the seats logged in.
- Steam app: the drills run against app id `480` (Spacewar). Put a
  `steam_appid.txt` file with `480` next to the Godot binary; Steamworks
  reads it when launched outside Steam.
- Engine: Godot 4.4.1 plus the GodotSteam GDExtension 4.21 - the pair the
  opt-in `steam-ext` lane downloads, pins, and checksums; use its copy for
  the seat's drill tree. Version landmines (measured facts:
  `.llm/research/steam-identity.md`):
  - Every GDExtension from 4.16 on needs Godot 4.4 or newer.
  - Godot 4.3 caps at GDExtension 4.15, which ships no linux arm64
    libraries; arm64 seats need the 4.21 extension with Godot 4.4.1.
  - Embedded callbacks broke in 4.14/3.29; auto-init plus embed only
    works from 4.23. The drill harness pumps `run_callbacks()` itself,
    so it needs neither.

### Run

Self-check first - deterministic, no Steam needed:

```sh
python3 -E scripts/run-runtime-checks.py steam-drill
```

Then one process per seat against a real relay. `--app` is your Signal
Fish app id on the relay; the Steam app id above is separate. Start the
host, and read the room code from its `room_joined` row:

```sh
godot --headless --path . --script tests/smoke/run_steam_live_drill.gd ++ --mode=live --seat=host --endpoint=wss://your-relay/socket --app=your-app --player=Host --out=host.json
```

Join the peer to the same room:

```sh
godot --headless --path . --script tests/smoke/run_steam_live_drill.gd ++ --mode=live --seat=peer --endpoint=wss://your-relay/socket --app=your-app --player=Peer --room=CODE --out=peer.json
```

The host seat finishes on `steam_peer_connected`, the peer seat on
`steam_host_connected`. Failed checks exit 1, usage errors exit 2, and
everything else exits 0: passed, and also pending - a seat with no Steam,
or one that runs out of `--deadline-sec`, reports `pending` with the
reason. Read the JSON report's `status` field, never the exit code alone.
The report carries one row per recorded check, with elapsed times.

### Evidence and verdict

- Attach both seat JSON reports.
- Capture Steam's relay log: launch each Steam client with `-lognetapi`;
  it writes all P2P networking info to `log/netapi_log.txt` under the
  Steam install directory.
- Record the verdict on the drill issue (#322). A clean two-machine run
  closes #315; re-scope with the failures when it does not.
- Update `.llm/research/steam-identity.md` open items with the
  fake-vs-real deltas.

## Validation status

CI runs the full bootstrap against a deterministic fake Steam seam (fake
time, fake transport, no GodotSteam). The GodotSteam call surface was
authored against the GodotSteam 4.x sources and docs; live validation
follows the runbook above.
