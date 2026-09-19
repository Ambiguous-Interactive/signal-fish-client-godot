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
signal authenticated(app_name: String, organization: String, rate_limits)
signal protocol_info(info)
signal authentication_error(error: String, error_code: int)
signal room_joined(info)
signal room_join_failed(reason: String, error_code: int)
signal room_left
signal player_joined(player)
signal player_left(player_id: String)
signal player_reconnected(player_id: String)
signal game_data_received(from_player: String, data)
signal game_data_binary_received(from_player: String, encoding: int, payload: PackedByteArray)
signal authority_changed(authority_player: String, you_are_authority: bool)
signal authority_response(granted: bool, reason: String, error_code: int)
signal lobby_state_changed(lobby_state: int, ready_players: PackedStringArray, all_ready: bool)
signal game_starting(peer_connections: Array)
signal pong
## [param missed_events] carries decoded [code]DecodedEvent[/code]s; malformed
## entries decode to [code]signal_name == &"protocol_error"[/code] sentinels —
## check them when replaying (see SFEvents).
signal reconnected(info, missed_events: Array)
signal reconnection_failed(reason: String, error_code: int)
signal spectator_joined(info)
signal spectator_join_failed(reason: String, error_code: int)
signal spectator_left(room_id: String, room_code: String, reason: int, current_spectators: Array)
signal new_spectator_joined(spectator, current_spectators: Array, reason: int)
signal spectator_disconnected(spectator_id: String, reason: int, current_spectators: Array)
signal server_error(message: String, error_code: int)

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
const SFTransportScript = preload("res://addons/signal_fish/transport/sf_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
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

## Active transport adapter. Tests may inject an [code]SFFakeTransport[/code]
## before [method connect_to_server]; production code leaves this null and the
## client builds a [code]SFWebSocketTransport[/code].
var transport = null

var _config: SignalFishConfigScript = null
var _connection_state: ConnectionState = ConnectionState.DISCONNECTED
var _session_state: SessionState = SessionState.UNAUTHENTICATED
var _secrets: PackedStringArray = PackedStringArray()
var _player_id := ""
var _room_id := ""
var _room_code := ""
var _lobby_state: int = SFTypesScript.LobbyState.UNKNOWN
var _players: Array = []
var _spectators: Array = []
# Credentials for the in-flight reconnect dial (sent on transport open instead
# of Authenticate). Empty auth_token = the next open authenticates normally.
var _reconnect_player_id := ""
var _reconnect_room_id := ""
var _reconnect_auth_token := ""
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
	if not config.credential.is_empty():
		_secrets.append(config.credential)
	# Retained reconnect identities may outlive configure() (it is allowed
	# whenever no connection is active); keep them on the redaction list.
	_remember_secret(_reconnect_auth_token)
	_remember_secret(_context_auth_token)
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
	_reconnect_player_id = ""
	_reconnect_room_id = ""
	_reconnect_auth_token = ""
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
## join-on-auth handler cannot race the handshake). Backoff-driven retries
## need the client in the scene tree so [code]_process[/code] runs.
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
	var target := _last_dial_url
	if target.is_empty():
		target = _config.endpoint_url
	if target.is_empty():
		_emit_protocol_error(
			"reconnect requires a configured endpoint_url or a previous connect_to_server url"
		)
		return ERR_INVALID_PARAMETER
	_remember_secret(auth_token)
	_reconnect_player_id = player_id
	_reconnect_room_id = room_id
	_reconnect_auth_token = auth_token
	return _open_transport(target)


## Enables opt-in automatic reconnection after an abnormal termination: a
## non-user-initiated close, or a transport failure (including failed dials,
## even ones you initiate). Uses the last server-issued reconnection token; a
## clean [method close] or a terminal reconnection error stops it. When the
## retry budget is exhausted, a final [signal connection_failed]
## ("auto-reconnect exhausted") is emitted, the retained token is dropped,
## and retrying stops until a fresh baseline re-establishes a session. Off by
## default.
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
			# Closing while connecting is a failed open: the transport surfaces
			# `failed`, which transitions the client to FAILED.
			_connection_state = ConnectionState.CLOSING
			transport.close(code, reason)
			return OK
		ConnectionState.CONNECTED:
			_connection_state = ConnectionState.CLOSING
			transport.close(code, reason)
			return OK
		_:
			return OK


func is_connected_to_server() -> bool:
	# Named to avoid shadowing Object.is_connected(signal, callable).
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


func get_players() -> Array:
	return _players


func get_spectators() -> Array:
	return _spectators


func get_buffered_amount() -> int:
	if transport == null:
		return 0
	return transport.get_buffered_amount()


func join_room(params: JoinRoomParams) -> Error:
	var guard := _guard_session_send("join_room")
	if guard != OK:
		return guard
	var max_players: Variant = null
	if params.max_players > 0:
		max_players = params.max_players
	var envelope := SFMessagesScript.join_room(
		params.game_name,
		params.player_name,
		_optional_string(params.room_code),
		max_players,
		params.supports_authority,
		params.relay_transport
	)
	return _send_envelope(envelope, "join_room")


func leave_room() -> Error:
	var guard := _guard_session_send("leave_room")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.leave_room(), "leave_room")


