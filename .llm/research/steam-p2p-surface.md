---
description: Verdict and source-anchored facts for moving off the deprecated classic Steam P2P API to Networking Messages (issue #320).
triggers: steam, godotsteam, p2p, networking messages, isteamnetworkingmessages, deprecated, migration, sockets, sdr
category: Research
---

# Steam Post-Deprecation P2P Surface Notes (issue #320)

Valve marked the classic P2P API (ISteamNetworking; the
`sendP2PPacket`/`readP2PPacket` surface the identity bootstrap rides)
deprecated. This note records the evaluated successor and the port shape,
anchored to upstream sources, so a later session can act without redoing
the research.

## Verdict

- Port target: **ISteamNetworkingMessages ("Networking Messages")**. The
  SDK header itself points there for the classic calls ("These APIs are
  deprecated... See ISteamNetworkingMessages"), and it keeps the
  bootstrap's session-less, UDP-like model.
- **Networking Sockets (SDR)** stays out: it is connection-oriented
  (listen/connect with `uint32` handles), needs its own
  `runNetworkingCallbacks()` pump, and exposes poll-group / FakeIP /
  dedicated-server surface irrelevant at this scope. The SDK positions
  Messages as the UDP-port path, built on the same Sockets relay stack.
- Timing: no action now. Steamworks 1.65 (GodotSteam 4.23 and 4.23-gde)
  still ships the classic binds. Revisit triggers are listed below.

## Upstream anchors

- GodotSteam 4.x sources: Codeberg `godotsteam/godotsteam`, branch
  `godot4`, commit `532740f3f9` (2026-10-05). Line refs below are against
  that tree.
- Steamworks SDK headers: public mirror `rlabrecque/SteamworksSDK`,
  branch `main` (SDK 1.65-era; GodotSteam 4.23 release titles pin
  "Steamworks 1.65").
- Classic deprecation (`isteamnetworking.h`): the interface note reads
  "This interface is deprecated and may be removed in a future release of
  the Steamworks SDK. Please see ISteamNetworkingSockets and
  ISteamNetworkingMessages"; the send/receive calls carry "These APIs are
  deprecated, and may be removed in a future version of the Steamworks
  SDK. See ISteamNetworkingMessages." `AllowP2PPacketRelay` is deprecated
  separately; Steam may relay traffic regardless of a `false` argument
  for privacy reasons.
- Messages intent (`isteamnetworkingmessages.h`): "non-connection-oriented
  interface... more like UDP... The underlying connections are established
  implicitly"; it "works on top of the ISteamNetworkingSockets code, so
  you get the same routing and messaging efficiency". Both interfaces
  support unreliable plus reliable messages with fragmentation and
  reassembly.

## GodotSteam Networking Messages surface (4.x GDExtension)

- Methods (bound at `godotsteam.cpp:9304-9309`):
  `acceptSessionWithUser(remote_steam_id)`,
  `closeChannelWithUser(remote_steam_id, channel)`,
  `closeSessionWithUser(remote_steam_id)`,
  `getSessionConnectionInfo(remote_steam_id, get_connection, get_status)`,
  `receiveMessagesOnChannel(channel, max_messages)`,
  `sendMessageToUser(remote_steam_id, data, flags, channel)`.
- Signals: `network_messages_session_request(remote_steam_id)`
  (`:9835`) and `network_messages_session_failed(reason, remote_steam_id,
connection_state, debug_message)` (`:9836`). Both callbacks register in
  the same shared table as the classic P2P signals (`:142-147`), so the
  existing `run_callbacks()` / `embed_callbacks` pumping story carries
  over unchanged (`steamInit`/`steamInitEx`, `:452-544`).
- `receiveMessagesOnChannel` returns an Array of Dictionaries keyed
  `payload` (PackedByteArray), `size`, `connection` (handle), `identity`
  (peer Steam id), `receiver_user_data`, `time_received`,
  `message_number`, `channel`, `flags` (`:3496-3504`); the binding
  releases each message (`:3506`).
- `getSessionConnectionInfo` returns `connection_state`, plus on request
  identity, remote address, POP, end reason/debug, and realtime status
  (ping, quality, send rates, queue time) (`:3442-3474`).
- Send flags arrive as class constants (`BIND_CONSTANT(NETWORKING_SEND_)`,
  `:10062-10070`) following the SDK values (`steamnetworkingtypes.h`):
  Unreliable 0, NoNagle 1, NoDelay 4, Reliable 8, UseCurrentThread 16,
  AutoRestartBrokenSession 32.
- Connection states arrive as the bound `CONNECTION_STATE_*` enum
  (`godotsteam_enums.h:1738-1749`, bound at `godotsteam.cpp:11551-11560`):
  NONE, CONNECTING, FINDING_ROUTE, CONNECTED, CLOSED_BY_PEER,
  PROBLEM_DETECTED_LOCALLY, FIN_WAIT, LINGER, DEAD.
- `sendMessageToUser` returns an int result code (`:3514-3516`); the SDK
  types it EResult. GodotSteam binds neither a messages-side
  `FlushMessagesToUser` nor a messages-specific callback pump.

## Port deltas for the bootstrap seam

The SDK session semantics match the shipped dial design: sending to a
peer implicitly opens a session, success posts no callback ("You should
have the peer send a reply for this purpose" - `isteamnetworkingmessages.h`),
and sending implicitly accepts a pending session from that peer. The
host-side fence maps directly onto
`network_messages_session_request` -> `acceptSessionWithUser`.

- Dial: the one-byte poke plus reply-as-connected fence ports 1:1.
- Receive loop: `readP2PPacket(size, channel)` (one dict, keys
  `data`/`remote_steam_id`) becomes a batch drain over
  `receiveMessagesOnChannel` (keys `payload`/`identity`).
- Failure surfacing: `p2p_session_connect_fail(remote, session_error)`
  becomes `network_messages_session_failed` with an end reason, peer id,
  connection state, and debug text.
- Liveness: Messages also lacks a session-closed callback; the
  `getP2PSessionState().connection_active` poll becomes
  `getSessionConnectionInfo(...).connection_state` checked against
  `CONNECTION_STATE_CONNECTED` / `CLOSED_BY_PEER` /
  `PROBLEM_DETECTED_LOCALLY` - richer state, same best-effort poll.
- Constants: the addon pin moves `P2P_SEND_RELIABLE` (2) to
  `NETWORKING_SEND_RELIABLE` (8). Keep pinning ints for the duck-typed
  seam, as `addons/signal_fish/steam` does today.
- Packet ceiling: classic caps a packet at 1200 bytes; Messages rides the
  Sockets stack with fragmentation and reassembly. Keep the addon's
  max-packet guard for decode safety regardless.
- Unchanged: wire keys `signal_fish_steam_host` / `signal_fish_steam_peer`
  travel over the game data lane, so the transport swap is invisible to
  the identity contract. Version landmines carry over (4.23-gde needs
  Godot 4.4+; see `steam-identity.md`). Web export stays out of scope
  (no Steamworks browser build).

## Revisit triggers

- A GodotSteam changelog entry dropping the classic ISteamNetworking
  binds, or a Steamworks SDK release removing the interface.
- A demo-level Steam integration decision (the `steam-identity.md` pin
  guidance follow-up) that would ship players on the deprecated surface.
- The live drills (#321, #322) validating the classic path; a port
  should re-run the #318 harness against the new seam before any switch.
