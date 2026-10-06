---
description: GodotSteam P2P facts behind the SFSteamIdentityBootstrap design (versions, singleton access, callback pumping, wire keys).
triggers: steam, godotsteam, p2p, steamworks, steamid, relay, steam identity bootstrap, p2p_session_request, sendP2PPacket
category: Research
---

# Steam Identity Bootstrap Notes (issue #312)

Source-backed facts for `SFSteamIdentityBootstrap` and its follow-ups.
Authored against GodotSteam 4.x sources (Codeberg `godotsteam/godotsteam`,
branch `godot4`) and the dotnet client's Steamworks.NET adapter
(`signal-fish-client-dotnet` PR #98, `SteamIdentityEnvelope`).

## GodotSteam surface (4.x GDExtension)

- Singleton: `Engine.has_singleton("Steam")` / `Engine.get_singleton("Steam")`
  (registered in `register_types.cpp`). Never reference the bare `Steam`
  identifier in addon code; the script must keep parsing without the
  extension. Warnings-as-errors also ban `signal.property` access on
  `Object`-typed values, so the seam is driven through `.call(...)` /
  `.connect(...)` / `.has_signal(...)`.
- `getSteamID()` returns a plain 64-bit int (GDNative's dictionary-wrapped
  `{"id": ...}` shape is 3.x-only). Id 0 means uninitialized.
- Classic P2P API (session-less): `sendP2PPacket(remote, data, send_type,
channel)` establishes sessions implicitly; `getAvailableP2PPacketSize`
  (NOT `isP2PPacketAvailable`, unbound in 4.x); `readP2PPacket(size, channel)`
  returns `{"data": PackedByteArray, "remote_steam_id": int}` - the public
  docs page still says `steam_id_remote`, so the bootstrap reads both keys.
  `acceptP2PSessionWithUser`, `closeP2PSessionWithUser`,
  `getP2PSessionState` (key `connection_active`) round out the surface.
  Signals: `p2p_session_request(remote_steam_id)`,
  `p2p_session_connect_fail(remote_steam_id, session_error)`.
- `P2P_SEND_RELIABLE == 2` (Steamworks `k_EP2PSendReliable`), pinned as an
  addon const so the duck-typed seam needs no constant lookup.
- Callbacks: `run_callbacks()` per frame, or `steamInit(..., embed_callbacks=
true)`. Embedding was broken in 4.14/3.29 and fixed later; auto-init plus
  embed landed together only in 4.23. The bootstrap pumps nothing itself.
- Versions: current GDExtension `v4.23-gde` needs Godot 4.4+
  (`compatibility_minimum = "4.4"`); Godot 4.3 users need GodotSteam <= 4.21.
  Web export: none (`godotsteam.gdextension` ships no `web.*` libraries; the
  Steamworks SDK has no browser build).

## Wire contract (shared with the dotnet adapter)

- Lane keys, matched verbatim: `signal_fish_steam_host` (the host publishes,
  peers dial it) and `signal_fish_steam_peer` (a peer publishes, the host
  consumes it into the accept fence). Ids are decimal strings, 1-20 digits,
  no leading zero - a raw 64-bit JSON number would lose precision.
- Malformed or foreign lane payloads decode as absent, never as an error:
  the lane is shared with the game's own payloads.
- Godot sends the envelope as JSON via `send_game_data`; Godot's
  `JSON.stringify` output (`{"key":"id"}`) parses with the dotnet codec, and
  the Godot reader is structural, so cross-binding rooms work in principle.

## Deliberate Godot adaptations

- The classic P2P API has no listen call and no connect-success callback, so
  the dial is a one-byte poke on the bootstrap channel and the host's reply
  is the "connected" event. Game traffic stays on the game's channels.
- Session-closed detection does not exist on this API; `poll()` watches
  `getP2PSessionState().connection_active` (best effort).
- Failure paths leave established Steam sessions to the game; a dial that
  never completed closes its half-open session. `stop()` closes everything.

## Open items

- Live two-client validation with the Steam client running - tracked as
  #317 (real-extension seam groundwork), #318 (drill harness), #321
  (dual-seat loopback), #322 (two-machine run + verdict; closes #315).
  No Steam seat in CI; #319 explores one. The dotnet adapter shipped
  under the same honest status.
- Valve deprecated the classic P2P API (ISteamNetworking; still shipped
  in Steamworks 1.65). Migration evaluation: #320.
- GodotSteam version pin guidance for the demo project if a demo integration
  lands.