func send_game_data(data) -> Error:
	var guard := _guard_session_send("send_game_data")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.game_data(data), "send_game_data")


func set_ready() -> Error:
	var guard := _guard_session_send("set_ready")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.player_ready(), "set_ready")


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


func join_as_spectator(game_name: String, room_code: String, spectator_name: String) -> Error:
	var guard := _guard_session_send("join_as_spectator")
	if guard != OK:
		return guard
	return _send_envelope(
		SFMessagesScript.join_as_spectator(game_name, room_code, spectator_name),
		"join_as_spectator"
	)


func leave_spectator() -> Error:
	var guard := _guard_session_send("leave_spectator")
	if guard != OK:
		return guard
	return _send_envelope(SFMessagesScript.leave_spectator(), "leave_spectator")


func _process(_delta: float) -> void:
	if _reconnect_timer_running:
		_reconnect_delay_remaining -= _delta
		if _reconnect_delay_remaining <= 0.0:
			_reconnect_timer_running = false
			_start_auto_reconnect()
	if _config != null and _config.auto_poll:
		poll()


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
		_emit_protocol_error(scheme_error)
		return ERR_INVALID_PARAMETER
	# Remember the dial target so reconnect/auto-reconnect rejoin the same
	# endpoint even when the session started with an explicit override.
	_last_dial_url = target
	_user_close_requested = false
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
		# The transport already emitted `failed` for a synchronous refusal.
		return error
	return OK


func _make_transport():
	return SFWebSocketTransportScript.new()


func _wire_transport_signals() -> void:
	transport.opened.connect(_on_transport_opened)
	transport.packet_received.connect(_on_transport_packet)
	transport.closed.connect(_on_transport_closed)
	transport.failed.connect(_on_transport_failed)
	if transport.get("max_packets_per_poll") != null:
		transport.max_packets_per_poll = _config.max_inbound_packets_per_poll


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
	connected.emit()
	if _connection_state != ConnectionState.CONNECTED:
		return
	# Every dial authenticates first (upstream parity); a reconnect dial sends
	# its directed `Reconnect` once `Authenticated` arrives.
	_send_authenticate()


func _send_reconnect() -> Error:
	var envelope := SFMessagesScript.reconnect(
		_reconnect_player_id, _reconnect_room_id, _reconnect_auth_token
	)
	return _send_envelope(envelope, "reconnect")


func _send_authenticate() -> Error:
	var envelope := SFMessagesScript.authenticate(
		_config.app_id,
		_optional_string(_config.sdk_version),
		_optional_string(_config.platform),
		_optional_string(_config.game_data_format)
	)
	return _send_envelope(envelope, "authenticate")


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
		# Binary game-data frames are only meaningful after format negotiation
		# (MessagePack support, PLAN P2); without it there is nothing to decode.
		_emit_protocol_error("unexpected binary frame; dropped")
		return
	_handle_event(SFEventsScript.decode_text(payload.get_string_from_utf8()))


