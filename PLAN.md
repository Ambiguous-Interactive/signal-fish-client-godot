# Signal Fish — Godot 4 GDScript Client Bindings · Implementation Plan

> **Status:** P0 complete. P1 optional-value policy, transport seam, fake transport, WebSocket transport,
> and deterministic headless transport tests are in place; core client/config/state-machine work remains.
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
| 4 | Test framework | **gdUnit4** (suite + CI). |
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
| Wire envelope, 11 client + 24 server messages | server `src/protocol/messages.rs`; `docs/protocol.md` |
| Types (PlayerId, RoomId, LobbyState, GameDataEncoding, RelayTransport, ConnectionInfo, *Payload structs) | server `src/protocol/types.rs` |
| Error codes (~37–40) | server `src/protocol/error_codes.rs`; client `src/error_codes.rs`; `docs/reference/error-codes.md` |
| Room state machine (Waiting→Lobby→Finalized) | server `src/protocol/room_state.rs`; `docs/concepts/rooms-and-lobbies.md` |
| Authority / spectator / reconnection rules | server `docs/concepts/{authority,spectator-mode,reconnection}.md`; `docs/adr/reconnection-protocol.md` |
| **Gold wire fixtures** (vendor complete copies) | server `.llm/code-samples/protocol/v2-client-messages.jsonl` + `v2-server-messages.jsonl` |
| Client event set (26 variants) | client `src/event.rs`; `docs/events.md` |
| Client method set + config + params + defaults | client `src/polling_client.rs`, `src/client.rs`; `docs/client.md` |

> ⚠️ The upstream JSONL samples use **elided values** (`"..."`, partial fields). They are
> shape-illustrative, not byte-complete. Vendor our own **complete** fixtures derived from the Rust
> structs; cross-check each field against `messages.rs`/`types.rs`. Each fixture file gets a header
> comment recording source repo + path + commit SHA.

### Confirmed facts

- **Transport:** WebSocket, `ws://` (local dev only) / `wss://` (production). Control protocol
  messages use JSON **text** frames.
- **Envelope:** externally tagged — `{"type":"<Name>","data":{...}}`. Unit (no-field) messages
  serialize as `{"type":"X"}` with **no `data` key** (serde `tag="type", content="data"`). Decoder must
  also tolerate `data: null` and missing `data`.
- **11 client→server messages:** `Authenticate`, `JoinRoom`, `LeaveRoom`, `GameData`,
  `AuthorityRequest`, `PlayerReady`, `ProvideConnectionInfo`, `Ping`, `Reconnect`, `JoinAsSpectator`,
  `LeaveSpectator`.
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
    sf_messages.gd                #   builders for the 11 client messages -> Dictionary envelopes
    sf_events.gd                  #   decoder: server Dictionary -> SFDecodedEvent (malformed-safe)
    sf_types.gd                   #   typed value objects + enums (see 4.3)
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
tests/                            # gdUnit4: protocol/, transport/, smoke/, fixtures/
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

**11 send methods (1:1 with client messages, named per Rust client)** — each returns `Error` and is
guarded on session state (room commands require `AUTHENTICATED`; pre-auth emits `protocol_error` +
returns `ERR_UNAUTHORIZED`, sends nothing):

```gdscript
# _send_authenticate()  -> auto on transport open
func join_room(params: JoinRoomParams) -> Error
func leave_room() -> Error
func send_game_data(data: Variant) -> Error
func send_game_data_binary(bytes: PackedByteArray, encoding := SFTypes.GameDataEncoding.MESSAGE_PACK) -> Error
func set_ready() -> Error                            # PlayerReady (toggle)
func request_authority(become_authority: bool) -> Error
func provide_connection_info(info: SFTypes.ConnectionInfo) -> Error
func ping() -> Error
func join_as_spectator(game_name: String, room_code: String, spectator_name: String) -> Error
func leave_spectator() -> Error
```

`JoinRoomParams` = small RefCounted/inner class: `game_name`, `player_name`, `room_code?`,
`max_players?`, `supports_authority?`, `relay_transport?`.

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
- **Reconnect:** open a fresh transport; on open send `Reconnect` instead of `Authenticate`; on
  `Reconnected`, restore cached state from the payload, decode `missed_events` via the same decoder,
  emit `reconnected(info, missed_events)` and let the consumer replay (no hidden re-emit).

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
- **Error codes (`sf_error_codes.gd`):** single source — `enum Code`, `STRING_TO_CODE`/`CODE_TO_STRING`,
  `to_code()`/`to_string()`/`category()` (auth/validation/room/authority/ratelimit/reconnect/spectator/server).
