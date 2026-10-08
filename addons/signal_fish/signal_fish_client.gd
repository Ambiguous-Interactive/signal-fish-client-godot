class_name SignalFishClient
extends Node

## GDScript Signal Fish v2 client (PLAN §4.2). Configure with a
## [SignalFishConfig], connect over WebSocket, and drive gameplay through the
## typed send methods plus one signal per server event. Everything is polled:
## call [method poll] (or leave [member SignalFishConfig.auto_poll] on) —
## there are no threads and no blocking calls, so web exports work unchanged.

signal connected
signal disconnected(code: int, reason: String)
signal connection_failed(error: String)
signal protocol_error(error: String)
## Server accepted the app authentication. Not emitted on reconnect dials:
## those re-authenticate internally and the consumer observes
## [signal reconnected] (or [signal reconnection_failed]) instead.
signal authenticated(
	app_name: String, organization: String, rate_limits: SFTypesScript.RateLimitInfo
)
signal protocol_info(info: SFTypesScript.ProtocolInfo)
signal authentication_error(error: String, error_code: int)
signal room_joined(info: SFTypesScript.RoomJoinedInfo)
signal room_join_failed(reason: String, error_code: int)
signal room_left
signal player_joined(player: SFTypesScript.PlayerInfo)
signal player_left(player_id: String)
signal player_reconnected(player_id: String)
signal game_data_received(from_player: String, data: Variant)
signal game_data_binary_received(from_player: String, encoding: int, payload: PackedByteArray)
signal authority_changed(authority_player: String, you_are_authority: bool)
signal authority_response(granted: bool, reason: String, error_code: int)
signal lobby_state_changed(lobby_state: int, ready_players: PackedStringArray, all_ready: bool)
signal game_starting(peer_connections: Array[SFTypesScript.PeerConnectionInfo])
signal pong
## [param missed_events] carries decoded [code]DecodedEvent[/code]s; malformed
## entries decode to [code]signal_name == &"protocol_error"[/code] sentinels —
## check them when replaying (see SFEvents).
signal reconnected(
	info: SFTypesScript.RoomJoinedInfo, missed_events: Array[SFTypesScript.DecodedEvent]
)
## [param error_code] is the server's error code, or [code]Code.NONE[/code]
## for a local failure (e.g. a handshake send that never reached the wire).
signal reconnection_failed(reason: String, error_code: int)
signal spectator_joined(info: SFTypesScript.SpectatorJoinedInfo)
signal spectator_join_failed(reason: String, error_code: int)
signal spectator_left(
	room_id: String,
	room_code: String,
	reason: int,
	current_spectators: Array[SFTypesScript.SpectatorInfo]
)
signal new_spectator_joined(
	spectator: SFTypesScript.SpectatorInfo,
	current_spectators: Array[SFTypesScript.SpectatorInfo],
	reason: int
)
signal spectator_disconnected(
	spectator_id: String, reason: int, current_spectators: Array[SFTypesScript.SpectatorInfo]
)
signal server_error(message: String, error_code: int)
## Relayed v3 signal, forwarded verbatim. Payload may be null or a future
## shape; check it before indexing. Empty generation marks a legacy plan.
signal signal_received(from_player: String, generation: String, signal_payload: Variant)
signal new_peer(peer_id: String, you_initiate: bool)
## Latest v3 plan wins. A relay plan with no peers resets the mesh floor.
signal session_plan(plan: SFSessionTypesScript.SessionPlanInfo)
signal peer_transport_status(peer_id: String, transport: int, connected: bool)
## Graceful server-shutdown advisory (v3 only). Informational: the structured
## close that follows stays authoritative; the client never acts on it.
## [code]retry_after_secs[/code] is -1 when the server sent no hint.
signal going_away(deadline_ms: int, retry_after_secs: int)
## Exact delivery-accountability report (v3 only). Informational.
signal delivery_report(report: SFSessionTypesScript.DeliveryReportInfo)
## Terminal response for a room operation (v3 only). The client never issues
## room operations yet, so any result is unsolicited and surfaced verbatim.
signal room_operation_result(result: SFSessionTypesScript.RoomOperationResultInfo)

enum ConnectionState {
	DISCONNECTED,  # idle, no transport
	CONNECTING,  # transport dialing
	CONNECTED,  # transport open
	CLOSING,  # close requested; polling until the close frame arrives
	CLOSED,  # a transport close frame was observed
	FAILED,  # client abstraction for unrecoverable open/send/protocol errors
}

enum SessionState {
	UNAUTHENTICATED,
	AUTHENTICATING,
	AUTHENTICATED,
	IN_ROOM_WAITING,
	IN_ROOM_LOBBY,
	IN_ROOM_FINALIZED,
	SPECTATING,
}

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFGameDataFormatScript = preload("res://addons/signal_fish/protocol/sf_game_data_format.gd")
const SFDiagnosticsScript = preload("res://addons/signal_fish/protocol/sf_diagnostics.gd")
const SFTransportScript = preload("res://addons/signal_fish/transport/sf_transport.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")

## Auto-reconnect backoff (PLAN §4.7): full jitter is deterministic-hostile in
## tests, so the RNG stays internal and the jitter fraction small.
const RECONNECT_BASE_DELAY_SEC := 0.5
const RECONNECT_BACKOFF_FACTOR := 2.0
const RECONNECT_MAX_DELAY_SEC := 15.0
const RECONNECT_JITTER_FRACTION := 0.25

## Redaction-list bound for rotating secrets (issue #274): a hostile relay
## cycling fresh reconnection tokens per baseline must not grow the list
## without a bound. Per-baseline tokens rotate under the cap, evicting the
## oldest; pinned secrets are bounded by the same cap and evict oldest-first,
## so the live credential (re-pinned on every dial) stays redacted (issue #335).
const MAX_REMEMBERED_SECRETS := 16

## Upstream `CloseReason::Kicked`: a kick removes the reconnection record, so
## the episode is over and retrying can never rejoin.
const CLOSE_CODE_KICKED := 4007

const _PLAYER_ROOM_STATES: Array[SessionState] = [
	SessionState.IN_ROOM_WAITING,
	SessionState.IN_ROOM_LOBBY,
	SessionState.IN_ROOM_FINALIZED,
]

## The negotiated formats under which WebSocket binary frames carry game
## data; anything else (json / server-default) drops binary upstream.
const _BINARY_GAME_DATA_FORMATS: Array[int] = [
	SFTypesScript.GameDataEncoding.MESSAGE_PACK,
	SFTypesScript.GameDataEncoding.RKYV,
	SFTypesScript.GameDataEncoding.PROTOBUF,
]

## Active transport adapter. Tests may inject an [code]SFTransport[/code]
## before [method connect_to_server]; otherwise the client builds an
## [code]SFWebSocketTransport[/code].
var transport: SFTransportScript = null