func _on_transport_closed(code: int, reason: String) -> void:
	var user_close := _user_close_requested
	_user_close_requested = false
	_connection_state = ConnectionState.CLOSED
	_reset_session()
	_teardown_transport()
	SFLogScript.info("transport closed (code %d): %s" % [code, reason], _secrets)
	disconnected.emit(code, reason)
	if _auto_reconnect_enabled and not user_close:
		_schedule_auto_reconnect()


func _on_transport_failed(error: String) -> void:
	var user_close := _user_close_requested
	_user_close_requested = false
	_connection_state = ConnectionState.FAILED
	_reset_session()
	_teardown_transport()
	SFLogScript.info("transport failed: %s" % error, _secrets)
	connection_failed.emit(error)
	# A dead dial or dropped link is an abnormal termination, same as a
	# server-initiated close: budget-limited retries keep auto-reconnect
	# useful when the endpoint is briefly unreachable.
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
			_emit_protocol_error(event.args[0])
		&"authenticated":
			_session_state = SessionState.AUTHENTICATED
			if _reconnect_auth_token.is_empty():
				authenticated.emit(event.args[0], event.args[1], event.args[2])
			elif _connection_state == ConnectionState.CONNECTED:
				# Reconnect dial: the fresh connection is authenticated, so
				# the directed handshake goes out now (upstream
				# `take_auto_reconnect_operation` fires only post-auth).
				# `authenticated` stays consumer-silent on dials: emitting it
				# would invite a join-on-auth handler to race the handshake
				# with a fresh JoinRoom. Consumers observe `reconnected`
				# (or `reconnection_failed`) next.
				_send_reconnect()
		&"protocol_info":
			protocol_info.emit(event.args[0])
		&"authentication_error":
			_session_state = SessionState.UNAUTHENTICATED
			# A failed authentication also kills any pending reconnect
			# handshake; the server closes the link after auth failures, so
			# the normal close cascade takes over from here.
			_reconnect_player_id = ""
			_reconnect_room_id = ""
			_reconnect_auth_token = ""
			authentication_error.emit(event.args[0], event.args[1])
		&"room_joined":
			_apply_room_info(event.args[0])
			_session_state = _session_state_for_lobby(_lobby_state)
			# A fresh authoritative session restarts the retry budget.
			_auto_reconnect_attempts = 0
			room_joined.emit(event.args[0])
		&"room_join_failed":
			room_join_failed.emit(event.args[0], event.args[1])
		&"room_left":
			_clear_room_state()
			# Leaving the room ends its rejoin identity; a later drop must
			# not silently rejoin a room the consumer left.
			_capture_reconnect_context("", "", "")
			_session_state = SessionState.AUTHENTICATED
			room_left.emit()
		&"player_joined":
			_upsert_player(event.args[0])
			player_joined.emit(event.args[0])
		&"player_left":
			_remove_player(event.args[0])
			player_left.emit(event.args[0])
		&"player_reconnected":
			player_reconnected.emit(event.args[0])
		&"game_data_received":
			game_data_received.emit(event.args[0], event.args[1])
		&"game_data_binary_received":
			game_data_binary_received.emit(event.args[0], event.args[1], event.args[2])
		&"authority_changed":
			authority_changed.emit(event.args[0], event.args[1])
		&"authority_response":
			authority_response.emit(event.args[0], event.args[1], event.args[2])
		&"lobby_state_changed":
			_lobby_state = event.args[0]
			# Spectators receive lobby updates too; only players map lobby
			# state onto in-room session states.
			if _session_state != SessionState.SPECTATING:
				_session_state = _session_state_for_lobby(_lobby_state)
			lobby_state_changed.emit(event.args[0], event.args[1], event.args[2])
		&"game_starting":
			# One-shot instruction event; session state stays FINALIZED.
			game_starting.emit(event.args[0])
		&"pong":
			pong.emit()
		&"reconnected":
			_apply_room_info(event.args[0])
			_session_state = _session_state_for_lobby(_lobby_state)
			# The reconnection handshake completed: drop the dial credentials
			# and reset the auto-reconnect budget.
			_reconnect_player_id = ""
			_reconnect_room_id = ""
			_reconnect_auth_token = ""
			_auto_reconnect_attempts = 0
			reconnected.emit(event.args[0], event.args[1])
		&"reconnection_failed":
			# The handshake resolved negatively: consume the dial credentials.
			_reconnect_player_id = ""
			_reconnect_room_id = ""
			_reconnect_auth_token = ""
			if (
				event.args[1]
				in [
					SFErrorCodesScript.Code.RECONNECTION_TOKEN_INVALID,
					SFErrorCodesScript.Code.RECONNECTION_EXPIRED,
				]
			):
				# Terminal reconnection errors: retrying can never succeed.
				_cancel_auto_reconnect()
			reconnection_failed.emit(event.args[0], event.args[1])
			# The server rejected the rejoin; nothing is left to do on this
			# connection. Bring the link down so `disconnected` fires and
			# retryable auto-reconnects continue from a clean state.
			_terminate_reconnection_attempt()
		&"spectator_joined":
			_apply_spectator_info(event.args[0])
			_session_state = SessionState.SPECTATING
			spectator_joined.emit(event.args[0])
		&"spectator_join_failed":
			spectator_join_failed.emit(event.args[0], event.args[1])
		&"spectator_left":
			_clear_room_state()
			# Mirrors room_left: a voluntary exit ends any retained identity.
			_capture_reconnect_context("", "", "")
			_session_state = SessionState.AUTHENTICATED
			spectator_left.emit(event.args[0], event.args[1], event.args[2], event.args[3])
		&"new_spectator_joined":
			_upsert_spectator(event.args[0])
			new_spectator_joined.emit(event.args[0], event.args[1], event.args[2])
		&"spectator_disconnected":
			_remove_spectator(event.args[0])
			spectator_disconnected.emit(event.args[0], event.args[1], event.args[2])
		&"server_error":
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
	var error: Error = transport.send_text(SFMessagesScript.encode(envelope))
	if error != OK:
		# Transport failures also surface as `failed` -> connection_failed.
		_emit_protocol_error("%s send failed: %s" % [action, error_string(error)])
	return error


