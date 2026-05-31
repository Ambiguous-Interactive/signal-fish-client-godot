class_name SFWebSocketTransport
extends "res://addons/signal_fish/transport/sf_transport.gd"

const DEFAULT_MAX_PACKETS_PER_POLL := 64

var max_packets_per_poll := DEFAULT_MAX_PACKETS_PER_POLL

var _peer: WebSocketPeer = null
var _opened_emitted := false
var _closed_emitted := false
var _handshake_failed_emitted := false


func connect_to_url(url: String) -> Error:
	_reset()
	if not _is_valid_websocket_url(url):
		failed.emit("invalid WebSocket URL scheme; expected ws:// or wss://")
		return ERR_INVALID_PARAMETER

	_peer = WebSocketPeer.new()
	var error := _peer.connect_to_url(url)
	if error != OK:
		failed.emit("failed to connect WebSocket: %s" % error_string(error))
		_peer = null
		return error
	return OK


func poll() -> void:
	if _peer == null:
		return

	_peer.poll()
	_handle_polled_state(_peer.get_ready_state())


func send_text(text: String) -> Error:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		failed.emit("cannot send WebSocket text frame while the socket is not open")
		return ERR_UNCONFIGURED
	var error := _peer.send_text(text)
	if error != OK:
		failed.emit("failed to send WebSocket text frame: %s" % error_string(error))
	return error


func send_binary(bytes: PackedByteArray) -> Error:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		failed.emit("cannot send WebSocket binary frame while the socket is not open")
		return ERR_UNCONFIGURED
	var error := _peer.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)
	if error != OK:
		failed.emit("failed to send WebSocket binary frame: %s" % error_string(error))
	return error


func get_buffered_amount() -> int:
	if _peer == null:
		return 0
	return _peer.get_current_outbound_buffered_amount()


func get_ready_state() -> int:
	if _peer == null:
		return WebSocketPeer.STATE_CLOSED
	return _peer.get_ready_state()


func close(code := 1000, reason := "") -> void:
	if _peer == null:
		return
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed_state()
		return
	_peer.close(code, reason)


func _reset() -> void:
	_peer = null
	_opened_emitted = false
	_closed_emitted = false
	_handshake_failed_emitted = false


func _is_valid_websocket_url(url: String) -> bool:
	return url.begins_with("ws://") or url.begins_with("wss://")


func _handle_polled_state(state: int) -> void:
	if state == WebSocketPeer.STATE_OPEN:
		_emit_opened_once()

	if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CLOSING:
		_drain_packets()

	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed_state()


func _drain_packets() -> void:
	var drained := 0
	while _peer.get_available_packet_count() > 0 and drained < max_packets_per_poll:
		var packet := _peer.get_packet()
		var error := _peer.get_packet_error()
		if error != OK:
			failed.emit("failed to read WebSocket packet: %s" % error_string(error))
			return
		packet_received.emit(packet, _peer.was_string_packet())
		drained += 1


func _handle_closed_state() -> void:
	if not _opened_emitted:
		if not _handshake_failed_emitted:
			_handshake_failed_emitted = true
			failed.emit(_closed_error_message())
		return
	_emit_closed_once()


func _emit_opened_once() -> void:
	if _opened_emitted:
		return
	_opened_emitted = true
	opened.emit()


func _emit_closed_once() -> void:
	if _peer == null or _closed_emitted:
		return
	_closed_emitted = true
	closed.emit(_peer.get_close_code(), _peer.get_close_reason())


func _closed_error_message() -> String:
	if _peer == null:
		return "WebSocket connection failed"
	var reason := _peer.get_close_reason()
	if not reason.is_empty():
		return "WebSocket connection failed: %s" % reason
	return "WebSocket connection failed"