var _config: SignalFishConfigScript = null
var _connection_state: ConnectionState = ConnectionState.DISCONNECTED
var _session_state: SessionState = SessionState.UNAUTHENTICATED
var _secrets: PackedStringArray = PackedStringArray()
var _pinned_secrets := 0
var _player_id := ""
var _room_id := ""
var _room_code := ""
var _lobby_state: int = SFTypesScript.LobbyState.UNKNOWN
var _players: Array[SFTypesScript.PlayerInfo] = []
var _spectators: Array[SFTypesScript.SpectatorInfo] = []
# Credentials for the in-flight reconnect dial (sent on transport open instead
# of Authenticate). Empty auth_token = the next open authenticates normally.
var _reconnect_player_id := ""
var _reconnect_room_id := ""
var _reconnect_auth_token := ""
# Once-per-dial guard for the directed Reconnect handshake: a duplicate
# `Authenticated` server event must never resend the handshake.
var _reconnect_handshake_sent := false
# Once-per-dial guard for `Authenticated` itself: a duplicate event on any
# dial (issue #24) must not re-emit `authenticated` or re-set session state.
var _authenticated_seen := false
# Once-per-dial guard for `Reconnected`: a duplicate event on any dial
# (issue #71) must not re-emit the baseline or replay `missed_events`.
var _reconnected_seen := false
# Once-per-dial guard for `ProtocolInfo`: duplicates must not re-reconcile
# the game-data format or re-emit (issue #82).
var _protocol_info_seen := false
# Stable per-dial fact recorded while the dial credentials are still live;
# handlers consult this, not the credential state `authentication_error` clears.
var _reconnect_dial := false
# Last URL a dial was attempted against. Reconnect/auto-reconnect dials reuse
# it so a session opened with an explicit connect_to_server override rejoins
# the same endpoint; it falls back to config.endpoint_url when never set.
var _last_dial_url := ""
# Retained last-baseline identity for opt-in auto-reconnect (upstream
# client_core.rs AutoReconnectContext: player baselines store, spectator and
# tokenless baselines clear). Survives disconnects; never serialized.
var _context_player_id := ""
var _context_room_id := ""
var _context_auth_token := ""
var _auto_reconnect_enabled := false
var _auto_reconnect_attempts := 0
var _reconnect_timer_running := false
var _reconnect_delay_remaining := 0.0
var _user_close_requested := false
var _reconnect_rng := RandomNumberGenerator.new()
# Dead-link detection (PLAN §4.7, issue #91): delta-accumulated heartbeat.
# A silent link produces no FIN/RST on NAT rebinding or radio loss, so
# without a pong deadline the client sits CONNECTED forever and
# auto-reconnect can never engage.
var _heartbeat_elapsed := 0.0
var _awaiting_pong := false
var _pong_elapsed := 0.0
# True only while the last beat's send was accepted; a refused beat keeps
# retrying each interval while the same pong deadline runs (issue #128).
var _beat_in_flight := false
# Effective negotiated game-data format. UNKNOWN = follow the configured
# preference; the server may downgrade an unsupported preference to JSON at
# Authenticate (an `Error{UnsupportedGameDataFormat}` event and/or an absence
# from `ProtocolInfo.game_data_formats`), and binary sends/receives must
# follow the effective format, not the request.
var _effective_game_data_format: int = SFTypesScript.GameDataEncoding.UNKNOWN
# Protocol version the server negotiated (v3+ only; 0 = v2 or not yet seen).
# Gates the v3-only opaque wire shapes (rkyv/protobuf) on the version the
# server actually picked, not the one the config requested.
var _negotiated_protocol_version := 0
# Latest authoritative session plan. Sends gated on it mirror the rust
# client's ensure_v3 + SessionPlanUnavailable + stale-generation refusals:
# the server relays signals verbatim but refuses generation-less frames at
# parse time (server v0.10.0 required `Signal.generation`), so a stale or
# absent plan generation would only ever surface as a distant generic error
# while the peer waits for a signal that never arrives (issue #330).
var _session_plan_seen := false
var _session_plan_generation := ""


func configure(config: SignalFishConfigScript) -> Error:
	if config == null:
		_emit_protocol_error("configure requires a SignalFishConfig")
		return ERR_INVALID_PARAMETER
	if (
		_connection_state
		in [ConnectionState.CONNECTING, ConnectionState.CONNECTED, ConnectionState.CLOSING]
	):
		_emit_protocol_error("cannot reconfigure while a connection is active")
		return ERR_BUSY
	var problem := config.validation_error()
	if not problem.is_empty():
		_emit_protocol_error("invalid config: %s" % problem)
		return ERR_INVALID_DATA
	_config = config
	_secrets = PackedStringArray()
	_pinned_secrets = 0
	_effective_game_data_format = SFTypesScript.GameDataEncoding.UNKNOWN
	_negotiated_protocol_version = 0
	_remember_secret(config.credential, true)
	# Retained reconnect identities may outlive configure() (it is allowed
	# whenever no connection is active); keep them on the redaction list.
	_remember_secret(_reconnect_auth_token, true)
	_remember_secret(_context_auth_token, true)
	return OK


func connect_to_server(url := "") -> Error:
	if _config == null:
		_emit_protocol_error("connect_to_server requires configure() first")
		return ERR_UNCONFIGURED
	if (
		_connection_state
		in [ConnectionState.CONNECTING, ConnectionState.CONNECTED, ConnectionState.CLOSING]
	):
		_emit_protocol_error("connect_to_server called while a connection is active")
		return ERR_BUSY
	var target := url
	if target.is_empty():
		target = _config.endpoint_url
	# A fresh dial starts a normal Authenticate session, never a stale
	# reconnect handshake.
	_clear_reconnect_credentials()
	return _open_transport(target)


## Opens a fresh transport, authenticates, and then rejoins the room with a
## [code]Reconnect[/code] handshake (player_id + room_id + the server-issued
## auth_token) once [code]Authenticated[/code] arrives. This mirrors the
## upstream Rust client, which re-authenticates on every reconnection round
## because enforcing servers reject any pre-auth message
## (`client_core.rs` @ `fdab2e83`; server `websocket/connection.rs`
## @ `eaae1ca3`). The dial target is the URL the most recent dial targeted
## (an explicit [method connect_to_server] override, else
## [member SignalFishConfig.endpoint_url]); reconfiguring does not retarget a
## retained reconnection identity because tokens are endpoint-bound. On
## [code]Reconnected[/code] the full room state is restored and
## [signal reconnected] fires with the decoded [code]missed_events[/code] for
## the consumer to replay. [signal connected] fires on reconnect dials;
## [signal authenticated] does not (re-authentication is internal, so a
## join-on-auth handler cannot race the handshake). The dial's credentials
## become the retained auto-reconnect identity (issue #73): a rotated token
## replaces a stale one, so a later retry never reuses the old credential.
## Backoff-driven retries need the client in the scene tree so
## [code]_process[/code] runs.
func reconnect(player_id: String, room_id: String, auth_token: String) -> Error:
	if _config == null:
		_emit_protocol_error("reconnect requires configure() first")
		return ERR_UNCONFIGURED
	if (
		_connection_state
		in [ConnectionState.CONNECTING, ConnectionState.CONNECTED, ConnectionState.CLOSING]
	):
		_emit_protocol_error("reconnect called while a connection is active")
		return ERR_BUSY
	if player_id.is_empty() or room_id.is_empty() or auth_token.is_empty():
		_emit_protocol_error("reconnect requires player_id, room_id, and auth_token")
		return ERR_INVALID_PARAMETER
	# Same gate the builders apply (issue #151): a non-UUID identity would be
	# refused by the server's serde parse, so fail fast with the parameter
	# error instead of mid-dial.
	if not SFTypeUtils.is_canonical_uuid_text(player_id):
		_emit_protocol_error("reconnect player_id must be a lowercase hyphenated UUID")
		return ERR_INVALID_PARAMETER
	if not SFTypeUtils.is_canonical_uuid_text(room_id):
		_emit_protocol_error("reconnect room_id must be a lowercase hyphenated UUID")
		return ERR_INVALID_PARAMETER
	var target := _last_dial_url
	if target.is_empty():
		target = _config.endpoint_url
	if target.is_empty():
		_emit_protocol_error(
			"reconnect requires a configured endpoint_url or a previous connect_to_server url"
		)
		return ERR_INVALID_PARAMETER
	# A manual dial carries the freshest known identity: capture it (and its
	# secret) so auto-reconnect never re-arms with a stale token (issue #73).
	_capture_reconnect_context(player_id, room_id, auth_token)
	_reconnect_player_id = player_id
	_reconnect_room_id = room_id
	_reconnect_auth_token = auth_token
	return _open_transport(target)


