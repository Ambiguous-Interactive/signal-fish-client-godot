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
	if fail_on_connect:
		_ready_state = WebSocketPeer.STATE_CLOSED
		_emit_failed_once("fake transport connect failure")
		return ERR_CANT_CONNECT
	_ready_state = WebSocketPeer.STATE_CONNECTING
	return OK


func poll() -> void:
	pass


func send_text(text: String) -> Error:
	if _ready_state != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	sent_text.append(text)
	return OK


func send_binary(bytes: PackedByteArray) -> Error:
	if _ready_state != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	sent_binary.append(bytes.duplicate())
	return OK


func get_buffered_amount() -> int:
	return buffered_amount


func get_ready_state() -> int:
	return _ready_state


func close(code := 1000, reason := "") -> void:
	inject_close(code, reason)


func inject_open() -> void:
	_ready_state = WebSocketPeer.STATE_OPEN
	if _opened_emitted:
		return
	_opened_emitted = true
	opened.emit()


func inject_text(text: String) -> void:
	packet_received.emit(text.to_utf8_buffer(), true)


func inject_server_message(message: Dictionary) -> void:
	inject_text(JSON.stringify(message, "", false))


func inject_binary(bytes: PackedByteArray) -> void:
	packet_received.emit(bytes.duplicate(), false)


func inject_close(code := 1000, reason := "") -> void:
	_ready_state = WebSocketPeer.STATE_CLOSED
	if _failed_emitted and not _opened_emitted:
		return
	if _closed_emitted:
		return
	_closed_emitted = true
	closed.emit(code, reason)


func inject_failure(error: String) -> void:
	_ready_state = WebSocketPeer.STATE_CLOSED
	_emit_failed_once(error)


func _emit_failed_once(error: String) -> void:
	if _failed_emitted:
		return
	_failed_emitted = true
	failed.emit(error)