- **MessagePack (`sf_msgpack.gd`):** opt-in (`config.decode_msgpack_payloads`). Default behavior =
  expose binary payload bytes as `PackedByteArray` + hand back the `encoding` enum (no transcode).
  **Rkyv = pass-through bytes only** (zero-copy archive format, not implementable in pure GDScript) —
  documented. `game_data_format` in `Authenticate` is independently settable (tells the server the
  preference) regardless of local decode.

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
  on abnormal close; stop on clean `close()` or terminal codes (`RECONNECTION_TOKEN_INVALID`,
  `RECONNECTION_EXPIRED`).
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
- [ ] `signal_fish_config.gd`; `signal_fish_client.gd` with both state machines, core API
      (configure/connect/auto-authenticate/join/leave/`send_game_data`(JSON)/ping/close + state
      accessors), `_process`/`poll` driver, backpressure + cleanup.
- [ ] Client fake-transport tests: auto-authenticate, decoded receive path, send methods, close/error,
      backpressure enforcement, cleanup, close code/reason surfacing, and pre-auth guard.
- **DoD:** all the above green; matches `.llm/code-samples/gdscript-client-shape.md` contract.
- **Fan-out (after seam freeze):** WS impl ‖ client/state-machine tests.

### P2 — Full protocol depth
**Goal:** Complete the protocol surface.
- [ ] **Authority:** `request_authority`, `authority_changed`, `authority_response` + tests.
- [ ] **Spectators:** `join_as_spectator`/`leave_spectator` + 5 spectator events + `SPECTATING` state + tests.
- [ ] **Reconnection + replay** (lands last — perturbs state most): `reconnect()`, `Reconnected` w/
      `missed_events`, `ReconnectionFailed`, bounded retry + backoff (**injected clock** in tests).
- [ ] Full ~40 error-code surface mapped through `sf_error_codes.gd`.
- [ ] **MessagePack** `sf_msgpack.gd` (opt-in) + raw-bytes pass-through; Rkyv pass-through documented.
- [ ] Add `.llm/skills/reconnection-replay.md` (regenerate index + `agent-check.ps1`).
- **DoD:** every feature has deterministic fake-transport tests; all green.
- **Fan-out:** authority ‖ spectators ‖ reconnection (merge reconnection last).

### P3 — WebRTC P2P helper (optional layer)
**Goal:** Turn server signaling into real peer connections, without bloating the core.
- [ ] `webrtc/sf_webrtc_mesh.gd`: consume `game_starting` + `ConnectionInfo` (SDP/ICE) and
      `provide_connection_info()` to build a `WebRTCMultiplayerPeer` mesh.
- [ ] Browser export uses built-in WebRTC; **native requires the official Godot WebRTC GDExtension** —
      document clearly; the core server-relayed client stays zero-native.
- [ ] P2P example in the demo; tests where deterministic (signaling glue around a fake transport).
- **DoD:** opt-in layer; server-relayed users pay nothing; documented native dependency.

### P4 — Demo + web-export smoke + docs  *(→ context.md "first usable client" DoD met)*
- [ ] `demo/` Godot 4 project: connect→join→game-data→leave (+ optional P2P scene).
- [ ] Headless `WebSocketPeer` smoke test (network-gated/opt-in).
- [ ] **Browser-export manual checklist** executed & recorded: HTTPS host, `wss://`, `Origin`,
      mixed-content (`ws://` from HTTPS) rejection, single-thread export, no native-only sockets.
- [ ] `README.md` + quickstart + API reference reflecting the **real** API; `icon.png`.
- [ ] Update `.llm/code-samples/gdscript-client-shape.md` to the shipped API; add
      `.llm/skills/runtime-architecture.md` (regenerate index + `agent-check.ps1`).
- **DoD:** demo runs in editor + exports to web; docs accurate; all five context.md DoD items met.

### P5 — CI/CD  *(separate from llm-harness.yml)*
- [ ] New `.github/workflows/ci.yml`: `detect` guard (no-op until `addons/signal_fish/**/*.gd` exists) →
      **lint** (`pip install gdtoolkit==4.5.0`; `gdformat --check addons/signal_fish/`; `gdlint ...`) →
      **test** matrix (`MikeSchulze/gdUnit4-action@v1.3.1`, Godot `['4.3.0','4.4.1']`, `paths:
      res://addons/signal_fish/tests`, JUnit upload) → **web-export-smoke**
      (`chickensoft-games/setup-godot@v2.4.1` `use-dotnet:false include-templates:true`; `--import`;
      `--export-release "Web"`; assert artifacts).
- [ ] `permissions: contents: read`; concurrency `cancel-in-progress: true`; `fail-fast: false`.
- [ ] `.github/dependabot.yml` (github-actions weekly + pip).
- [ ] **Do not touch `llm-harness.yml`** (preflight, harness, generated-diff, 5000ms guard stay intact).
- **DoD:** `ci.yml` green across matrix; `llm-harness.yml` still green.