## Enables opt-in automatic reconnection after an abnormal termination: a
## non-user-initiated close, or a transport failure (including failed dials,
## even ones you initiate). Uses the freshest reconnection identity (the last
## server-issued token, or a later manual [method reconnect] dial's
## credentials); a clean [method close], a terminal reconnection error, or a
## `4007` (kicked) close stops it. When the retry budget is exhausted, a final
## [signal connection_failed] ("auto-reconnect exhausted") is emitted, the
## retained token is dropped, and retrying stops until a fresh baseline
## re-establishes a session. Off by default.
func set_auto_reconnect(enabled: bool) -> void:
	_auto_reconnect_enabled = enabled
	if not enabled:
		_cancel_auto_reconnect()


## Drives the transport. Called from [code]_process[/code] when
## [member SignalFishConfig.auto_poll] is on; call manually otherwise.
func poll() -> void:
	if transport == null:
		return
	transport.poll()


func close(code := 1000, reason := "") -> Error:
	# A deliberate close stops any pending auto-reconnect, marks the resulting
	# transport close as clean, and drops the retained reconnection identity:
	# nothing after a user close may silently rejoin a room.
	_reconnect_timer_running = false
	_reconnect_delay_remaining = 0.0
	_user_close_requested = true
	_capture_reconnect_context("", "", "")
	match _connection_state:
		ConnectionState.CONNECTING:
			_connection_state = ConnectionState.CLOSING
			_reset_heartbeat()
			transport.close(code, reason)
			return OK
		ConnectionState.CONNECTED:
			_connection_state = ConnectionState.CLOSING
			_reset_heartbeat()
			transport.close(code, reason)
			return OK
		_:
			return OK


func is_connected_to_server() -> bool:
	return _connection_state == ConnectionState.CONNECTED


func is_authenticated() -> bool:
	return not _session_state in [SessionState.UNAUTHENTICATED, SessionState.AUTHENTICATING]


func get_connection_state() -> ConnectionState:
	return _connection_state


func get_session_state() -> SessionState:
	return _session_state


func get_player_id() -> String:
	return _player_id


func get_room_id() -> String:
	return _room_id


func get_room_code() -> String:
	return _room_code


func get_lobby_state() -> int:
	return _lobby_state


## Returns a roster snapshot. Later authority changes replace entries, so
## earlier snapshots keep their values (issues #87 and #147).
func get_players() -> Array[SFTypesScript.PlayerInfo]:
	return _players.duplicate()


func get_spectators() -> Array[SFTypesScript.SpectatorInfo]:
	return _spectators.duplicate()


## Current authority player id, or "" while no player holds authority.
## Derived from the cached roster (issue #147), so it stays in step with
## [signal authority_changed] exactly like [method get_players] does.
func get_authority_player() -> String:
	for player: SFTypesScript.PlayerInfo in _players:
		if player.is_authority:
			return player.id
	return ""


func get_buffered_amount() -> int:
	if transport == null:
		return 0
	return transport.get_buffered_amount()


func join_room(params: JoinRoomParams) -> Error:
	var guard := _guard_session_send("join_room")
	if guard != OK:
		return guard
	# Join passwords are secrets like tokens: redact them from any log line.
	_remember_secret(params.password, true)
	var max_players: Variant = null
	if params.max_players > 0:
		max_players = params.max_players
	var envelope := SFMessagesScript.join_room(
		params.game_name,
		params.player_name,
		_optional_string(params.room_code),
		max_players,
		params.supports_authority,
		params.relay_transport,
		_optional_string(params.password)
	)
	return _send_envelope(envelope, "join_room")


func leave_room() -> Error:
	var guard := _guard_session_send("leave_room")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.leave_room(), "leave_room")


func send_game_data(data: Variant) -> Error:
	var guard := _guard_session_send("send_game_data")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.game_data(data), "send_game_data")


## Sends opaque game-data bytes as one WebSocket binary frame. Upstream
## semantics: the server tags inbound binary with the negotiated format and
## drops binary on [code]json[/code] connections
## (server `websocket/connection.rs`), so the client refuses that case
## locally. Pair with [member SignalFishConfig.game_data_format] set to
## [code]message_pack[/code] or an opaque [code]rkyv[/code]/[code]protobuf[/code]
## request (server issue #627; opaque encodings are v3-only). If the server
## downgraded the requested format (see [signal protocol_info]), the
## effective negotiation rules.
func send_game_data_binary(bytes: PackedByteArray) -> Error:
	var guard := _guard_session_send("send_game_data_binary")
	if guard != OK:
		return guard
	if bytes.is_empty():
		_emit_protocol_error("send_game_data_binary requires non-empty bytes")
		return ERR_INVALID_PARAMETER
	var negotiated := _negotiated_game_data_format()
	if not _BINARY_GAME_DATA_FORMATS.has(negotiated):
		_emit_protocol_error(
			(
				"send_game_data_binary requires a binary game_data_format"
				+ " (message_pack, rkyv, or protobuf); this connection"
				+ " negotiates %s" % _game_data_format_label(negotiated)
			)
		)
		return ERR_UNAVAILABLE
	if (
		negotiated != SFTypesScript.GameDataEncoding.MESSAGE_PACK
		and _negotiated_protocol_version < 3
	):
		# Defense in depth: ProtocolInfo already downgraded a v2-opaque
		# request; without that statement the version is unknown, and the
		# opaque v2 pass-through carries no sender attribution (issue #627).
		_emit_protocol_error(
			(
				"%s game data requires protocol version 3; no v3 negotiation seen"
				% _game_data_format_label(negotiated)
			)
		)
		return ERR_UNAVAILABLE
	var buffered: int = transport.get_buffered_amount()
	if buffered > _config.max_buffered_bytes:
		_emit_protocol_error(
			(
				(
					"transport backpressure: %d buffered bytes exceeds cap %d;"
					+ " send_game_data_binary dropped"
				)
				% [buffered, _config.max_buffered_bytes]
			)
		)
		return ERR_BUSY
	if bytes.size() > _config.max_outbound_frame_bytes:
		_emit_protocol_error(
			(
				"send_game_data_binary: %d bytes exceeds outbound cap %d"
				% [bytes.size(), _config.max_outbound_frame_bytes]
			)
		)
		return ERR_INVALID_DATA
	var error: Error = transport.send_binary(bytes)
	if error != OK:
		_emit_protocol_error("send_game_data_binary send failed: %s" % error_string(error))
	return error


func set_ready() -> Error:
	var guard := _guard_session_send("set_ready")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.player_ready(), "set_ready")


## Explicitly finalizes the lobby with its current members (upstream
## `StartGame`). The server accepts it only when every current player is ready
## and the sender may start (authority-designated rooms restrict it to the
## authority); failures surface through [signal server_error] with
## [code]GameStartNotReady[/code] / [code]GameStartForbidden[/code].
func start_game() -> Error:
	var guard := _guard_session_send("start_game")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.start_game(), "start_game")


func request_authority(become_authority: bool) -> Error:
	var guard := _guard_session_send("request_authority")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.authority_request(become_authority), "request_authority")


func provide_connection_info(info: SFTypesScript.ConnectionInfo) -> Error:
	var guard := _guard_session_send("provide_connection_info")
	if guard != OK:
		return guard
	if info == null:
		_emit_protocol_error("provide_connection_info requires a ConnectionInfo")
		return ERR_INVALID_PARAMETER
	return _send_envelope(
		SFMessagesScript.provide_connection_info(info.to_dict()), "provide_connection_info"
	)


func ping() -> Error:
	var guard := _guard_session_send("ping")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.ping(), "ping")


