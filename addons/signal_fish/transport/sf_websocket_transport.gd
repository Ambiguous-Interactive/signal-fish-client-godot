class_name SFWebSocketTransport
extends "res://addons/signal_fish/transport/sf_transport.gd"

const SFWebSocketPeerAdapterScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_peer_adapter.gd"
)
const DEFAULT_MAX_PACKETS_PER_POLL := 64
const SESSION_RESET_CLOSE_CODE := 1000
const SESSION_RESET_CLOSE_REASON := "transport session reset"

var max_packets_per_poll := DEFAULT_MAX_PACKETS_PER_POLL

var _peer: SFWebSocketPeerAdapterScript = null
var _opened_emitted := false
var _closed_emitted := false
var _failed_emitted := false


func connect_to_url(url: String) -> Error:
	_close_peer_for_session_reset()
	_reset_session_flags()
	if not _is_valid_websocket_url(url):
		_fail_current_session("invalid WebSocket URL scheme; expected ws:// or wss://", false)
		return ERR_INVALID_PARAMETER

	_peer = _make_peer()
	var error: Error = _peer.connect_to_url(url)
	if error != OK:
		_fail_current_session("failed to connect WebSocket: %s" % error_string(error))
		return error
	return OK


func poll() -> void:
	if _peer == null or _is_terminal():
		return

	_peer.poll()
	if _peer == null or _is_terminal():
		return
	_handle_polled_state(_peer.get_ready_state())


func send_text(text: String) -> Error:
	if not _can_send():
		return ERR_UNCONFIGURED
	var error: Error = _peer.send_text(text)
	if error != OK:
		_fail_current_session("failed to send WebSocket text frame: %s" % error_string(error))
	return error


func send_binary(bytes: PackedByteArray) -> Error:
	if not _can_send():
		return ERR_UNCONFIGURED
	var error: Error = _peer.send_binary(bytes)
	if error != OK:
		_fail_current_session("failed to send WebSocket binary frame: %s" % error_string(error))
	return error


func get_buffered_amount() -> int:
	if _peer == null or _is_terminal():
		return 0
	return _peer.get_current_outbound_buffered_amount()


func get_ready_state() -> int:
	if _peer == null:
		return WebSocketPeer.STATE_CLOSED
	return _peer.get_ready_state()


func close(code := 1000, reason := "") -> void:
	if _peer == null or _is_terminal():
		return
	var state: int = _peer.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed_state()
		return
	if state == WebSocketPeer.STATE_OPEN:
		_emit_opened_once()
	elif not _opened_emitted:
		_fail_current_session(_closed_error_message())
		return
	_peer.close(code, reason)


func _close_peer_for_session_reset() -> void:
	if _peer == null:
		return
	if _peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_peer.close(SESSION_RESET_CLOSE_CODE, SESSION_RESET_CLOSE_REASON)
	_peer = null


func _reset_session_flags() -> void:
	_opened_emitted = false
	_closed_emitted = false
	_failed_emitted = false


func _make_peer() -> SFWebSocketPeerAdapterScript:
	return SFWebSocketPeerAdapterScript.new()


func _is_valid_websocket_url(url: String) -> bool:
	var lower_url := url.to_lower()
	return lower_url.begins_with("ws://") or lower_url.begins_with("wss://")


func _handle_polled_state(state: int) -> void:
	if _is_terminal():
		return
	if state == WebSocketPeer.STATE_OPEN:
		_emit_opened_once()

	if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CLOSING:
		if not _drain_packets():
			return

	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed_state()


func _drain_packets() -> bool:
	if _peer == null or _is_terminal():
		return false
	var drained := 0
	while _peer.get_available_packet_count() > 0 and drained < max_packets_per_poll:
		var packet: PackedByteArray = _peer.get_packet()
		var error: Error = _peer.get_packet_error()
		if error != OK:
			_fail_current_session("failed to read WebSocket packet: %s" % error_string(error))
			return false
		packet_received.emit(packet, _peer.was_string_packet())
		drained += 1
		if _peer == null or _is_terminal():
			return false
	return true


func _handle_closed_state() -> void:
	if _is_terminal():
		return
	if not _opened_emitted:
		_fail_current_session(_closed_error_message(), false)
		return
	_emit_closed_once()


func _emit_opened_once() -> void:
	if _opened_emitted or _is_terminal():
		return
	_opened_emitted = true
	opened.emit()


func _emit_closed_once() -> void:
	if _peer == null or _closed_emitted or _failed_emitted:
		return
	var close_code: int = _peer.get_close_code()
	var close_reason: String = _peer.get_close_reason()
	_peer = null
	_closed_emitted = true
	closed.emit(close_code, close_reason)


func _fail_current_session(error: String, close_peer := true) -> void:
	if _failed_emitted or _closed_emitted:
		return
	var peer = _peer
	_peer = null
	_failed_emitted = true
	if close_peer and peer != null and peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		peer.close()
	failed.emit(error)


func _is_terminal() -> bool:
	return _closed_emitted or _failed_emitted


func _can_send() -> bool:
	return (
		_peer != null and not _is_terminal() and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN
	)


func _closed_error_message() -> String:
	if _peer == null:
		return "WebSocket connection failed"
	var reason: String = _peer.get_close_reason()
	if not reason.is_empty():
		return "WebSocket connection failed: %s" % reason
	return "WebSocket connection failed"