### P6 — Asset Library release + first publish
- [ ] `addons/signal_fish/plugin.cfg` (`version` = git tag, validated in CI); `CHANGELOG.md`
      (Keep-a-Changelog); `icon.png` square ≥128² served from `raw.githubusercontent.com`.
- [ ] `.gitattributes` `export-ignore` for `/.llm /.devcontainer /.github /scripts tests/`; keep addon
      self-contained under `addons/signal_fish/`.
- [ ] `.github/workflows/release.yml` on `release: published`: validate `plugin.cfg version == tag` →
      package addon zip (addons/ at root, exclude dev/test) → GitHub Release →
      `deep-entertainment/godot-asset-lib-action@v0.6.0` with `.asset-template.json.hb` (committed
      curl fallback). `permissions: contents: write` only on the release job.
- [ ] Add `.llm/skills/asset-library-release.md` documenting **one-time manual first submission +
      moderation** and the secrets (regenerate index + `agent-check.ps1`).
- [ ] User adds secrets `GODOT_ASSET_LIBRARY_USERNAME` + `GODOT_ASSET_LIBRARY_PASSWORD` and var
      `GODOT_ASSET_LIBRARY_ASSET_ID` (after first submission); pin third-party actions to commit SHA.
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

Runner: `godot --headless` via the gdUnit4 runner over `res://addons/signal_fish/tests`. Codec (F)
tests need no SceneTree.

---

## 9. CI/CD design

**Two sibling workflows; the harness one is never modified.**

`ci.yml` (triggers: `pull_request`, `push:[main]`; `permissions: contents: read`; concurrency
cancel-in-progress):
- `detect` → outputs `has_addon` (true once `addons/signal_fish/**/*.gd` exists) so jobs no-op at bootstrap.
- `lint-gdscript` → `actions/setup-python@v5`, `pip install gdtoolkit==4.5.0`, `gdformat --check
  addons/signal_fish/`, `gdlint addons/signal_fish/`.
- `test` → matrix `godot: ['4.3.0','4.4.1']`, `MikeSchulze/gdUnit4-action@v1.3.1` (`paths:
  res://addons/signal_fish/tests`, `publish-report`/`upload-report`). *(Adding 4.5.x is a coordinated
  bump to a gdUnit4-v6-compatible action — not a free matrix row.)*
- `web-export-smoke` → `chickensoft-games/setup-godot@v2.4.1` (`use-dotnet:false`,
  `include-templates:true`), `godot --headless --path . --import`, `godot --headless --path .
  --export-release "Web" build/web/index.html`, assert `index.html`+`index.wasm`, upload artifact.

`release.yml` (trigger: `release: published`; `permissions: contents: write` on release job only;
concurrency `cancel-in-progress: false`):
- `package` → assert `plugin.cfg version == ${tag#v}`; `zip -r` the addon (addons/ at root; exclude
  `tests/`, `.gdignore`); `softprops/action-gh-release` (pin SHA) with the zip + generated notes.
- `publish-asset-lib` → see §10.

**Caching:** gdUnit4-action caches Godot internally; setup-godot caches Godot+templates; setup-python +
pip are fast. **Pin third-party actions to commit SHA** (gdUnit4-action, setup-godot,
godot-asset-lib-action, action-gh-release); `actions/*` may stay on major tags.

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
"Submitting to the Asset Library"; `deep-entertainment/godot-asset-lib-action`; `MikeSchulze/gdUnit4-action`;
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

1. **Reconnect `auth_token` origin** — where the client obtains the token (likely in
   `RoomJoined`/`Reconnected` payload or `Connected`). Pin to client `polling_client.rs` + server
   `types.rs`. Gates auto-reconnect; manual `reconnect()` works regardless.
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
- The **full** protocol is implemented and adversarially verified: all 11 client messages / 26 events,
  authority, spectators, reconnection + missed-event replay, MessagePack (opt-in) + binary pass-through,
  and the optional WebRTC P2P helper.
- All five context.md "first usable client" DoD items are met (fixtures pinned to upstream commits;
  fake-transport tests for connect/receive/send/close/error/reconnect/backpressure; close codes/reasons/
  failures/cleanup surfaced; Godot 4 `WebSocketPeer` smoke passes; browser-export manual check done).
- Tests deterministic + green; `gdformat`/`gdlint` clean; `ci.yml` green across the Godot matrix;
  `llm-harness.yml` still green.
- The demo runs in editor and exports to web; README/quickstart/API reference are accurate.
- The first Godot Asset Library entry is published, and tagging a release auto-submits a pending update.
