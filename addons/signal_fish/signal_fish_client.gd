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
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTransportScript = preload("res://addons/signal_fish/transport/sf_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")

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
	var scheme_error := insecure_scheme_error(target, _is_web_platform(), _is_secure_page())
	if not scheme_error.is_empty():
		_emit_protocol_error(scheme_error)
		return ERR_INVALID_PARAMETER

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


## Drives the transport. Called from [code]_process[/code] when
## [member SignalFishConfig.auto_poll] is on; call manually otherwise.
func poll() -> void:
	if transport == null:
		return
	transport.poll()


func close(code := 1000, reason := "") -> Error:
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
	_connection_state = ConnectionState.CONNECTED
	_session_state = SessionState.AUTHENTICATING
	connected.emit()
	_send_authenticate()


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
	_connection_state = ConnectionState.CLOSED
	_reset_session()
	_teardown_transport()
	SFLogScript.info("transport closed (code %d): %s" % [code, reason], _secrets)
	disconnected.emit(code, reason)


func _on_transport_failed(error: String) -> void:
	_connection_state = ConnectionState.FAILED
	_reset_session()
	_teardown_transport()
	SFLogScript.info("transport failed: %s" % error, _secrets)
	connection_failed.emit(error)


func _handle_event(event: SFTypesScript.DecodedEvent) -> void:
	match event.signal_name:
		&"protocol_error":
			_emit_protocol_error(event.args[0])
		&"authenticated":
			_session_state = SessionState.AUTHENTICATED
			authenticated.emit(event.args[0], event.args[1], event.args[2])
		&"protocol_info":
			protocol_info.emit(event.args[0])
		&"authentication_error":
			_session_state = SessionState.UNAUTHENTICATED
			authentication_error.emit(event.args[0], event.args[1])
		&"room_joined":
			_apply_room_info(event.args[0])
			_session_state = _session_state_for_lobby(_lobby_state)
			room_joined.emit(event.args[0])
		&"room_join_failed":
			room_join_failed.emit(event.args[0], event.args[1])
		&"room_left":
			_clear_room_state()
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
			reconnected.emit(event.args[0], event.args[1])
		&"reconnection_failed":
			reconnection_failed.emit(event.args[0], event.args[1])
		&"spectator_joined":
			_apply_spectator_info(event.args[0])
			_session_state = SessionState.SPECTATING
			spectator_joined.emit(event.args[0])
		&"spectator_join_failed":
			spectator_join_failed.emit(event.args[0], event.args[1])
		&"spectator_left":
			_clear_room_state()
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
	_players = info.current_players
	_spectators = info.current_spectators


func _apply_spectator_info(info) -> void:
	_room_id = info.room_id
	_room_code = info.room_code
	_lobby_state = info.lobby_state
	_players = info.current_players
	_spectators = info.current_spectators


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