func _apply_room_info(info) -> void:
	_room_id = info.room_id
	_room_code = info.room_code
	_player_id = info.player_id
	_lobby_state = info.lobby_state
	# Duplicate the rosters so later presence updates never mutate the payload
	# objects already handed to consumers.
	_players = info.current_players.duplicate()
	_spectators = info.current_spectators.duplicate()
	# Retain the freshest reconnection identity for opt-in auto-reconnect.
	# Every authoritative baseline replaces it; a baseline without a token
	# clears it (upstream client_core.rs baseline handling).
	_capture_reconnect_context(info.player_id, info.room_id, info.reconnection_token)


func _apply_spectator_info(info) -> void:
	_room_id = info.room_id
	_room_code = info.room_code
	_lobby_state = info.lobby_state
	_players = info.current_players.duplicate()
	_spectators = info.current_spectators.duplicate()
	# The protocol has no spectator reconnect: drop any retained identity.
	_capture_reconnect_context("", "", "")


func _clear_room_state() -> void:
	_room_id = ""
	_room_code = ""
	_player_id = ""
	_lobby_state = SFTypesScript.LobbyState.UNKNOWN
	_players = []
	_spectators = []


func _upsert_player(player) -> void:
	_upsert_by_id(_players, player, player.id)


func _remove_player(player_id: String) -> void:
	_remove_by_id(_players, player_id)


func _upsert_spectator(spectator) -> void:
	_upsert_by_id(_spectators, spectator, spectator.id)