func join_as_spectator(
	game_name: String, room_code: String, spectator_name: String, password := ""
) -> Error:
	var guard := _guard_session_send("join_as_spectator")
	if guard != OK:
		return guard
	_remember_secret(password, true)
	return _send_envelope(
		SFMessagesScript.join_as_spectator(
			game_name, room_code, spectator_name, _optional_string(password)
		),
		"join_as_spectator"
	)


func leave_spectator() -> Error:
	var guard := _guard_session_send("leave_spectator")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.leave_spectator(), "leave_spectator")


## Relay one opaque WebRTC signal to [param to_peer] (protocol v3). Refused
## locally — with nothing on the wire — unless the connection negotiated v3,
## a [signal session_plan] has arrived, and [param generation] equals that
## plan's generation ("" only on legacy plans whose own generation is ""):
## the pinned server (v0.9.1+) requires `generation` at parse time, so an
## off-plan signal would be dropped server-side with only a generic error
## while the peer waits (issue #330, rust-client parity). [param
## signal_payload] is forwarded verbatim.
func send_signal(to_peer: String, generation: String, signal_payload: Variant) -> Error:
	var guard := _guard_session_send("send_signal")
	if guard != OK:
		return guard
	if _refuse_pre_v3("send_signal"):
		return ERR_UNAVAILABLE
	if not _session_plan_seen:
		_emit_protocol_error("send_signal requires a session plan; none seen on this connection")
		return ERR_UNAVAILABLE
	if generation != _session_plan_generation:
		_emit_protocol_error("send_signal generation must match the latest session_plan generation")
		return ERR_INVALID_PARAMETER
	return _send_envelope(
		SFMessagesScript.peer_signal(to_peer, generation, signal_payload), "send_signal"
	)


## Report the current data-path transport state (protocol v3; informational).
## Refused locally before a v3 negotiation for the same reason as
## [method send_signal]. [param transport_kind] takes a
## [enum SFSessionTypes.TransportKind] value.
func send_transport_status(transport_kind: int, is_up: bool) -> Error:
	var guard := _guard_session_send("send_transport_status")
	if guard != OK:
		return guard
	if _refuse_pre_v3("send_transport_status"):
		return ERR_UNAVAILABLE
	return _send_envelope(
		SFMessagesScript.transport_status(transport_kind, is_up), "send_transport_status"
	)


func _refuse_pre_v3(action: String) -> bool:
	if _negotiated_protocol_version >= 3:
		return false
	if _negotiated_protocol_version == 0:
		_emit_protocol_error("%s requires protocol version 3; no v3 negotiation seen" % action)
	else:
		_emit_protocol_error(
			(
				"%s requires protocol version 3; this connection negotiates v%d"
				% [action, _negotiated_protocol_version]
			)
		)
	return true


func _process(delta: float) -> void:
	if _reconnect_timer_running:
		_reconnect_delay_remaining -= delta
		if _reconnect_delay_remaining <= 0.0:
			_reconnect_timer_running = false
			_start_auto_reconnect()
	_tick_heartbeat(delta)
	if _config != null and _config.auto_poll:
		poll()


func _tick_heartbeat(delta: float) -> void:
	if _config == null:
		return
	if _connection_state == ConnectionState.CLOSING:
		# Polling surfaces nothing while the close handshake hangs, and every
		# recovery entry refuses with ERR_BUSY while CLOSING: without this
		# bound a silently dead link strands the client forever (issue #126).
		_heartbeat_elapsed += delta
		if _heartbeat_elapsed >= _config.pong_timeout_sec:
			_on_transport_failed("heartbeat close timeout")
		return
	if _connection_state != ConnectionState.CONNECTED:
		_reset_heartbeat()
		return
	if not is_authenticated():
		# These windows cannot send Protocol Ping, and a duplicate
		# `Authenticated` never restores a dead session (issue #24), so
		# silence past the pong deadline is a dead link (issues #121 and
		# #346). Accrued time flows into the ping cycle.
		_heartbeat_elapsed += delta
		if _heartbeat_elapsed >= _config.pong_timeout_sec:
			_on_transport_failed("heartbeat auth timeout")
		return
	# The deadlines above send nothing, so unlike the ping cycle they run
	# with the heartbeat off (issues #121, #126, #346); the beat is opt-in.
	if _config.heartbeat_interval_sec <= 0.0:
		_reset_heartbeat()
		return
	if _awaiting_pong:
		_pong_elapsed += delta
		if _pong_elapsed >= _config.pong_timeout_sec:
			_on_transport_failed("heartbeat pong timeout")
			return
		if _beat_in_flight:
			return
	# A refused beat falls through and retries after a full interval (a
	# per-frame retry would spam protocol_error on a congested link) while
	# the pong deadline it armed keeps running (issue #128).
	_heartbeat_elapsed += delta
	if _heartbeat_elapsed < _config.heartbeat_interval_sec:
		return
	_heartbeat_elapsed = 0.0
	if not _awaiting_pong:
		_awaiting_pong = true
		_pong_elapsed = 0.0
	_beat_in_flight = ping() == OK


func _reset_heartbeat() -> void:
	_heartbeat_elapsed = 0.0
	_awaiting_pong = false
	_pong_elapsed = 0.0
	_beat_in_flight = false


func _exit_tree() -> void:
	close()


class JoinRoomParams:
	extends RefCounted
	## Parameters for [method SignalFishClient.join_room]. Optional fields use
	## their zero value to mean "omit from the wire".

	var game_name: String = ""
	var player_name: String = ""
	var room_code: String = ""
	var max_players: int = 0
	var supports_authority: Variant = null
	var relay_transport: Variant = null
	## Join password for password-protected rooms (upstream `JoinRoom.password`).
	## Empty = omit from the wire: a password presented to an open room is
	## refused upstream, and a non-empty value seals a room this join creates.
	var password: String = ""


## Returns a non-empty error message when connecting to [param url] would hit
## a browser mixed-content block. Static and pure so tests can drive it.
static func insecure_scheme_error(url: String, is_web_platform: bool, secure_page: bool) -> String:
	var lower_url := url.to_lower()
	if not (lower_url.begins_with("ws://") or lower_url.begins_with("wss://")):
		return "invalid WebSocket URL scheme; expected ws:// or wss://"
	if is_web_platform and secure_page and lower_url.begins_with("ws://"):
		return "ws:// is blocked from secure pages (mixed content); use wss://"
	return ""


func _open_transport(target: String) -> Error:
	var scheme_error := insecure_scheme_error(target, _is_web_platform(), _is_secure_page())
	if not scheme_error.is_empty():
		# A refused dial never starts, so any pending reconnect handshake
		# credentials are dropped here instead of lingering in memory until
		# the next dial overwrites them.
		_clear_reconnect_credentials()
		_emit_protocol_error(scheme_error)
		return ERR_INVALID_PARAMETER
	_last_dial_url = target
	_user_close_requested = false
	_reconnect_handshake_sent = false
	_authenticated_seen = false
	_reconnected_seen = false
	_protocol_info_seen = false
	_reconnect_dial = not _reconnect_auth_token.is_empty()
	_effective_game_data_format = SFTypesScript.GameDataEncoding.UNKNOWN
	_negotiated_protocol_version = 0
	# A fresh dial supersedes any armed retry timer. The retry budget is NOT
	# reset here: it resets only when a session actually re-establishes (a
	# RoomJoined/Reconnected baseline), so exhaustion can terminate.
	_reconnect_timer_running = false
	_reset_session()
	_connection_state = ConnectionState.CONNECTING
	if transport == null:
		transport = _make_transport()
	_wire_transport_signals()
	var error: Error = transport.connect_to_url(target)
	if error != OK:
		return error
	return OK


