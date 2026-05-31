class_name SFFakeTransport
extends "res://addons/signal_fish/transport/sf_transport.gd"

var sent_text: Array = []
var sent_binary: Array = []
var buffered_amount := 0
var fail_on_connect := false

var _ready_state := WebSocketPeer.STATE_CLOSED
var _opened_emitted := false
var _closed_emitted := false
var _failed_emitted := false
var _connected_url := ""


func connect_to_url(url: String) -> Error:
	_connected_url = url
	_reset_session_flags()
	if fail_on_connect:
		_ready_state = WebSocketPeer.STATE_CLOSED
		_emit_failed_once("fake transport connect failure")
		return ERR_CANT_CONNECT
	_ready_state = WebSocketPeer.STATE_CONNECTING
	return OK


func poll() -> void:
	pass


func send_text(text: String) -> Error:
	if _ready_state != WebSocketPeer.STATE_OPEN or _is_terminal():
		return ERR_UNCONFIGURED
	sent_text.append(text)
	return OK


func send_binary(bytes: PackedByteArray) -> Error:
	if _ready_state != WebSocketPeer.STATE_OPEN or _is_terminal():
		return ERR_UNCONFIGURED
	sent_binary.append(bytes.duplicate())
	return OK


func get_buffered_amount() -> int:
	if _is_terminal():
		return 0
	return buffered_amount


func get_ready_state() -> int:
	return _ready_state


func close(code := 1000, reason := "") -> void:
	inject_close(code, reason)


func inject_open() -> void:
	if _ready_state != WebSocketPeer.STATE_CONNECTING or _opened_emitted or _is_terminal():
		return
	_ready_state = WebSocketPeer.STATE_OPEN
	_opened_emitted = true
	opened.emit()


func inject_text(text: String) -> void:
	if _ready_state != WebSocketPeer.STATE_OPEN or _is_terminal():
		return
	packet_received.emit(text.to_utf8_buffer(), true)


func inject_server_message(message: Dictionary) -> void:
	inject_text(JSON.stringify(message, "", false))


func inject_binary(bytes: PackedByteArray) -> void:
	if _ready_state != WebSocketPeer.STATE_OPEN or _is_terminal():
		return
	packet_received.emit(bytes.duplicate(), false)


func inject_close(code := 1000, reason := "") -> void:
	if _is_terminal():
		return
	if _ready_state == WebSocketPeer.STATE_CLOSED and not _opened_emitted:
		return
	_ready_state = WebSocketPeer.STATE_CLOSED
	if not _opened_emitted:
		_emit_failed_once(_failure_from_close_message(code, reason))
		return
	_emit_closed_once(code, reason)


func inject_failure(error: String) -> void:
	if _is_terminal():
		return
	_ready_state = WebSocketPeer.STATE_CLOSED
	_emit_failed_once(error)


func _reset_session_flags() -> void:
	_opened_emitted = false
	_closed_emitted = false
	_failed_emitted = false


func _is_terminal() -> bool:
	return _closed_emitted or _failed_emitted


func _emit_closed_once(code: int, reason: String) -> void:
	if _closed_emitted or _failed_emitted:
		return
	_closed_emitted = true
	closed.emit(code, reason)


func _emit_failed_once(error: String) -> void:
	if _closed_emitted or _failed_emitted:
		return
	_failed_emitted = true
	failed.emit(error)


func _failure_from_close_message(code: int, reason: String) -> String:
	if not reason.is_empty():
		return "fake transport connection failed before open: %s" % reason
	if code != 1000:
		return "fake transport connection failed before open: close code %d" % code
	return "fake transport connection failed before open"