func _remove_spectator(spectator_id: String) -> void:
	_remove_by_id(_spectators, spectator_id)


func _upsert_by_id(roster: Array, entry, id: String) -> void:
	for index: int in roster.size():
		if roster[index].id == id:
			roster[index] = entry
			return
	roster.append(entry)


func _remove_by_id(roster: Array, id: String) -> void:
	for index: int in roster.size():
		if roster[index].id == id:
			roster.remove_at(index)
			return


func _session_state_for_lobby(lobby_state: int) -> SessionState:
	match lobby_state:
		SFTypesScript.LobbyState.LOBBY:
			return SessionState.IN_ROOM_LOBBY
		SFTypesScript.LobbyState.FINALIZED:
			return SessionState.IN_ROOM_FINALIZED
		_:
			# WAITING plus any UNKNOWN fallback: server-driven states only.
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


func _schedule_auto_reconnect() -> void:
	if _reconnect_timer_running:
		# Already armed (e.g. a consumer's handler redial failed and
		# scheduled first): one termination cascade arms exactly one retry.
		return
	if _user_close_requested:
		# A consumer closed from a disconnect/failure handler after the flag
		# was snapshotted: their clean close wins over arming a retry.
		_user_close_requested = false
		return
	if (
		_connection_state
		in [
			ConnectionState.CONNECTING,
			ConnectionState.CONNECTED,
			ConnectionState.CLOSING,
		]
	):
		# A consumer dialed or closed from a disconnect handler; never arm a
		# timer that would burn a budgeted attempt against a live dial.
		return
	if _context_auth_token.is_empty():
		# Nothing to reconnect with (never joined a room, spectator session,
		# or a terminal reconnection error already cleared the context).
		return
	if _auto_reconnect_attempts >= _config.reconnect_max_attempts:
		connection_failed.emit(
			"auto-reconnect exhausted after %d attempt(s)" % _auto_reconnect_attempts
		)
		# The episode is over: drop the retained identity so no later event
		# can re-enter scheduling (retries restart on a fresh baseline).
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
	if _connection_state in [ConnectionState.CONNECTING, ConnectionState.CONNECTED]:
		return
	var error: Error = reconnect(_context_player_id, _context_room_id, _context_auth_token)
	if error == OK:
		return
	# The dial never started (e.g. a refused URL): re-enter scheduling so the
	# consumed attempt still arms the next backoff window or ends the episode
	# with the exhaustion notice instead of stalling. A synchronously refused
	# dial already re-entered scheduling from `failed`; this early-returns
	# there, so exactly one attempt is armed per cascade.
	_schedule_auto_reconnect()


func _cancel_auto_reconnect() -> void:
	_reconnect_timer_running = false
	_reconnect_delay_remaining = 0.0
	_auto_reconnect_attempts = 0
	_context_player_id = ""
	_context_room_id = ""
	_context_auth_token = ""


## After a `ReconnectionFailed` the server rejected the rejoin: tear the
## connection down exactly like a close frame so consumers observe
## `disconnected`, and give retryable auto-reconnects a fresh scheduling
## point. Terminal codes cleared the context above, so their schedule is a
## no-op.
func _terminate_reconnection_attempt() -> void:
	if _connection_state != ConnectionState.CONNECTED:
		# A consumer handler already closed (CLOSING) or the link dropped.
		return
	_connection_state = ConnectionState.CLOSED
	_reset_session()
	_teardown_transport()
	disconnected.emit(-1, "reconnection failed")
	if _auto_reconnect_enabled:
		_schedule_auto_reconnect()


func _remember_secret(secret: String) -> void:
	if not secret.is_empty() and not _secrets.has(secret):
		_secrets.append(secret)


func _teardown_transport() -> void:
	if transport != null:
		transport.opened.disconnect(_on_transport_opened)
		transport.packet_received.disconnect(_on_transport_packet)
		transport.closed.disconnect(_on_transport_closed)
		transport.failed.disconnect(_on_transport_failed)
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
	return bool(window.isSecureContext)