func _make_transport() -> SFTransportScript:
	return SFWebSocketTransportScript.new()


func _wire_transport_signals() -> void:
	transport.opened.connect(_on_transport_opened)
	transport.packet_received.connect(_on_transport_packet)
	transport.closed.connect(_on_transport_closed)
	transport.failed.connect(_on_transport_failed)
	if transport.get("max_packets_per_poll") != null:
		transport.set("max_packets_per_poll", _config.max_inbound_packets_per_poll)


func _on_transport_opened() -> void:
	# A `connected` handler may close the client synchronously; never resurrect
	# a session that already moved past CONNECTING.
	if (
		_connection_state
		in [ConnectionState.CLOSING, ConnectionState.CLOSED, ConnectionState.FAILED]
	):
		return
	_connection_state = ConnectionState.CONNECTED
	_session_state = SessionState.AUTHENTICATING
	# The heartbeat clock belongs to this link alone: a synchronous redial
	# (fake transports, failed dials) can skip the idle ticks that would
	# otherwise reset a pending pong deadline from the previous link.
	_reset_heartbeat()
	connected.emit()
	if _connection_state != ConnectionState.CONNECTED:
		return
	var error: Error = _send_authenticate()
	if error != OK and _connection_state == ConnectionState.CONNECTED:
		# A refused authenticate (e.g. the backpressure cap) leaves the dial
		# with nothing in flight (issue #73): resolve it like a transport
		# failure instead of stalling. A consumer handler that closed inside
		# the error signal left CLOSING, and its cascade owns the teardown.
		_on_transport_failed("authenticate send failed")


func _send_reconnect() -> Error:
	var envelope := SFMessagesScript.reconnect(
		_reconnect_player_id, _reconnect_room_id, _reconnect_auth_token
	)
	return _send_envelope(envelope, "reconnect")


func _fail_reconnect_handshake() -> void:
	# The directed handshake could not go out on the fresh socket: without it
	# the session would hang authenticated-but-roomless with nothing in
	# flight. Resolve the attempt negatively: reconnection_failed always
	# fires. When the link is still up (e.g. the client-side backpressure cap
	# refused the send), the attempt is torn down exactly like a close frame
	# so consumers observe the terminal disconnect; when the send error
	# already killed the link, the transport-failure cascade has surfaced
	# connection_failed instead and auto-reconnect keeps the episode going.
	_clear_reconnect_credentials()
	reconnection_failed.emit("reconnect handshake send failed", SFErrorCodesScript.Code.NONE)
	_terminate_reconnection_attempt()


func _send_authenticate() -> Error:
	# The credential rides this dial; keep it on the redaction list and at
	# the newest pin so bounded eviction cannot age it out (issue #335).
	_remember_secret(_config.credential, true)
	_touch_pinned_secret(_config.credential)
	var protocol_version: Variant = null
	if _config.protocol_version > 0:
		protocol_version = _config.protocol_version
	var envelope := SFMessagesScript.authenticate(
		_config.app_id,
		_optional_string(_config.sdk_version),
		_optional_string(_config.platform),
		_optional_string(_config.game_data_format),
		protocol_version,
		_string_list_or_null(_config.supported_transports),
		_string_list_or_null(_config.supported_topologies),
		_string_list_or_null(_config.requested_capabilities),
		_optional_string(_config.credential)
	)
	return _send_envelope(envelope, "authenticate")


func _string_list_or_null(values: PackedStringArray) -> Variant:
	if values.is_empty():
		return null
	return Array(values)


func _on_transport_packet(payload: PackedByteArray, is_text: bool) -> void:
	if payload.size() > _config.max_inbound_frame_bytes:
		_emit_protocol_error(
			(
				"inbound frame of %d bytes exceeds cap %d; dropped"
				% [payload.size(), _config.max_inbound_frame_bytes]
			)
		)
		return
	if not is_text:
		_handle_binary_frame(payload)
		return
	var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		payload.get_string_from_utf8()
	)
	_handle_event(event)


func _handle_binary_frame(payload: PackedByteArray) -> void:
	if _connection_state != ConnectionState.CONNECTED:
		# Mirror the text path: while CLOSING the client only polls for the
		# close frame; late binary frames must not surface game data (or
		# re-arm anything) after a user close.
		return
	var negotiated := _negotiated_game_data_format()
	if negotiated in _BINARY_GAME_DATA_FORMATS:
		var frame: Dictionary = SFBinaryFramesScript.decode_envelope(payload)
		if not frame["ok"]:
			var frame_error: String = frame["error"]
			_emit_protocol_error(frame_error)
			return
		var frame_encoding: int = frame["encoding"]
		var from_player: String = frame["from_player"]
		var frame_payload: PackedByteArray = frame["payload"]
		if (
			_config.decode_msgpack_payloads
			and (frame_encoding == SFTypesScript.GameDataEncoding.MESSAGE_PACK)
		):
			var decoded: Dictionary = SFMsgpackScript.decode(frame_payload)
			if decoded["ok"]:
				game_data_received.emit(from_player, decoded["value"])
				return
			_emit_protocol_error(
				"message_pack payload decode failed (%s); surfacing raw bytes" % decoded["error"]
			)
		game_data_binary_received.emit(from_player, frame_encoding, frame_payload)
	else:
		_emit_protocol_error(
			(
				"binary frame on a %s-negotiated connection; dropped"
				% _game_data_format_label(negotiated)
			)
		)


func _negotiated_game_data_format() -> int:
	if _config == null:
		return SFTypesScript.GameDataEncoding.UNKNOWN
	return SFGameDataFormatScript.negotiated(_config.game_data_format, _effective_game_data_format)


func _reconcile_game_data_format(supported_formats: Array[int]) -> void:
	var reason := SFGameDataFormatScript.downgrade_reason(
		_config.game_data_format, supported_formats
	)
	if not reason.is_empty():
		_downgrade_game_data_format(reason)


func _downgrade_game_data_format(reason: String) -> void:
	if _effective_game_data_format == SFTypesScript.GameDataEncoding.JSON:
		return
	_effective_game_data_format = SFTypesScript.GameDataEncoding.JSON
	# WARN, not info (issue #146): a game that asked for binary data cannot
	# send any after the fallback, so it must clear the default log level.
	SFLogScript.warn("%s; falling back to json" % reason, _secrets)


func _game_data_format_label(encoding: int) -> String:
	return SFGameDataFormatScript.label(encoding)


func _on_transport_closed(code: int, reason: String) -> void:
	var user_close := _user_close_requested
	_user_close_requested = false
	_connection_state = ConnectionState.CLOSED
	_reset_session()
	_teardown_transport()
	# Issue #282: the close reason is relay-controlled wire text, so the
	# log line redacts secrets first, then renders it bounded and
	# single-line; the signal keeps the raw value.
	SFLogScript.info(
		(
			"transport closed (code %d): %s"
			% [code, SFDiagnosticsScript.render_key(SFLogScript.redact(reason, _secrets))]
		),
		_secrets
	)
	var kicked := code == CLOSE_CODE_KICKED
	if kicked:
		# Cancel before the emit so a consumer redialing from the handler
		# captures a fresh retained identity (issue #73 contract), like the
		# terminal-ReconnectionFailed path. A kick removes the reconnection
		# record server-side, so the old identity must not survive the emit.
		_cancel_auto_reconnect()
	disconnected.emit(code, reason)
	if not kicked and _auto_reconnect_enabled and not user_close:
		_schedule_auto_reconnect()


func _on_transport_failed(error: String) -> void:
	var user_close := _user_close_requested
	_user_close_requested = false
	_connection_state = ConnectionState.FAILED
	_reset_session()
	_teardown_transport()
	SFLogScript.info(
		"transport failed: %s" % SFDiagnosticsScript.render_failure(error, _secrets), _secrets
	)
	connection_failed.emit(error)
	if _auto_reconnect_enabled and not user_close:
		_schedule_auto_reconnect()


