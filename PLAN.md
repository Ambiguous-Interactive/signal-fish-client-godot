# Signal Fish — Godot 4 GDScript Client Bindings · Implementation Plan

> **Status:** P0–P2 complete: protocol codec + fixtures (re-pinned to upstream v0.9.1, #12),
> transport seam/adapters, core client/config/state machines, authority, spectators, reconnection +
> replay, and the MessagePack/binary game-data milestone (strict v2/v3 envelope decode, opt-in payload
> decode, raw pass-through for rkyv). Root README + auth primer shipped (#13). The v3 session-plan
> signaling surface (capabilities in `Authenticate`, `SessionPlan`/`Signal`/`NewPeer`/
> `PeerTransportStatus`, ICE pre-gather) has landed, and the P3 WebRTC mesh node that consumes those
> plans is in (#32). The P4 demo project (connect→join→game-data→leave) and the Web export preset +
> scheduled export-smoke CI (#51-adjacent P5) have landed; remaining P4 is the network-gated headless
> smoke test, the browser-export manual checklist, and full docs. P3 is complete (demo P2P example
> landed). P6 store automation is in: addon packaging (plugin.cfg/plugin.gd/icon) + release.yml
> Asset Library submission, credential-gated (#57); the store entry waits on the one-time manual
> bootstrap (see `.llm/skills/asset-library-release.md`). The Godot matrix covers 4.3/4.4.1/4.7.2
> (issue #51); remaining #15 item (Godot 3) is P5/P7 work.
> **Owner repo:** `Ambiguous-Interactive/signal-fish-client-godot`
> **Target:** A beautiful, performant, easy-to-use **pure-GDScript** Godot 4 client for the
> Signal Fish v2 protocol, shipped to the **Godot Asset Library via GitHub Actions** for
> drag-drop use in web + cross-platform games.

---

## Table of contents

- [Table of contents](#table-of-contents)
- [1. Context \& goals](#1-context--goals)
- [2. Locked decisions](#2-locked-decisions)
- [3. Protocol reference \& upstream source-of-truth](#3-protocol-reference--upstream-source-of-truth)
  - [Pin these files (record repo + path + commit SHA in `.llm/research/protocol-fixtures.md`)](#pin-these-files-record-repo--path--commit-sha-in-llmresearchprotocol-fixturesmd)
  - [Confirmed facts](#confirmed-facts)
- [4. Architecture](#4-architecture)
  - [4.1 File layout](#41-file-layout)
  - [4.2 Public `SignalFishClient` API](#42-public-signalfishclient-api)
  - [4.3 Data representation rulings](#43-data-representation-rulings)
  - [4.4 State machines](#44-state-machines)
  - [4.5 Transport abstraction (`sf_transport.gd`)](#45-transport-abstraction-sf_transportgd)
  - [4.6 Protocol codec](#46-protocol-codec)
  - [4.7 Performance \& reliability (web-safe)](#47-performance--reliability-web-safe)
- [5. Prioritized roadmap (P0–P7)](#5-prioritized-roadmap-p0p7)
  - [P0 — Protocol ground-truth + codec  *(foundational; blocks all)*](#p0--protocol-ground-truth--codec--foundational-blocks-all)
  - [P1 — Transport seam + core client + state machines  *(usable for early adopters)*](#p1--transport-seam--core-client--state-machines--usable-for-early-adopters)
  - [P2 — Full protocol depth](#p2--full-protocol-depth)
  - [P3 — WebRTC P2P helper (optional layer)](#p3--webrtc-p2p-helper-optional-layer)
  - [P4 — Demo + web-export smoke + docs  *(→ context.md "first usable client" DoD met)*](#p4--demo--web-export-smoke--docs---contextmd-first-usable-client-dod-met)
  - [P5 — CI/CD  *(separate from llm-harness.yml)*](#p5--cicd--separate-from-llm-harnessyml)
  - [P6 — Asset Library release + first publish](#p6--asset-library-release--first-publish)
  - [P7 — Post-v1 (deferred, each gated)](#p7--post-v1-deferred-each-gated)
- [6. Adversarial sub-agent execution model](#6-adversarial-sub-agent-execution-model)
- [7. Existing harness integration rules](#7-existing-harness-integration-rules)
- [8. Testing strategy \& matrix](#8-testing-strategy--matrix)
- [9. CI/CD design](#9-cicd-design)
- [10. Godot Asset Library publishing](#10-godot-asset-library-publishing)
- [11. Risk register](#11-risk-register)
- [12. Security \& privacy checklist](#12-security--privacy-checklist)
- [13. Open items to verify against upstream](#13-open-items-to-verify-against-upstream)
- [14. Definition of done (v1)](#14-definition-of-done-v1)

---

## 1. Context & goals

This repo now contains the pure-GDScript protocol codec, deterministic protocol fixtures/tests, and the
P1 transport seam/adapters. It also contains the polished `.llm/` AI-context system and PowerShell
validation harness (generator, linter, hooks, CI in `.github/workflows/llm-harness.yml`). This plan
continues that foundation into a complete Godot 4 client addon.

**Why pure GDScript (not a Rust GDExtension binding):** GDScript + `WebSocketPeer` runs everywhere
Godot runs — including web exports — with **zero compilation**, drag-drop install, and trivial Asset
Library distribution. Upstream's own Godot integration for the Rust client uses a Rust GDExtension
(`godot-rust`/gdext, nightly `-Zbuild-std`, `wasm32-unknown-emscripten`), which is heavy to build per
platform and painful to ship via the Asset Library — the opposite of the "easy-to-use / web / asset
store" goal. The repo's `.llm/context.md` already mandates GDScript-first. The Rust client remains the
**behavioral reference** (API names, event set, semantics); we re-implement the wire protocol in GDScript.

**End state:** A `SignalFishClient` Node a developer drops into any scene, configures with an `app_id`,
connects, and drives via typed methods + signals — covering the **full** Signal Fish v2 protocol plus
an optional WebRTC P2P helper, with deterministic tests, headless CI across a Godot matrix, web-export
validation, and automated Asset Library releases.

---

## 2. Locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Implementation approach | **Pure GDScript addon** (no C#, no Rust/GDExtension). Rust client = behavioral reference only. |
| 2 | Public API style | **Rich, typed, idiomatic API** mirroring the Rust client: per-message methods + one snake_case signal per event, with typed payload objects. (Not a thin `send_message(Dictionary)`.) |
| 3 | v1 scope | **Everything**: core + authority + spectators + reconnection/replay + MessagePack binary game data + an **optional WebRTC P2P helper** layer. |
| 4 | Test framework | **Deterministic custom `SceneTree` runners** (`godot --headless --script`), replacing the originally locked gdUnit4 choice (issue #15, item 5): the P0 suites landed as dependency-free runners with byte-pinned fixtures, injected clocks, and synchronous fake transports; gdUnit4 would add a dependency and async harness without adding coverage. CI wires the same runners in. |
| 5 | Engine target | **Godot 4 first** (devcontainer pins `4.3-stable`). Godot 3.6 only post-v1 behind a separate compatibility decision (context.md MVP rule). |

Hard constraint: the existing `.llm/` + PowerShell harness and `llm-harness.yml` CI **must stay green
and untouched**; runtime code lives outside the harness's path scope (see §7).

---

## 3. Protocol reference & upstream source-of-truth

**Relevant upstream repos are public** (verified during planning). Anchor every wire detail to a specific
file **and commit SHA** before implementing — never invent protocol details (canonical rule).

### Pin these files (record repo + path + commit SHA in `.llm/research/protocol-fixtures.md`)

| Concern | Source of truth |
|---|---|
| Wire envelope, 12 client + 24 server messages | server `src/protocol/messages.rs`; `docs/protocol.md` |
| Types (PlayerId, RoomId, LobbyState, GameDataEncoding, RelayTransport, ConnectionInfo, *Payload structs) | server `src/protocol/types.rs` |
| Error codes (62 upstream + cloud `DATABASE_ERROR` alias) | server `src/protocol/error_codes.rs`; client `src/error_codes.rs`; `docs/reference/error-codes.md` |
| Room state machine (Waiting→Lobby→Finalized) | server `src/protocol/room_state.rs`; `docs/concepts/rooms-and-lobbies.md` |
| Authority / spectator / reconnection rules | server `docs/concepts/{authority,spectator-mode,reconnection}.md`; `docs/adr/reconnection-protocol.md` |
| **Gold wire fixtures** (vendor complete copies) | server `.llm/code-samples/protocol/v2-client-messages.jsonl` + `v2-server-messages.jsonl` |
| Client event set (26 variants) | client `src/event.rs`; `docs/events.md` |
| Client method set + config + params + defaults | client `src/polling_client.rs`, `src/client.rs`; `docs/client.md` |

> The upstream v2 JSONL samples are **concrete, complete, round-trip-guarded
> frames** since server v0.9.2 (upstream PRs #612/#613). They are vendored
> byte-identically under `tests/fixtures/upstream/` and the codec is pinned to
> them by `tests/protocol/upstream_samples_tests.gd` (issue #55). The Godot
> fixtures in `tests/fixtures/` remain hand-built supersets (all 24 server
> variants, full-field shapes, fake-placeholder tokens). Each fixture file gets
> a header comment recording source repo + path + commit SHA.

### Confirmed facts

- **Transport:** WebSocket, `ws://` (local dev only) / `wss://` (production). Control protocol
  messages use JSON **text** frames.
- **Envelope:** externally tagged — `{"type":"<Name>","data":{...}}`. Unit (no-field) messages
  serialize as `{"type":"X"}` with **no `data` key** (serde `tag="type", content="data"`). Decoder must
  also tolerate `data: null` and missing `data`.
- **12 client→server messages:** `Authenticate`, `JoinRoom`, `LeaveRoom`, `GameData`,
  `AuthorityRequest`, `PlayerReady`, `StartGame`, `ProvideConnectionInfo`, `Ping`, `Reconnect`,
  `JoinAsSpectator`, `LeaveSpectator`.
- **26 client events** (24 server messages + synthetic `Connected`/`Disconnected`): see the full
  signal list in §4.
- **Binary game data:** current upstream negotiates `game_data_format` after `Authenticate`.
  MessagePack/Rkyv game data uses WebSocket binary frames when negotiated; JSON fallback from binary data
  is sent as `GameData`. The serde text form of `GameDataBinary{from_player, encoding, payload}` remains
  useful for codec fixtures, and the decoder should tolerate both byte arrays and documented base64 strings.
  `encoding ∈ {json, message_pack, rkyv}`.
- **Room state machine:** `Waiting → Lobby → Finalized`; `PlayerReady` toggles; single-player rooms skip
  Lobby; authority is explicit (requested, not auto-assigned); leaving drops `Lobby → Waiting`.
- **Reconnection:** `Reconnect{player_id, room_id, auth_token}` → `Reconnected{...full state..., missed_events:[...]}`
  or `ReconnectionFailed{reason, error_code}`. `missed_events` decoded through the same decoder.
- **Config (`SignalFishConfig`):** `app_id` (required), `sdk_version?`, `platform?`, `game_data_format?`.
  Rust leaves `game_data_format` unset by default; current server negotiation then defaults the connection
  to JSON unless another supported format is requested.

---

## 4. Architecture

Three hard layers, one-way dependencies — **API → protocol (pure/static) ⟂ transport (I/O)**. The
client Node is the only place protocol and transport meet. Polling model: everything driven from
`_process()`/`poll()`; **no threads, no blocking** (web-safe).

### 4.1 File layout

```
addons/signal_fish/
  plugin.cfg                      # name, version(==git tag), author, script=plugin.gd, icon
  plugin.gd                       # @tool EditorPlugin (editor convenience only)
  signal_fish_client.gd           # class_name SignalFishClient (Node) — PUBLIC API
  signal_fish_config.gd           # class_name SignalFishConfig (Resource)
  protocol/                       # PURE static; no Node, no transport import
    sf_envelope.gd                #   {type,data} <-> JSON (stringify/parse_string)
    sf_messages.gd                #   builders for the 12 client messages -> Dictionary envelopes
    sf_events.gd                  #   decoder: server Dictionary -> SFDecodedEvent (malformed-safe)
    sf_types.gd                   #   typed value objects + enums (see 4.3)
    sf_session_types.gd           #   v3 session-plan value objects + Topology/TransportKind enums
    sf_game_data_format.gd        #   pure game-data-format negotiation decisions
    sf_error_codes.gd             #   enum Code + string<->code table + category()
    sf_binary_codec.gd            #   byte-array/base64 compatibility <-> PackedByteArray
    sf_msgpack.gd                 #   pure-GDScript MessagePack encode/decode (opt-in)
    sf_log.gd                     #   leveled logger w/ token/id redaction
  transport/                      # byte/text oriented; NO protocol parsing
    sf_transport.gd               #   abstract base (signals + method contract)
    sf_websocket_transport.gd     #   Godot 4 WebSocketPeer impl
    sf_fake_transport.gd          #   deterministic in-memory test double
  webrtc/                         # OPTIONAL P2P helper (kept out of the core path)
    sf_webrtc_mesh.gd             #   GameStarting/ConnectionInfo -> WebRTCMultiplayerPeer
  icon.png  README.md  LICENSE
demo/                             # Godot 4 demo project
tests/                            # custom SceneTree runners: protocol/, transport/, client/
```

### 4.2 Public `SignalFishClient` API

`extends Node`, `class_name SignalFishClient`.

**Lifecycle & state methods**

```gdscript
func configure(config: SignalFishConfig) -> void
func connect_to_server(url := "") -> Error          # opens transport; auto-sends Authenticate on open
func poll() -> void                                 # called by _process when auto_poll; exposed for headless
func close(code := 1000, reason := "") -> Error     # graceful; keeps polling to capture close frame
func reconnect(player_id: String, room_id: String, auth_token: String) -> Error
func is_connected() -> bool                          # transport CONNECTED
func is_authenticated() -> bool                      # received Authenticated
func get_connection_state() -> ConnectionState
func get_session_state() -> SessionState
func get_player_id() -> String                       # "" if none
func get_room_id() -> String
func get_room_code() -> String
func get_lobby_state() -> SFTypes.LobbyState
func get_players() -> Array                          # Array[SFTypes.PlayerInfo]
func get_spectators() -> Array                       # Array[SFTypes.SpectatorInfo]
func get_buffered_amount() -> int
func set_auto_reconnect(enabled: bool) -> void       # default OFF
```

**12 send methods (1:1 with client messages, named per Rust client)** — each returns `Error` and is
guarded on session state (room commands require `AUTHENTICATED`; pre-auth emits `protocol_error` +
returns `ERR_UNAUTHORIZED`, sends nothing):

```gdscript
# _send_authenticate()  -> auto on transport open
func join_room(params: JoinRoomParams) -> Error
func leave_room() -> Error
func send_game_data(data: Variant) -> Error
func send_game_data_binary(bytes: PackedByteArray) -> Error
func set_ready() -> Error                            # PlayerReady (toggle)
func start_game() -> Error                           # StartGame (finalize lobby)
func request_authority(become_authority: bool) -> Error
func provide_connection_info(info: SFTypes.ConnectionInfo) -> Error
func ping() -> Error
func join_as_spectator(game_name: String, room_code: String, spectator_name: String, password := "") -> Error
func leave_spectator() -> Error
func send_signal(to_peer: String, generation: String, signal_payload) -> Error   # v3 WebRTC relay
func send_transport_status(transport: int, connected: bool) -> Error             # v3, informational
```

`JoinRoomParams` = small RefCounted/inner class: `game_name`, `player_name`, `room_code?`,
`max_players?`, `supports_authority?`, `relay_transport?`, `password?`.

**26 signals (1:1 with events, snake_case)**

```gdscript
# lifecycle / transport-derived
signal connected()
signal disconnected(code: int, reason: String)
signal connection_failed(error: String)
signal protocol_error(error: String)                 # local, non-fatal
# authentication
signal authenticated(app_name: String, organization: String, rate_limits: SFTypes.RateLimitInfo)
signal protocol_info(info: SFTypes.ProtocolInfo)
signal authentication_error(error: String, error_code: SFErrorCodes.Code)
# room lifecycle
signal room_joined(info: SFTypes.RoomJoinedInfo)     # 12 fields collapse to one typed object
signal room_join_failed(reason: String, error_code: SFErrorCodes.Code)
signal room_left()
# presence
signal player_joined(player: SFTypes.PlayerInfo)
signal player_left(player_id: String)
signal player_reconnected(player_id: String)
# game data
signal game_data_received(from_player: String, data: Variant)
signal game_data_binary_received(from_player: String, encoding: SFTypes.GameDataEncoding, payload: PackedByteArray)
# authority
signal authority_changed(authority_player: String, you_are_authority: bool)   # "" when null
signal authority_response(granted: bool, reason: String, error_code: SFErrorCodes.Code)
# lobby
signal lobby_state_changed(lobby_state: SFTypes.LobbyState, ready_players: PackedStringArray, all_ready: bool)
signal game_starting(peer_connections: Array)        # Array[SFTypes.PeerConnectionInfo]
# heartbeat
signal pong()
# reconnection
signal reconnected(info: SFTypes.RoomJoinedInfo, missed_events: Array)
signal reconnection_failed(reason: String, error_code: SFErrorCodes.Code)
# spectator
signal spectator_joined(info: SFTypes.SpectatorJoinedInfo)
signal spectator_join_failed(reason: String, error_code: SFErrorCodes.Code)
signal spectator_left(room_id: String, room_code: String, reason: SFTypes.SpectatorReason, current_spectators: Array)
signal new_spectator_joined(spectator: SFTypes.SpectatorInfo, current_spectators: Array, reason: SFTypes.SpectatorReason)
signal spectator_disconnected(spectator_id: String, reason: SFTypes.SpectatorReason, current_spectators: Array)
# generic server error
signal server_error(message: String, error_code: SFErrorCodes.Code)
# protocol v3 session-plan surface (opt-in via SignalFishConfig capabilities)
signal signal_received(from_player: String, generation: String, signal_payload)
signal new_peer(peer_id: String, you_initiate: bool)
signal session_plan(plan: SFSessionTypes.SessionPlanInfo)
signal peer_transport_status(peer_id: String, transport: SFSessionTypes.TransportKind, connected: bool)
```

### 4.3 Data representation rulings

- **Inbound structured payloads → typed `RefCounted` value objects** (`PlayerInfo`, `SpectatorInfo`,
  `RoomJoinedInfo`, `SpectatorJoinedInfo`, `PeerConnectionInfo`, `RateLimitInfo`, `ConnectionInfo`,
  `ProtocolInfo`) with `from_dict()` / `to_dict()`. Gives autocomplete + typo safety; not `Resource`
  (avoid `.tres`/editor baggage for transient data).
- **Closed sets → GDScript `enum`** (`LobbyState`, `GameDataEncoding`, `RelayTransport`,
  `SpectatorReason`, `SFErrorCodes.Code`) + string⇄enum tables in the owning class.
- **User game data → `Variant`/`Dictionary`** (never wrapped — `GameData.data` is open-ended).
- **Binary → `PackedByteArray`** (from WebSocket binary frames, JSON byte arrays, or documented base64
  strings at the codec boundary) + the `encoding` enum.
- **Optional `error_code` absent → `Code.NONE` (0)** sentinel; unknown server code string → `Code.UNKNOWN`
  (forward-compat). Enum ints are **internal only** — never serialized to the wire (wire uses strings).
- **Config = `Resource`** (`SignalFishConfig`) — authored/reused/inspected in the editor.
- **Optional upstream values exposed through the public Godot API use stable decoded sentinels.**
  `null`/missing optional strings become `""` (`organization`, `authority_player` when no authority);
  `null`/missing optional arrays become empty `Array`/`PackedStringArray`; optional enum-like values become
  the owning `UNKNOWN` enum (`SpectatorReason.UNKNOWN`, future relay/game-data/lobby values); optional
  error codes become `SFErrorCodes.Code.NONE`, while unknown non-empty error-code strings become
  `SFErrorCodes.Code.UNKNOWN`. Typed payload objects keep a `raw` dictionary for callers that need exact
  wire absence/null details. Intentional open JSON payloads (`GameData.data`, `ConnectionInfo.custom.data`)
  preserve JSON `null` as Godot `null`. Outbound optional fields are omitted when unset instead of emitting
  JSON `null`, matching server acceptance and keeping wire messages compact.

### 4.4 State machines

```gdscript
enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, CLOSING, CLOSED, FAILED }
enum SessionState   { UNAUTHENTICATED, AUTHENTICATING, AUTHENTICATED,
                      IN_ROOM_WAITING, IN_ROOM_LOBBY, IN_ROOM_FINALIZED, SPECTATING }
```

- **Connection** matches the `.llm/code-samples/gdscript-client-shape.md` sketch (DISCONNECTED idle,
  CLOSED = observed close frame, FAILED = client abstraction). Keep polling while CLOSING to read
  `get_close_code()`/`get_close_reason()`; map `-1` (abnormal/no close frame) through as-is.
- **Session** layers the protocol on top (independent of connection). Lobby transitions are
  **server-driven** (from `RoomJoined`/`LobbyStateChanged`/`Reconnected`); the client never
  self-promotes. `GameStarting` does not change session state (stays FINALIZED) — it's a one-shot
  instruction event.
- **Reconnect:** open a fresh transport; authenticate, then send
  `Reconnect{player_id, room_id, auth_token}` once `Authenticated` arrives
  (upstream parity: enforcing servers reject any pre-auth message with
  `MissingAppId`; rust client `client_core.rs` re-authenticates every
  reconnection round). On `Reconnected`, restore cached state from the
  payload, decode `missed_events` via the same decoder, emit
  `reconnected(info, missed_events)` and let the consumer replay (no hidden
  re-emit).

### 4.5 Transport abstraction (`sf_transport.gd`)

```gdscript
extends RefCounted
class_name SFTransport
signal opened()
signal packet_received(payload: PackedByteArray, is_text: bool)   # widened from sketch to keep frame type
signal closed(code: int, reason: String)
signal failed(error: String)
func connect_to_url(url: String) -> Error          # abstract
func poll() -> void
func send_text(text: String) -> Error
func send_binary(bytes: PackedByteArray) -> Error
func get_buffered_amount() -> int
func get_ready_state() -> int                      # mirrors WebSocketPeer.State
func close(code := 1000, reason := "") -> void
```

- **`SFWebSocketTransport`** (Godot 4 `WebSocketPeer`): validate scheme; `poll()` → drain all available
  packets up to a per-frame cap (`was_string_packet()` distinguishes text/binary); emit `opened` once on
  CONNECTING→OPEN; on first CLOSED read close code/reason and emit `closed` once; surface handshake/send
  failures via `failed`; `get_buffered_amount()` for backpressure. No protocol parsing. Web-safe.
- **`SFFakeTransport`**: in-memory, no network/timers. `inject_open()`, `inject_text()`,
  `inject_server_message(Dictionary)`, `inject_binary()`, `inject_close(code, reason)`,
  `inject_failure(error)`; records `sent_text[]`/`sent_binary[]`; settable `buffered_amount`,
  `fail_on_connect`. Makes every connect/recv/send/close/error/reconnect/backpressure test synchronous
  and deterministic.

### 4.6 Protocol codec

- **Encode:** `SFMessages.<name>(...)` → Dictionary envelope; omit unset optionals (don't send `null`
  unless upstream requires it); unit messages → `{"type":"X"}` (no `data`).
  `SFEnvelope.encode_client(env) -> String = JSON.stringify(env)`. Binary game data is handled at the
  transport boundary as a WebSocket binary frame after format negotiation; fixture text decoding remains in
  `SFBinaryCodec`.
- **Decode (never crash):** non-text frame → `protocol_error`, keep alive; `JSON.parse_string` failure
  or non-Dictionary → `protocol_error`; missing/unknown `type` → `protocol_error` (forward-compat,
  logged not fatal); per-variant builder reads `data` (default `{}`), builds typed payload via
  `from_dict` with `dict.get(key, default)` coercion. Returns `SFDecodedEvent{signal_name: StringName,
  args: Array}`; the client updates cache then `emit_signal(...)`. Same decoder processes `missed_events`.
  **Decode recursion is depth-bounded** (`MAX_MESSAGE_DEPTH`), and nested `Reconnected` entries inside
  `missed_events` are rejected as non-replayable (matching the Rust client) — a hostile server cannot
  overflow the script stack.
  **Decode output aliases the freshly parsed envelope** (issue #48): `raw` on `DecodedEvent` and typed
  payloads is a read-only view; all decode output from one envelope shares its tree (e.g. a
  `missed_events` entry's raw is visible through the parent event's raw). `to_dict()` returns the
  independent mutable copy. The outbound user-authored `ConnectionInfo` alone keeps a snapshot.
- **Error codes (`sf_error_codes.gd`):** single source — `enum Code` (62 upstream
  codes + the cloud-only `DATABASE_ERROR` alias, string lookups derived from the
  enum) + `from_string()`/`to_wire_string()`/`is_known()`/`category()` (per-code
  map following the upstream doc's category tables; unknown → `UNKNOWN`
  forward-compat; completeness pinned by tests).
- **MessagePack (`sf_msgpack.gd`):** landed (P2). Payload decode is opt-in
  (`config.decode_msgpack_payloads`): decoded values surface through
  `game_data_received`; default behavior exposes the envelope payload bytes as
  `PackedByteArray` + the `encoding` enum (no transcode), and an undecodable
  payload falls back to the bytes path with a `protocol_error` diagnostic.
  `send_game_data_binary(bytes)` sends one raw binary frame — the server tags
  inbound binary with the negotiated format and drops binary on `json`
  connections (server `websocket/connection.rs`), so the client refuses that
  case locally (`ERR_UNAVAILABLE`); no client-side `encoding` parameter exists
  (rust client `send_binary_game_data(payload)` parity).
  **Rkyv = pass-through bytes only** (zero-copy archive format, not
  implementable in pure GDScript) — documented; v2-route rkyv frames carry no
  envelope, so `from_player` is `""` for them. `game_data_format` in
  `Authenticate` is independently settable (tells the server the preference)
  regardless of local decode.
- **Binary game-data envelopes (`sf_binary_frames.gd`):** strict decode of the
  v2 map (`from_player` 16-byte binary UUID → canonical string, `encoding`
  `message_pack`, binary `payload`) and the v3 shape (adds non-zero `seq`/
  `epoch`; `json`/`rkyv` tokens), pinned to server `websocket/sending.rs`
  (`LegacyBinaryGameDataFrame`/`V3BinaryGameDataFrame`) and the rust client's
  `protocol/binary.rs` strictness: string keys, no duplicate/unknown fields,
  no trailing bytes, any unsigned marker width for stamps. Wire format has
  been stable since server v0.4.0; v3 frames only arrive on the separate v3
  WebSocket route, and the decoder accepts both for forward compatibility.
  The effective negotiation is tracked: an unsupported preference downgraded
  to JSON by the server (`Error{UnsupportedGameDataFormat}` and/or absence
  from `ProtocolInfo.game_data_formats`) gates binary send/receive to the
  effective format, not the request. Binary frames are also subject to the
  same CLOSING guard as text events, so late frames cannot surface game data
  after a user close.

### 4.7 Performance & reliability (web-safe)

- Per `poll()`: one `socket.poll()` + drain ≤ `max_inbound_packets_per_poll` (default 64); overflow next
  tick. Reject frames over `config.max_inbound_frame_bytes` (default ~256 KiB) before parsing →
  `protocol_error`, drop, stay connected.
- **Backpressure:** before each send, if `get_buffered_amount() > config.max_buffered_bytes` (default
  ~256 KiB), do not send → return `ERR_BUSY` + emit `protocol_error("transport backpressure")`. No silent
  queue growth.
- **Heartbeat:** optional (`config.heartbeat_interval_sec`, default 0 = off); accumulate delta in
  `_process` (no timer thread); `pong_timeout_sec` → treat as dead link.
- **Auto-reconnect:** OFF by default. When on: exponential backoff + jitter (`base 0.5s`, `factor 2`,
  `cap 15s`, `max_attempts` default 5) via accumulated `_process` delta (**no `OS.delay`/threads**); only
  on abnormal termination (a non-user-initiated close or transport failure — a dead dial must
  consume budget too, or a briefly-unreachable endpoint kills the loop on the first retry); stop
  on clean `close()` or terminal codes (`RECONNECTION_TOKEN_INVALID`,
  `RECONNECTION_EXPIRED`); after a `ReconnectionFailed` the client tears the link down itself so
  consumers always observe a terminal disconnect.
- **Cleanup:** on close/failure disconnect transport signals, null the transport (RefCounted freed),
  clear roster/spectators/ids/lobby state, reset `SessionState=UNAUTHENTICATED`; `_exit_tree()` calls
  `close()`.

---

## 5. Prioritized roadmap (P0–P7)

Serial spine **P0 → P1 → P2 → P3 → P4 → P5 → P6**; P7 is post-v1. Each phase runs the §6 adversarial
loop and exits only on its consensus criteria. Fan-out points noted.

### P0 — Protocol ground-truth + codec  *(foundational; blocks all)*
**Goal:** Pin the protocol and build the pure, testable codec.
- [x] Create `.llm/research/protocol-fixtures.md` recording upstream repo + path + **commit SHA** for
      every concern in §3 (frontmatter `description/triggers/category`, ≤300 lines).
- [x] Vendor **complete** fixtures `tests/fixtures/v2_client_messages.jsonl`,
      `v2_server_messages.jsonl`, `malformed.jsonl` (each with a source-attribution header).
- [x] Implement `sf_envelope.gd`, `sf_messages.gd` (11 builders), `sf_events.gd` (26 decoders),
      `sf_types.gd` (value objects + enums), `sf_error_codes.gd`, `sf_binary_codec.gd`.
- [x] Unit tests: encoders reproduce client fixtures byte-for-byte; decoders consume server fixtures
      into the right typed events; malformed input → `protocol_error`, no crash.
- **DoD:** codec complete + tests green; **no Node, no transport** dependency. Regenerate `.llm` index +
      run `agent-check.ps1` for the new research doc.
- **Fan-out:** fixture capture ‖ codec scaffolding (after the schema note exists).

### P1 — Transport seam + core client + state machines  *(usable for early adopters)*
**Goal:** A real connect→auth→join→send/recv→leave→close client over WebSocket.
- [x] Freeze public runtime API handling for optional upstream values that currently flatten to
      Godot-friendly decoded sentinels (`""`, `UNKNOWN`, empty arrays), including `organization`,
      `authority_player`, and spectator reasons.
- [x] `sf_transport.gd` interface — **freeze = decision gate** before parallel work.
- [x] `sf_fake_transport.gd` + `sf_websocket_transport.gd`.
- [x] Transport adapter tests: fake connect, receive, send, close, error, buffered amount, close
      code/reason, failed-open terminal ordering, WebSocket invalid URL/send failures, and cold-project
      runtime-check cleanup.
- [x] `signal_fish_config.gd` (includes a reserved `credential` slot for the upstream secret-key
      decision — carried as a value, never stitched into URLs, never logged/serialized; see §12);
      `signal_fish_client.gd` with both state machines, core API
      (configure/connect/auto-authenticate/join/leave/`send_game_data`(JSON)/ping/close + state
      accessors), `_process`/`poll` driver, backpressure + cleanup.
- [x] Client fake-transport tests: auto-authenticate, decoded receive path, send methods, close/error,
      backpressure enforcement, cleanup, close code/reason surfacing, and pre-auth guard.
- **DoD:** all the above green; matches `.llm/code-samples/gdscript-client-shape.md` contract.
- **Fan-out (after seam freeze):** WS impl ‖ client/state-machine tests.
- **Notes:** `is_connected()` was renamed `is_connected_to_server()` — Godot 4 `Object.is_connected`
  takes `(signal, callable)` and cannot be shadowed. `is_connected_to_server()` reports transport
  CONNECTED. Inbound frames over `max_inbound_frame_bytes` are dropped with `protocol_error` at the
  client boundary before decode; binary frames on a JSON-negotiated connection are dropped the same
  way (the P2 milestone dispatches them per negotiated format). `sf_log.gd` (redacting logger) landed
  with the client (issue #15),
  and `ws://` from secure web pages is a loud `ERR_INVALID_PARAMETER` (issue #15, R2). With the P2
  binary milestone, `game_data_format` accepts `json`/empty, `message_pack`, and `rkyv`.
  `reconnect()`/`set_auto_reconnect()` landed with the P2 reconnection work;
  `send_game_data_binary()` shipped with the P2 binary game-data milestone. The `credential`
  slot is a plain (non-exported) var so the Resource pipeline can never persist it; it now
  rides `Authenticate` as the upstream `connect_token` field (issue #33).

### P2 — Full protocol depth  *(complete)*
**Goal:** Complete the protocol surface.
- [x] **Authority:** `request_authority`, `authority_changed`, `authority_response` + tests.
- [x] **Spectators:** `join_as_spectator`/`leave_spectator` + 5 spectator events + `SPECTATING`
      state + tests (including lobby updates while spectating and stable rosters).
- [x] **Reconnection + replay** (lands last — perturbs state most): `reconnect()`, `Reconnected` w/
      `missed_events`, `ReconnectionFailed`, bounded retry + backoff (**injected clock** in tests).
      Notes: `reconnect()` authenticates first and sends `Reconnect` once
      `Authenticated` arrives (§4.4; enforcing servers reject pre-auth
      messages);
      `set_auto_reconnect()` retries only non-user-initiated abnormal terminations (closes and
      transport failures) with exponential backoff
      (base 0.5s, factor 2, cap 15s, jitter 0.25) and a `reconnect_max_attempts` budget
      (default 5, exhaustion → `connection_failed`); terminal codes
      (`RECONNECTION_TOKEN_INVALID`/`RECONNECTION_EXPIRED`) stop retrying, and any
      `ReconnectionFailed` tears the link down (`disconnected(-1)`) so consumers observe a
      terminal disconnect. The server-issued
      `reconnection_token` (server `messages.rs` `RoomJoinedPayload`/`ReconnectedPayload`)
      is parsed on every baseline: player baselines with a token retain the auto-reconnect
      context; tokenless and spectator baselines clear it (upstream `client_core.rs`
      `AutoReconnectContext`). Tokens feed the redacting logger. Suite:
      `tests/client/run_reconnect_tests.gd`; skill doc: `.llm/skills/reconnection-replay.md`.
      Follow-up hardening (issues #20/#21): consumer close intent is sticky across one
      termination cascade (double-nested handler cascades cannot arm past a close, and no
      attempt is burned), refused/failed dials drop the pending handshake credentials, the
      directed handshake is once-per-dial with post-handshake duplicates fully silent, a
      failed handshake send resolves the attempt (`reconnection_failed` with `Code.NONE`,
      terminal teardown, auto-reconnect re-arms from the retained context), and transport
      teardown closes the socket instead of dropping it live.
- [x] Full v0.9.1 62-code error-code surface mapped through `sf_error_codes.gd`
      (string⇄enum derived from the enum; per-code category map; unknown →
      `UNKNOWN` forward-compat; `NON_EMITTED` annotations) + `StartGame`
      builder/client method and `password` on joins (issue #26).
- [x] **MessagePack** `sf_msgpack.gd` (opt-in decode; encode for building
      payloads) + raw-bytes pass-through + strict v2/v3 binary envelope
      decoder (`sf_binary_frames.gd`); Rkyv pass-through documented. Suite:
      `tests/protocol/binary_frame_tests.gd` (byte-pinned canonical vectors,
      hostile matrix) + client binary send/receive paths.
- [x] Add `.llm/skills/reconnection-replay.md` (regenerate index + `agent-check.ps1`).
- **DoD:** every feature has deterministic fake-transport tests; all green.
- **Fan-out:** authority ‖ spectators ‖ reconnection (merge reconnection last).

### P3 — WebRTC P2P helper (optional layer)
**Goal:** Turn server signaling into real peer connections, without bloating the core.
- [x] **v3 signaling protocol surface** (landed in #31): `SignalFishConfig` capability
      fields (`protocol_version`, `supported_transports`, `supported_topologies`,
      `requested_capabilities` — omitted when unset, so v2 wire bytes stay identical);
      `sf_session_types.gd` (`SessionPlanInfo`/`SessionPeerInfo`/`DirectEndpointInfo`/
      `IceServerInfo`/`NewPeerInfo`/`PeerTransportStatusInfo` + `Topology`/`TransportKind`
      enums); `sf_messages.gd` `peer_signal`/`transport_status` builders (upstream
      `ClientMessage::Signal` — named `peer_signal` because `signal` is a GDScript keyword —
      and `ClientMessage::TransportStatus`); `sf_events.gd` decoders + client
      `session_plan`/`new_peer`/`signal_received`/`peer_transport_status` signals; ICE
      pre-gather on `RoomJoined`/`Reconnected` (`RoomJoinedInfo.ice_servers`); extended
      `ProtocolInfo` v3 fields; v3 fixture pair pinned to server v0.9.1 + rust authority.
      Upstream anchors: server `src/protocol/messages.rs` (v3 variants),
      `docs/concepts/protocol-versions.md`, rust client `src/protocol.rs`/`src/webrtc.rs`/
      `src/mesh.rs`.
- [x] `webrtc/sf_webrtc_mesh.gd` (#32): consumes `session_plan` + `signal_received`, answers
      with `send_signal` (offers only when the server's `initiate` flag says so — roles are
      never computed locally), applies `ice_servers` (replace, never merge; empty set is
      authoritative), rebuilds retained peers on generation/role change, drops peers absent
      from the latest plan, tears down on
      `room_left`/`player_left`/`disconnected`/`reconnected`/`_exit_tree` (a replayed plan
      inside `missed_events` cannot revive the old mesh), reports `send_transport_status`
      only at the aggregate 0↔1 connected-peer boundaries, and exposes a
      `WebRTCMultiplayerPeer` for high-level multiplayer RPCs. Peer ids come from a pinned
      deterministic FNV-1a UUID→int mapping. Peer-connection and multiplayer-peer factories
      are injectable; the deterministic suite (`tests/client/webrtc_mesh_tests.gd`) runs
      entirely on fakes (PLAN §8).
- [x] Platform note documented (mesh header + README): Godot 4 ships WebRTC on every
      platform via the built-in libdatachannel module; browser exports use the browser's own
      WebRTC. (The old "native needs the WebRTC GDExtension" note was Godot-3-era.) The core
      server-relayed client stays zero-native and the mesh layer is opt-in.
- [x] P2P example in the demo: `demo/p2p.tscn` negotiates a v3 session plan,
      attaches the mesh, and chats over mesh RPCs; booted headless in CI.
- **DoD:** opt-in layer; server-relayed users pay nothing; platform story documented.
  (Demo example landed in `demo/p2p.tscn`.)

### P4 — Demo + web-export smoke + docs  *(→ context.md "first usable client" DoD met)*
- [x] `demo/` Godot 4 project: `demo/main.tscn` connect→join→game-data→leave UI over the
      shipped client API; set as the project main scene so the "Web" export preset builds the demo.
      The P3 P2P example scene lives in `demo/p2p.tscn`.
- [ ] Headless `WebSocketPeer` smoke test (network-gated/opt-in).
- [ ] **Browser-export manual checklist** executed & recorded: HTTPS host, `wss://`, `Origin`,
      mixed-content (`ws://` from HTTPS) rejection, single-thread export, no native-only sockets.
- [x] `README.md` + quickstart + auth primer shipped early (issue #13; snippets verified against
      the shipped API). Remaining: full API reference and `icon.png`.
- [ ] Update `.llm/code-samples/gdscript-client-shape.md` to the shipped API; add
      `.llm/skills/runtime-architecture.md` (regenerate index + `agent-check.ps1`).
- **DoD:** demo runs in editor + exports to web; docs accurate; all five context.md DoD items met.

### P5 — CI/CD  *(separate from llm-harness.yml)*
- [x] New `.github/workflows/ci.yml` (landed during P1 and grown with the suites; custom runners via
      `scripts/run-runtime-checks.sh`). Two parallel jobs: `static` (private-helpers + gdformat +
      gdlint; no Godot install) and `test` (apt deps + cached Godot + the SceneTree suites), so
      wall clock is max(jobs) instead of their sum.
- [x] **Godot version matrix** (issue #15, item 6): `test` runs 4.3-stable + 4.4.1-stable +
      4.7.2-stable (issue #51) as concurrent legs (full suite verified on all); wall clock stays flat
      because the legs run in parallel. The pin-drift guard requires the `project.godot` version to
      appear in the matrix rather than in a single env literal. The apt dependency list was cut to the
      libraries headless Godot actually loads (`libfontconfig1`, `libfreetype6`, `libudev1`;
      verified via `/proc/<pid>/maps`), trimming ~10s off the wall-clock-critical test job. The
      `godot` target also boots the demo scenes (relay + P2P) headless on every leg.
- [x] **Web-export smoke** (moved out of the fast gate): `.github/workflows/web-export-smoke.yml`
      runs weekly + `workflow_dispatch`, so template-download minutes never touch pull_request/push
      runs (same pattern as `protocol-sync.yml`). It imports the project, exports the "Web" preset
      (the demo), asserts `index.html` + `index.wasm`, and uploads the build as an artifact. The
      export was verified end-to-end locally against real 4.3-stable templates.
- [x] `permissions: contents: read`; pip + Godot binary caching (`actions/setup-python` pip cache,
      `actions/cache` on `/usr/local/bin/godot` keyed by version); GDScript tooling installs via
      `uv` (issue #27; ~4× faster than the pip venv path, same pinned gdtoolkit).
- [x] `.github/dependabot.yml` (github-actions weekly + pip + devcontainers).
- [ ] **Do not touch `llm-harness.yml`** (preflight, harness, generated-diff, 5000ms guard stay intact).
- **DoD:** `ci.yml` green across matrix; `llm-harness.yml` still green.

### P6 — Asset Library release + first publish
- [x] `CHANGELOG.md` (Keep-a-Changelog; user-facing changes only) + SemVer
      policy (issue #29). `addons/signal_fish/plugin.cfg` (`version` = git
      tag, validated in CI) + `plugin.gd` + `icon.png` (128²) + addon
      README/LICENSE landed (issue #57).
- [x] `.gitattributes` `export-ignore` for dev/test-only paths (`.llm`,
      `.devcontainer`, `.github`, `scripts`, `tests`, plus `.claude`,
      `.githooks`, `progress`, `.asset-template.json.hb`); addon stays
      self-contained under `addons/signal_fish/`.
- [x] `.github/workflows/release.yml` (landed, issue #28; `workflow_dispatch`
      with a `version` input): validates `vMAJOR.MINOR.PATCH`, cuts release
      notes from the matching `CHANGELOG.md` section, packages the addon zip
      (addons/ at root), and publishes the GitHub Release. A
      `publish-asset-store` job then submits the Asset Library edit via
      `deep-entertainment/godot-asset-lib-action` (SHA-pinned v0.6.0,
      `.asset-template.json.hb`); it skips cleanly until the one-time
      bootstrap below (issue #57).
- [x] Add `.llm/skills/asset-library-release.md` documenting **one-time manual first submission +
      moderation** and the secrets (regenerate index + `agent-check.ps1`).
- [ ] User adds secrets `GODOT_ASSET_LIBRARY_USERNAME` + `GODOT_ASSET_LIBRARY_PASSWORD` and var
      `GODOT_ASSET_LIBRARY_ASSET_ID` (after first submission); pin third-party actions to commit SHA.
      (Action pin landed; only the human bootstrap + credentials remain.)
- **DoD:** first Asset Library entry live; subsequent tags auto-submit a pending edit.

### P7 — Post-v1 (deferred, each gated)
- [ ] Godot 3.6 compat (`WebSocketClient` adapter behind the seam) — only after the separate
      compatibility decision (context.md MVP rule) + `WebSocketClient` smoke tests.
- [ ] Revisit Rkyv (remains pass-through unless upstream offers a JSON-equivalent).

---

## 6. Adversarial sub-agent execution model

Run **once per phase** (grounded in `.llm/skills/adversarial-verification.md`):

1. **Builder (green team):** smallest complete version of the phase DoD; produces diff + tests + a
   **handoff packet** (intent, scope/non-goals, in/out-of-scope files, **upstream commits relied on**,
   compatibility targets, invariants, test matrix, known unknowns, deferred work).
2. **Adversarial reviewer (red team, zero-knowledge):** sees only packet + diff. Classifies each DoD item
   `DONE/PARTIAL/NOT-DONE/CHANGED/UNVERIFIABLE`; files P1/P2/P3 findings, each **citing a specific
   upstream file+commit or test** ("looks right" is rejected). Mandatory axes: **correctness**
   (positive/negative/error/extreme), **protocol parity vs upstream**, **web-export safety**, **API
   ergonomics**, **security/secrets**, **test-coverage gaps**.
3. **Reconciler (green team):** fix confirmed P1/P2 (with covering tests), or defer with owner+rationale,
   or mark unverifiable + add a manual check.
4. **Re-review:** only changed/unresolved items.

**Consensus / exit criteria (the "110/100, zero issues" bar, made testable):**
- Zero open P1/P2 findings (fixed w/ test, or deferred w/ owner+rationale, or unverifiable+manual check).
- All DoD items classified DONE (conservatively).
- Tests deterministic (fake transports, seeded fixtures, **injected clock** — no wall-clock sleeps, no
  live network in fast gates) and **green**.
- `gdformat --check` + `gdlint` clean on changed GDScript.
- Protocol parity cited to upstream commits.
- Harness green if `.llm/**`/scripts touched (regenerated index + `context.md` committed).
- **Final re-review returns empty** (= "needs no revision").

Anti-thrash: cap iterations per phase; if convergence stalls, escalate the disputed finding to a human
decision (architectural-planning Decision Gates) rather than looping forever.

---

## 7. Existing harness integration rules

- Runtime code under `addons/`, `tests/`, `demo/`, `project.godot`, `README`, `PLAN.md`, `CHANGELOG.md`
  is **outside** both harness path predicates → those commits fast-exit green; generator/linter do **not**
  run on them.
- A new **workflow file** under `.github/workflows/` matches the tooling predicate but is YAML, so it
  passes the fast PowerShell guards. **Never add Godot steps into `llm-harness.yml`** — use a separate
  `ci.yml` so the 5000ms fast-path guard is untouched.
- Every new `.llm/*.md` is born with `description`/`triggers`/`category` frontmatter and **≤300 lines**
  (PostToolUse `validate-llm-context.ps1` blocks otherwise). After any `.llm/**` edit:
  1. `pwsh -NoProfile -File scripts/generate-llm-index.ps1`
  2. `pwsh -NoProfile -File scripts/agent-check.ps1`
  3. Commit regenerated `.llm/index.md` + `.llm/context.md` **with** the source edit (CI does
     `git diff --exit-code` on them).
- New `.llm` files by phase: `research/protocol-fixtures.md` (P0); `skills/reconnection-replay.md` (P2);
  `skills/runtime-architecture.md` + update `code-samples/gdscript-client-shape.md` (P4);
  `skills/asset-library-release.md` (P6).
- Don't edit `scripts/lib/LlmHarness.psm1` / hook scripts during runtime phases; if unavoidable, run
  `run-llm-hooks.ps1 -Mode Full -Profile` first. Stop-hook preflight + PostToolUse parse-checks fire only
  for PowerShell/`.llm` edits — GDScript work sees no friction.
- Recovery if a PowerShell file is left unparseable: `pwsh -NoProfile -File scripts/preflight.ps1 -AutoFix`.

---

## 8. Testing strategy & matrix

Legend: **F** = fixture encode/decode (no Node/transport); **K** = FakeTransport behavior; **S** =
WebSocketPeer smoke (network-gated, opt-in).

| Requirement | F | K | S |
|---|---|---|---|
| Envelope tagging `{type,data}` + unit `{type}` | encode 11 vs fixtures | — | — |
| Decode 24 server msgs → typed events | decode fixtures | — | — |
| Auto-Authenticate from config | match fixture | assert `sent_text[0]` on open | real round-trip (manual) |
| JoinRoom incl. omitted optionals | encode variants | gated on auth; pre-auth→`protocol_error`+`ERR_UNAUTHORIZED` | — |
| GameData JSON round-trip | encode/decode | inject → `game_data_received` | — |
| GameDataBinary payload bytes | encode/decode | inject → `game_data_binary_received` | binary frame smoke (manual) |
| Authority req/resp/changed (null→"") | encode/decode | request gated; inject responses | — |
| PlayerReady + LobbyStateChanged + state machine | encode/decode 3 states | set_ready; waiting→lobby→finalized; single-player skip | — |
| GameStarting | decode peer_connections[] | inject; state stays FINALIZED | — |
| ProvideConnectionInfo (5 ConnectionInfo variants) | encode internally-tagged | correct tagged dict sent | — |
| Ping/Pong + heartbeat | encode/decode | heartbeat via poll delta; pong_timeout→close | — |
| RoomJoined rich payload (12 fields) | decode → RoomJoinedInfo | accessors populated | — |
| Presence (joined/left/reconnected) | decode | roster maintained | — |
| Spectator suite (5 events + 2 cmds) | encode/decode | SPECTATING; inject events | — |
| Reconnect + missed_events replay | decode incl. nested | reconnect sends Reconnect not Authenticate; replay array decoded; terminal codes stop retry | end-to-end (manual) |
| Error codes table | string⇄enum; unknown→UNKNOWN; category | absent code→NONE | — |
| Malformed never crashes | bad JSON / missing type / unknown type / wrong types / oversize | inject → `protocol_error`, stays connected | — |
| Connection state machine | — | connect→connected; close→closed+disconnected; fail→FAILED+connection_failed | real open/close (manual) |
| Close code/reason | — | inject_close(1000,"bye") & (-1,"") surface | abnormal drop (manual) |
| Backpressure | — | buffered>max → `ERR_BUSY`+`protocol_error`, nothing sent | — |
| Auto-reconnect backoff/limits | — | injected delta; N attempts; exhaustion→connection_failed; clean close→no retry | — |
| Cleanup on close | — | transport nulled; roster/ids cleared; UNAUTHENTICATED | — |
| Web export | — | — | wss://, Origin, mixed-content (manual checklist) |

Runner: `godot --headless --script` custom `SceneTree` suites over
`tests/` (locked decision #4, issue #15 item 5). Codec (F) tests need no
SceneTree. All GDScript is fully explicitly typed and CI-enforced:
`project.godot` promotes `untyped_declaration` and the `unsafe_*`
Variant-access family (`unsafe_property_access`, `unsafe_method_access`,
`unsafe_call_argument`, `unsafe_cast`) to error, so untyped or unsafely-typed
code fails the existing Godot suite steps (issues #35, #42).

---

## 9. CI/CD design

**Two sibling workflows; the harness one is never modified.**

`ci.yml` (triggers: `pull_request`, `push:[main]`; `permissions: contents: read`; a concurrency
group cancels superseded `pull_request` runs so commit churn does not queue redundant runs — `push`
runs on main are never canceled because merge checks depend on them):
- `static` + `test` jobs (parallel; wall clock is max instead of sum):
  - `static` → `actions/checkout`, `actions/setup-python@v5` (pip cache keyed on
    `requirements-ci.txt`), venv + `gdtoolkit==4.5.0` via `uv`, then `run-runtime-checks.sh`
    `static` (private-helpers + `gdformat --check` + `gdlint`).
  - `test` (Godot matrix) → `actions/checkout`, apt Godot deps, Godot install (cached via
    `actions/cache` on `/usr/local/bin/godot`, keyed by version), and the custom SceneTree
    suites (`run-runtime-checks.sh godot`). Legs: 4.3-stable + 4.4.1-stable + 4.7.2-stable
    (issue #15 item 6; issue #51).

`web-export-smoke.yml` (scheduled weekly cron + `workflow_dispatch`; never on push/PR, so fast-gate
CI time is untouched): installs Godot 4.3-stable with templates
(`chickensoft-games/setup-godot` pinned to SHA; `use-dotnet:false`, `include-templates:true`),
runs `godot --headless --import`, exports `--export-release "Web" build/web/index.html`
(target folder pre-created), asserts `index.html`+`index.wasm`, and uploads the build artifact.

`protocol-sync.yml` (scheduled weekly cron + `workflow_dispatch`; never on push/PR, so fast-gate
CI time is untouched): runs `scripts/check-protocol-sync.py` to fail loudly when the upstream
Rust SDK binding (`tests/compatibility.toml`) moves past the pins recorded in the fixture
headers and `.llm/research/protocol-fixtures.md` (issue #12).

`release.yml` (landed, issue #28; `workflow_dispatch` with a `version` input;
`permissions: contents: write` on the release job only):
- validate `vMAJOR.MINOR.PATCH`, cut release notes from the matching
  `CHANGELOG.md` section (fails loudly when the section is missing),
  `zip -r` the addon (addons/ at zip root), then `gh release create` tags
  and publishes the release with the zip. Asset-store auto-publish stays
  gated on the one-time Asset Library bootstrap (§10, P6).

**Caching:** pip wheels (setup-python cache) and the Godot binary (`actions/cache`) keep the
`protocol` job fast; setup-godot caches Godot+templates for the export smoke.
**Pin third-party actions to commit SHA** (setup-godot, godot-asset-lib-action,
action-gh-release); `actions/*` may stay on major tags.

---

## 10. Godot Asset Library publishing

**Key fact:** the Asset Library does **not** host your zip — an entry points at a git host + a
`download_commit` (commit hash **or git tag**); the library generates the archive from that ref and
records its hash on moderation. So pointing `download_commit` at the **release tag** is sufficient; the
packaged GitHub Release zip is for human downloads/provenance only.

**One-time manual bootstrap (cannot be automated):** push addon + a tag with correct layout → log in at
`godotengine.org/asset-library` (or `POST /asset`) and submit (title, category via
`GET /configure?type=addon`, `godot_version` e.g. `4.3`, `version_string`, `cost=MIT`,
`download_provider=GitHub`, `browse_url`, `issues_url`, `icon_url` on `raw.githubusercontent.com` ≥128²,
`download_commit`=tag) → wait for moderation → record the numeric **asset ID** → store as repo var
`GODOT_ASSET_LIBRARY_ASSET_ID`.

**Automated update per release:** `deep-entertainment/godot-asset-lib-action@v0.6.0` reads
`.asset-template.json.hb` (Handlebars over GitHub context) and does login→addEdit→logout. Template uses
`{{ context.release.tag_name }}` for `version_string` + `download_commit`. **Every edit creates a
*pending* edit a moderator must accept** — a successful POST means "submitted," not "live." Curl fallback
committed alongside:

```bash
BASE=https://godotengine.org/asset-library/api
TOKEN=$(curl -sf -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$GODOT_AL_USER\",\"password\":\"$GODOT_AL_PASS\"}" | jq -r .token)
curl -sf -X POST "$BASE/asset/$ASSET_ID" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"version_string\":\"${TAG#v}\",\"godot_version\":\"4.3\",\"download_commit\":\"$TAG\"}"
curl -sf -X POST "$BASE/logout" -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}"
```

**Secrets/vars:** `GODOT_ASSET_LIBRARY_USERNAME` + `GODOT_ASSET_LIBRARY_PASSWORD` (secrets, publish job
only, never exposed to fork PRs), `GODOT_ASSET_LIBRARY_ASSET_ID` (var). **Packaging:** addon
self-contained under `addons/signal_fish/`; `plugin.cfg` required; include README + LICENSE + icon;
exclude `tests/`, `.llm/`, `.devcontainer/`, `.github/`, `scripts/`, demo (via `.gitattributes
export-ignore`). **Versioning:** SemVer tags `vMAJOR.MINOR.PATCH`; git tag is the single source of truth
(CI asserts `plugin.cfg` matches); keep `CHANGELOG.md`. Pre-1.0 while protocol/API stabilize.

**Sources** (verify live during P6): `godotengine/godot-asset-library/blob/master/API.md`; Godot docs
"Submitting to the Asset Library"; `deep-entertainment/godot-asset-lib-action`;
`chickensoft-games/setup-godot`; `Scony/godot-gdscript-toolkit`.

---

## 11. Risk register

L/I = likelihood/impact (H/M/L).

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Protocol drift vs upstream | H | H | Pin **commit SHAs** in `protocol-fixtures.md`; fixtures from those commits; parity test fails if a fixture's source SHA missing; periodic upstream-diff review. |
| R2 | Web-export incompat (Origin, mixed content, threads, tab suspension) | M | H | Auth **after** open (no handshake headers); enforce `wss://` from HTTPS (clear error on `ws://`); single-thread export; non-blocking poll; P4 manual checklist = hard gate. |
| R3 | MessagePack/Rkyv in pure GDScript | M | M | JSON default/required; MessagePack opt-in (P2); **Rkyv = pass-through only**, documented. |
| R4 | API stability post-publish | M | H | Freeze public surface through P4 loop before P6; SemVer + documented compat policy; breaking ⇒ major bump (sketch already mandates stable names). |
| R5 | WebRTC native dependency | M | M | Core stays zero-native; WebRTC native path documents the official Godot WebRTC GDExtension; browser built-in. Keep helper optional. |
| R6 | Godot version-matrix breakage | M | M | Test 4.3+4.4 matrix; isolate version-specific code behind small adapters; 4.5 = coordinated bump; Godot 3 deferred to P7. |
| R7 | Asset Library partly manual/unofficial | H | M | Automate up to submission; first submission + each edit's moderation are human/serialized; set expectations ("CI-prepared + assisted submission"). |
| R8 | Keeping the PowerShell harness green | M | M | Follow §7 ritual; runtime outside predicates; Godot CI in separate workflow; `agent-check.ps1` before commits touching `.ps1/.llm`. |
| R9 | Non-deterministic tests in fast gates | M | M | Fake transports, seeded fixtures, **injected clock**; live/manual tests labeled and out of mandatory gates. |
| R10 | Concurrent agents diverge API/state machine | M | M | P1 seam freeze + public-API freeze are decision gates; merge shared-state tracks through §6 loop before dependents start; `gdscript-client-shape.md` is the single source. |
| R11 | Secret leakage (`app_id`, `auth_token`) | M | H | §12; enforced by the security review axis. |
| R12 | Over-scoping | M | M | Enforce phase order; nothing from P7 starts until P6 ships; "smallest complete change" per phase. |

---

## 12. Security & privacy checklist

Grounded in `.llm/skills/security-privacy.md` + `web-export.md`; enforced by the §6 security axis and the
P6 release gate.

- [ ] `app_id` / reconnection `auth_token` **never logged** at default level; `sf_log.gd` redacts them on
      all paths; debug (full payloads) opt-in + clearly local-only.
- [ ] Config reserves an explicit `credential` slot (now wired as the upstream
      `Authenticate.connect_token` tenant credential, rust SDK 0.14.0, issue #33):
      values only (never globals), never stitched into URLs, absent from `to_string()`/debug output and
      redacted by the logger.
- [ ] Tokens **never in fixtures** (use fake placeholders); reviewer checks every committed fixture.
- [ ] Tokens not surfaced in error messages or signal payloads.
- [ ] Treat browser `localStorage`/query strings as **user-visible**; prefer in-memory tokens; persist
      reconnection token only with an explicit, documented decision.
- [ ] Authenticate **after** socket open (no `Authorization`/custom handshake headers in browser).
- [ ] Production `wss://`; clear error (no silent fallback) on `ws://` from HTTPS; `Origin` is a
      **server-side** policy (client cannot set it in browser) — document.
- [ ] No secrets/credentials/endpoints committed; keep `.gitignore` exclusions for export creds.
- [ ] CI secrets only in the publish job, least permissions, never echoed, never exposed to fork PRs;
      release artifacts contain no tokens/`.env`/local config (verify packaged file list).
- [ ] Keep dependency footprint small (pure-GDScript JSON path needs no third-party runtime dep); any new
      dep goes through a decision gate.

---

## 13. Open items to verify against upstream

Resolve each by reading the cited upstream file at a specific commit during implementation (mostly P0/P2):

1. ~~**Reconnect `auth_token` origin**~~ **Resolved (2026-09-19):** the token is
   server-issued as `reconnection_token` inside `RoomJoined`/`Reconnected` baselines (server
   `messages.rs`; Rust `client_core.rs`). Parsed into `RoomJoinedInfo.reconnection_token`;
   gates auto-reconnect via the retained context. See `.llm/skills/reconnection-replay.md`.
2. **`missed_events` ordering / sequence numbers** — confirm guarantees in server reconnection module
   before any dedup/replay logic.
3. **`SignalFishConfig` / `JoinRoomParams` exact fields + defaults** — client `client.rs`
   (`game_data_format` defaults unset/client negotiates JSON unless requested, `relay_transport` is
   optional/reserved, whether `sdk_version`/`platform` auto-filled). Godot outbound messages omit unset
   optional fields per §4.3; still verify field defaults before the public config/resource lands.
4. **Unit-variant serialization** — confirm server accepts both `{"type":"Ping"}` and
   `{"type":"Ping","data":null}` (decoder tolerates both regardless).
5. **`RoomJoinedPayload` / `ReconnectedPayload` / `SpectatorJoinedPayload`** full field lists +
   `rename_all` so `from_dict` keys match the wire exactly.
6. **`ConnectionInfo` variant field names** (`direct`/`unity_relay`/`relay`/`webrtc`/`custom`) for
   `ProvideConnectionInfo` round-trip.
7. **`error_code` presence rules** — which events carry mandatory vs optional `error_code` (sets the
   `Code.NONE` sentinel correctly).
8. **Close-code conventions** — any app-specific WS close codes (4xxx) with meanings, before mapping to
   auto-reconnect decisions.
9. **Authority default** — server `room_service.rs` defaults omitted `supports_authority` to `true`, while
   docs imply omitted/false disables authority. Pick the Godot API default before P1 state-machine tests.
10. **Cloud error-code drift** — server/Rust client use `STORAGE_ERROR`; cloud also exposes
    `DATABASE_ERROR`. Decide whether Godot maps cloud-only legacy codes to `UNKNOWN` or named aliases.

---

## 14. Definition of done (v1)

v1 is complete when:
- The **full** protocol is implemented and adversarially verified: all 12 client messages / 26 events,
  authority, spectators, reconnection + missed-event replay, MessagePack (opt-in) + binary pass-through,
  and the optional WebRTC P2P helper.
- All five context.md "first usable client" DoD items are met (fixtures pinned to upstream commits;
  fake-transport tests for connect/receive/send/close/error/reconnect/backpressure; close codes/reasons/
  failures/cleanup surfaced; Godot 4 `WebSocketPeer` smoke passes; browser-export manual check done).
- Tests deterministic + green; `gdformat`/`gdlint` clean; `ci.yml` green across the Godot matrix;
  `llm-harness.yml` still green.
- The demo runs in editor and exports to web; README/quickstart/API reference are accurate.
- The first Godot Asset Library entry is published, and tagging a release auto-submits a pending update.