func _handle_event(event: SFTypesScript.DecodedEvent) -> void:
	if _connection_state != ConnectionState.CONNECTED:
		# While CLOSING the client keeps polling to read the close frame, so
		# late packets can still arrive. Applying them is moot and dangerous:
		# a late baseline would resurrect the room state (and re-capture the
		# reconnection identity) that the user's close just cleared.
		return
	match event.signal_name:
		&"protocol_error":
			var message: String = event.args[0]
			_emit_protocol_error(message)
		&"authenticated":
			# Once-per-dial: a duplicate `Authenticated` on any dial is
			# hostile-server input (issue #24) and must stay fully silent —
			# no second `authenticated` emission and no session-state reset.
			if not _authenticated_seen:
				_authenticated_seen = true
				if _reconnect_dial:
					# Keep authenticated silent on reconnect dials: a join-on-auth
					# handler could race the directed handshake (issue #82).
					if (
						not _reconnect_handshake_sent
						and not _reconnect_auth_token.is_empty()
						and _connection_state == ConnectionState.CONNECTED
					):
						_session_state = SessionState.AUTHENTICATED
						_reconnect_handshake_sent = true
						if _send_reconnect() != OK:
							_fail_reconnect_handshake()
				else:
					_session_state = SessionState.AUTHENTICATED
					authenticated.emit(event.args[0], event.args[1], event.args[2])
		&"protocol_info":
			if not _protocol_info_seen:
				_protocol_info_seen = true
				var info: SFTypesScript.ProtocolInfo = event.args[0]
				_negotiated_protocol_version = info.protocol_version
				_reconcile_game_data_format(info.game_data_formats)
				# The opaque wire shapes are v3-only (server issue #627): a
				# v2 negotiation has no sender attribution, so an opaque
				# request falls back to JSON like any unsupported preference.
				var reason := SFGameDataFormatScript.version_downgrade_reason(
					_negotiated_game_data_format(), info.protocol_version
				)
				if not reason.is_empty():
					_downgrade_game_data_format(reason)
				protocol_info.emit(info)
		&"authentication_error":
			_session_state = SessionState.UNAUTHENTICATED
			# The silence deadline measures from the error (issue #346).
			_reset_heartbeat()
			# A failed authentication kills any pending reconnect handshake;
			# room state dies with the session too (issue #342).
			_clear_reconnect_credentials()
			_clear_room_state()
			authentication_error.emit(event.args[0], event.args[1])
		&"room_joined":
			# A baseline before an authenticated session forges in-room state
			# (#100, #340): loud refusal (#108 posture). Gated on the live
			# session, not a dial latch: an AuthenticationError keeps it armed.
			if not is_authenticated():
				_emit_protocol_error("RoomJoined before an authenticated session on this dial")
				return
			# Every RoomJoined is an authoritative fresh baseline: consumers
			# (the WebRTC mesh) rebuild on re-emission, so unlike
			# Authenticated/Reconnected/ProtocolInfo there is no duplicate
			# latch here (issue #107, closed as intended behavior).
			var info: SFTypesScript.RoomJoinedInfo = event.args[0]
			_apply_room_info(info)
			# Rust clears plan state on every baseline (`set_room`): a stale
			# generation from the previous baseline must not keep the gate
			# armed across an off-contract re-baseline (issue #330).
			_session_plan_seen = false
			_session_plan_generation = ""
			_session_state = _session_state_for_lobby(_lobby_state)
			_auto_reconnect_attempts = 0
			room_joined.emit(info)
		&"room_join_failed":
			room_join_failed.emit(event.args[0], event.args[1])
		&"room_left":
			# Room-scoped (issue #106, #100 precedent): a `RoomLeft` for a
			# session that holds no player room baseline is off-contract and
			# must stay informational — wiping state or the retained
			# reconnection identity here would silently disable auto-rejoin.
			if _session_state in _PLAYER_ROOM_STATES:
				_clear_room_state()
				# Leaving the room ends its rejoin identity; a later drop must
				# not silently rejoin a room the consumer left.
				_capture_reconnect_context("", "", "")
				_session_state = SessionState.AUTHENTICATED
			room_left.emit()
		&"player_joined":
			var player: SFTypesScript.PlayerInfo = event.args[0]
			_upsert_player(player)
			player_joined.emit(player)
		&"player_left":
			var player_id: String = event.args[0]
			_remove_player(player_id)
			player_left.emit(player_id)
		&"player_reconnected":
			player_reconnected.emit(event.args[0])
		&"game_data_received":
			game_data_received.emit(event.args[0], event.args[1])
		&"game_data_binary_received":
			game_data_binary_received.emit(event.args[0], event.args[1], event.args[2])
		&"authority_changed":
			var authority_player: String = event.args[0]
			_apply_authority_flags(authority_player)
			authority_changed.emit(authority_player, event.args[1])
		&"authority_response":
			authority_response.emit(event.args[0], event.args[1], event.args[2])
		&"lobby_state_changed":
			# A lobby update is room-scoped (issue #100): without a room
			# baseline an off-contract frame must not touch cached state —
			# an in-room session state with no baseline would defeat the
			# pre-auth send guard. Spectators receive lobby updates too; only
			# players map lobby state onto in-room session states.
			if not _room_id.is_empty():
				_lobby_state = event.args[0]
				if _session_state != SessionState.SPECTATING:
					_session_state = _session_state_for_lobby(_lobby_state)
			lobby_state_changed.emit(event.args[0], event.args[1], event.args[2])
		&"game_starting":
			game_starting.emit(event.args[0])
		&"pong":
			_awaiting_pong = false
			_pong_elapsed = 0.0
			_beat_in_flight = false
			pong.emit()
		&"signal_received":
			signal_received.emit(event.args[0], event.args[1], event.args[2])
		&"new_peer":
			new_peer.emit(event.args[0], event.args[1])
		&"session_plan":
			# A plan is room-scoped (issue #120): like the mesh, a plan landing
			# before any room baseline is off-contract server input and must
			# not arm the send gate.
			if not _room_id.is_empty():
				var plan: SFSessionTypesScript.SessionPlanInfo = event.args[0]
				_session_plan_seen = true
				_session_plan_generation = plan.generation
			session_plan.emit(event.args[0])
		&"peer_transport_status":
			peer_transport_status.emit(event.args[0], event.args[1], event.args[2])
		&"going_away":
			going_away.emit(event.args[0], event.args[1])
		&"delivery_report":
			delivery_report.emit(event.args[0])
		&"room_operation_result":
			room_operation_result.emit(event.args[0])
		&"reconnected":
			# Once-per-dial: a duplicate `Reconnected` on any dial is hostile-
			# server input (issue #71, #24 precedent) and must stay fully
			# silent — consumers replay `missed_events`, so a second emission
			# would double-apply game events. Upstream only sends `Reconnected`
			# for a directed handshake, so pre-handshake (issue #82) or
			# normal-auth events are equally hostile.
			if _reconnected_seen:
				return
			if not _reconnect_handshake_sent or not is_authenticated():
				# No handshake on this dial, or the session already died
				# (issue #340): stays loud, not silently dropped (issue #108).
				_emit_protocol_error(
					"Reconnected without an authenticated reconnect handshake on this dial"
				)
				return
			_reconnected_seen = true
			var info: SFTypesScript.RoomJoinedInfo = event.args[0]
			_apply_room_info(info)
			# The pre-drop plan identity is dead on a re-dial, and replayed
			# plans surface through [signal reconnected] only (never the
			# session_plan dispatch), so sends stay gated until the next live
			# plan — the same posture as the mesh teardown.
			_session_plan_seen = false
			_session_plan_generation = ""
			_session_state = _session_state_for_lobby(_lobby_state)
			_clear_reconnect_credentials()
			_auto_reconnect_attempts = 0
			reconnected.emit(info, event.args[1])
		&"reconnection_failed":
			_clear_reconnect_credentials()
			if (
				event.args[1]
				in [
					SFErrorCodesScript.Code.RECONNECTION_TOKEN_INVALID,
					SFErrorCodesScript.Code.RECONNECTION_EXPIRED,
				]
			):
				_cancel_auto_reconnect()
			reconnection_failed.emit(event.args[0], event.args[1])
			_terminate_reconnection_attempt()
		&"spectator_joined":
			# Mirrors the room_joined refusal (issue #340).
			if not is_authenticated():
				_emit_protocol_error("SpectatorJoined before an authenticated session on this dial")
				return
			# Mirror of `room_joined`: no duplicate latch; every
			# SpectatorJoined is an authoritative baseline (issue #107).
			var info: SFTypesScript.SpectatorJoinedInfo = event.args[0]
			_apply_spectator_info(info)
			_session_plan_seen = false
			_session_plan_generation = ""
			_session_state = SessionState.SPECTATING
			spectator_joined.emit(info)
		&"spectator_join_failed":
			spectator_join_failed.emit(event.args[0], event.args[1])
		&"spectator_left":
			# Spectator-flow-scoped (issue #106): a `SpectatorLeft` for a
			# session that is not spectating is off-contract and must stay
			# informational — mirrors the `room_left` guard.
			if _session_state == SessionState.SPECTATING:
				_clear_room_state()
				# Mirrors room_left: a voluntary exit ends any retained identity.
				_capture_reconnect_context("", "", "")
				_session_state = SessionState.AUTHENTICATED
			spectator_left.emit(event.args[0], event.args[1], event.args[2], event.args[3])
		&"new_spectator_joined":
			var spectator: SFTypesScript.SpectatorInfo = event.args[0]
			_upsert_spectator(spectator)
			new_spectator_joined.emit(spectator, event.args[1], event.args[2])
		&"spectator_disconnected":
			var spectator_id: String = event.args[0]
			_remove_spectator(spectator_id)
			spectator_disconnected.emit(spectator_id, event.args[1], event.args[2])
		&"server_error":
			if event.args[1] == SFErrorCodesScript.Code.UNSUPPORTED_GAME_DATA_FORMAT:
				_downgrade_game_data_format("server rejected the requested game_data_format")
			server_error.emit(event.args[0], event.args[1])
		_:
			_emit_protocol_error("client has no handler for decoded event %s" % event.type_name)


func _guard_session_send(action: String) -> Error:
	if _session_state in [SessionState.UNAUTHENTICATED, SessionState.AUTHENTICATING]:
		_emit_protocol_error("%s requires an authenticated session" % action)
		return ERR_UNAUTHORIZED
	if transport == null or _connection_state != ConnectionState.CONNECTED:
		_emit_protocol_error("%s requires a connected transport" % action)
		return ERR_UNCONFIGURED
	return OK


func _send_envelope(envelope: Dictionary, action: String) -> Error:
	if not SFMessagesScript.is_valid_message(envelope):
		_emit_protocol_error("%s: %s" % [action, SFMessagesScript.validation_error(envelope)])
		return ERR_INVALID_DATA
	if transport == null:
		# A synchronous terminal event (close/failure) can tear the session
		# down mid-dispatch, e.g. from a `connected` signal handler.
		_emit_protocol_error("%s requires a connected transport" % action)
		return ERR_UNCONFIGURED
	var buffered: int = transport.get_buffered_amount()
	if buffered > _config.max_buffered_bytes:
		_emit_protocol_error(
			(
				"transport backpressure: %d buffered bytes exceeds cap %d; %s dropped"
				% [buffered, _config.max_buffered_bytes, action]
			)
		)
		return ERR_BUSY
	# The encode boundary is the last-resort JSON-shape net: a payload that
	# passed builder validation but cannot be serialized losslessly (an
	# engine-only Variant deep inside ConnectionInfo.custom.data, a
	# non-finite float) must surface here, never as an empty text frame.
	var wire := SFMessagesScript.encode(envelope)
	if wire.is_empty():
		_emit_protocol_error("%s: payload is not losslessly JSON-representable" % action)
		return ERR_INVALID_DATA
	var frame_bytes := wire.to_utf8_buffer().size()
	if frame_bytes > _config.max_outbound_frame_bytes:
		_emit_protocol_error(
			(
				"%s: frame %d bytes exceeds outbound cap %d"
				% [action, frame_bytes, _config.max_outbound_frame_bytes]
			)
		)
		return ERR_INVALID_DATA
	var error: Error = transport.send_text(wire)
	if error != OK:
		_emit_protocol_error("%s send failed: %s" % [action, error_string(error)])
	return error


func _apply_room_info(info: SFTypesScript.RoomJoinedInfo) -> void:
	_room_id = info.room_id
	_room_code = info.room_code
	_player_id = info.player_id
	_lobby_state = info.lobby_state
	# Duplicate the rosters so later presence updates never mutate the payload
	# objects already handed to consumers.
	_players = info.current_players.duplicate()
	_bound_roster(_players, "current_players")
	_spectators = info.current_spectators.duplicate()
	_bound_roster(_spectators, "current_spectators")
	# Retain the freshest reconnection identity for opt-in auto-reconnect.
	# Every authoritative baseline replaces it; a baseline without a token
	# clears it (upstream client_core.rs baseline handling).
	_capture_reconnect_context(info.player_id, info.room_id, info.reconnection_token)


func _apply_spectator_info(info: SFTypesScript.SpectatorJoinedInfo) -> void:
	_room_id = info.room_id
	_room_code = info.room_code
	_lobby_state = info.lobby_state
	_players = info.current_players.duplicate()
	_bound_roster(_players, "current_players")
	_spectators = info.current_spectators.duplicate()
	_bound_roster(_spectators, "current_spectators")
	# The protocol has no spectator reconnect: drop any retained identity.
	_capture_reconnect_context("", "", "")


func _clear_room_state() -> void:
	_room_id = ""
	_room_code = ""
	_player_id = ""
	_lobby_state = SFTypesScript.LobbyState.UNKNOWN
	_players = []
	_spectators = []
	# Plans are room-scoped (issue #120): the plan gate dies with the room.
	_session_plan_seen = false
	_session_plan_generation = ""


func _bound_roster(roster: Array, label: String) -> void:
	# Joins and leaves stop at the first id match, so a repeated baseline id
	# would strand stale entries (and pinned authority) forever. Keep the
	# first occurrence of each id and refuse the rest loudly (#92, #273
	# precedent).
	var seen := {}
	var write := 0
	for index: int in roster.size():
		var id: String = roster[index].id
		if seen.has(id):
			continue
		seen[id] = true
		if write != index:
			roster[write] = roster[index]
		write += 1
	if write < roster.size():
		_emit_protocol_error(
			(
				"%s contains duplicate ids; kept the first occurrence, dropped %d"
				% [label, roster.size() - write]
			)
		)
		roster.resize(write)
	if roster.size() <= SFTypeUtils.MAX_TRACKED_PEERS:
		return
	var dropped: int = roster.size() - SFTypeUtils.MAX_TRACKED_PEERS
	roster.resize(SFTypeUtils.MAX_TRACKED_PEERS)
	_emit_protocol_error(
		"%s exceeds %d entries; dropped %d" % [label, SFTypeUtils.MAX_TRACKED_PEERS, dropped]
	)


func _upsert_player(player: SFTypesScript.PlayerInfo) -> void:
	for index: int in _players.size():
		if _players[index].id == player.id:
			_players[index] = player
			return
	if _players.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
		_emit_protocol_error(
			"player roster is at cap %d; PlayerJoined not tracked" % SFTypeUtils.MAX_TRACKED_PEERS
		)
		return
	_players.append(player)


func _remove_player(player_id: String) -> void:
	for index: int in _players.size():
		if _players[index].id == player_id:
			_players.remove_at(index)
			return


func _apply_authority_flags(authority_player: String) -> void:
	for index: int in _players.size():
		var player: SFTypesScript.PlayerInfo = _players[index]
		var flag: bool = player.id == authority_player
		if player.is_authority == flag:
			continue
		var raw: Dictionary = player.raw.duplicate(true)
		raw["is_authority"] = flag
		_players[index] = SFTypesScript.PlayerInfo.new(raw)


func _upsert_spectator(spectator: SFTypesScript.SpectatorInfo) -> void:
	for index: int in _spectators.size():
		if _spectators[index].id == spectator.id:
			_spectators[index] = spectator
			return
	if _spectators.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
		_emit_protocol_error(
			(
				"spectator roster is at cap %d; NewSpectatorJoined not tracked"
				% SFTypeUtils.MAX_TRACKED_PEERS
			)
		)
		return
	_spectators.append(spectator)


func _remove_spectator(spectator_id: String) -> void:
	for index: int in _spectators.size():
		if _spectators[index].id == spectator_id:
			_spectators.remove_at(index)
			return


func _session_state_for_lobby(lobby_state: int) -> SessionState:
	match lobby_state:
		SFTypesScript.LobbyState.LOBBY:
			return SessionState.IN_ROOM_LOBBY
		SFTypesScript.LobbyState.FINALIZED:
			return SessionState.IN_ROOM_FINALIZED
		_:
			return SessionState.IN_ROOM_WAITING


func _reset_session() -> void:
	_session_state = SessionState.UNAUTHENTICATED
	_clear_room_state()


func _capture_reconnect_context(player_id: String, room_id: String, auth_token: String) -> void:
	if auth_token.is_empty():
		_context_player_id = ""
		_context_room_id = ""
		_context_auth_token = ""
		return
	_context_player_id = player_id
	_context_room_id = room_id
	_context_auth_token = auth_token
	_remember_secret(auth_token)


func _clear_reconnect_credentials() -> void:
	_reconnect_player_id = ""
	_reconnect_room_id = ""
	_reconnect_auth_token = ""


func _schedule_auto_reconnect() -> void:
	if _reconnect_timer_running:
		# Already armed (e.g. a consumer's handler redial failed and
		# scheduled first): one termination cascade arms exactly one retry.
		return
	if _user_close_requested:
		# A synchronous consumer close wins over retry scheduling (issue #73).
		return
	if (
		_connection_state
		in [
			ConnectionState.CONNECTING,
			ConnectionState.CONNECTED,
			ConnectionState.CLOSING,
		]
	):
		# A handler may have started a new dial during the close cascade.
		return
	if _context_auth_token.is_empty():
		return
	if _auto_reconnect_attempts >= _config.reconnect_max_attempts:
		connection_failed.emit(
			"auto-reconnect exhausted after %d attempt(s)" % _auto_reconnect_attempts
		)
		if _connection_state == ConnectionState.CONNECTING:
			# Emission is synchronous; do not erase a handler's fresh identity.
			return
		_context_player_id = ""
		_context_room_id = ""
		_context_auth_token = ""
		return
	_auto_reconnect_attempts += 1
	var raw_delay: float = (
		RECONNECT_BASE_DELAY_SEC * pow(RECONNECT_BACKOFF_FACTOR, _auto_reconnect_attempts - 1)
	)
	_reconnect_delay_remaining = (
		minf(raw_delay, RECONNECT_MAX_DELAY_SEC)
		* (1.0 + _reconnect_rng.randf() * RECONNECT_JITTER_FRACTION)
	)
	_reconnect_timer_running = true
	SFLogScript.info(
		(
			"auto-reconnect attempt %d/%d in %.2fs"
			% [_auto_reconnect_attempts, _config.reconnect_max_attempts, _reconnect_delay_remaining]
		),
		_secrets
	)


func _start_auto_reconnect() -> void:
	if _context_auth_token.is_empty():
		return
	if (
		_connection_state
		in [ConnectionState.CONNECTING, ConnectionState.CONNECTED, ConnectionState.CLOSING]
	):
		return
	var error: Error = reconnect(_context_player_id, _context_room_id, _context_auth_token)
	if error == OK:
		return
	# A rejected dial still consumes the attempt; schedule the next one.
	# _schedule_auto_reconnect deduplicates a transport-failure cascade.
	_schedule_auto_reconnect()


func _cancel_auto_reconnect() -> void:
	_reconnect_timer_running = false
	_reconnect_delay_remaining = 0.0
	_auto_reconnect_attempts = 0
	_context_player_id = ""
	_context_room_id = ""
	_context_auth_token = ""


func _terminate_reconnection_attempt() -> void:
	if _connection_state != ConnectionState.CONNECTED:
		return
	_connection_state = ConnectionState.CLOSED
	_reset_session()
	_teardown_transport()
	disconnected.emit(-1, "reconnection failed")
	if _auto_reconnect_enabled:
		_schedule_auto_reconnect()


func _remember_secret(secret: String, pinned := false) -> void:
	if secret.is_empty() or _secrets.has(secret):
		return
	if pinned:
		_secrets.insert(_pinned_secrets, secret)
		_pinned_secrets += 1
		if _pinned_secrets > MAX_REMEMBERED_SECRETS:
			# Distinct pins (rotated room passwords) are bounded like the
			# rotating half; pins in active use re-pin on every use, so
			# oldest-first eviction only ages out dead credentials
			# (issue #335).
			_secrets.remove_at(0)
			_pinned_secrets -= 1
		return
	_secrets.append(secret)
	if _secrets.size() > _pinned_secrets + MAX_REMEMBERED_SECRETS:
		_secrets.remove_at(_pinned_secrets)


## Moves an already-tracked pin to the newest pin slot: eviction is
## oldest-first, so a secret on its way onto the wire must never sit at the
## eviction end (issue #335).
func _touch_pinned_secret(secret: String) -> void:
	if secret.is_empty():
		return
	var index := _secrets.find(secret)
	if index == -1 or index >= _pinned_secrets:
		return
	_secrets.remove_at(index)
	_pinned_secrets -= 1
	_secrets.insert(_pinned_secrets, secret)
	_pinned_secrets += 1


func _teardown_transport() -> void:
	if transport != null:
		transport.opened.disconnect(_on_transport_opened)
		transport.packet_received.disconnect(_on_transport_packet)
		transport.closed.disconnect(_on_transport_closed)
		transport.failed.disconnect(_on_transport_failed)
		# Signals are already unwired, so this close cannot re-enter a
		# cascade: a torn-down attempt must never leak a live socket (the
		# server would otherwise pin the session until its own timeout).
		# Peer reclamation may prevent the close handshake from flushing (issue #24).
		transport.close(1000, "client teardown")
	transport = null


func _emit_protocol_error(message: String) -> void:
	SFLogScript.debug(message, _secrets)
	protocol_error.emit(message)


func _optional_string(value: String) -> Variant:
	if value.is_empty():
		return null
	return value


func _is_web_platform() -> bool:
	return OS.has_feature("web")


func _is_secure_page() -> bool:
	if not OS.has_feature("web"):
		return false
	var window: Variant = JavaScriptBridge.get_interface("window")
	if window == null:
		return false
	var is_secure_context: bool = window.isSecureContext
	return is_secure_context
