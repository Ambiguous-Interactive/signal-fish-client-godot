extends "res://addons/signal_fish/transport/sf_websocket_peer_adapter.gd"

var ready_state := WebSocketPeer.STATE_CONNECTING
var close_code := 1000
var close_reason := ""
var connect_error := OK
var send_text_error := OK
var send_binary_error := OK
var buffered_amount := 0
var close_calls: Array = []
var sent_text: Array = []
var sent_binary: Array = []
var packets: Array = []
var packet_errors: Array = []
var packet_is_text: Array = []
var poll_count := 0
var _last_packet_error := OK
var _last_was_string := false


func _init() -> void:
	pass


func connect_to_url(_url: String) -> Error:
	return connect_error


func poll() -> void:
	poll_count += 1


func get_ready_state() -> int:
	return ready_state


func close(code := 1000, reason := "") -> void:
	close_calls.append([code, reason])
	close_code = code
	close_reason = reason
	ready_state = WebSocketPeer.STATE_CLOSED


func send_text(text: String) -> Error:
	sent_text.append(text)
	return send_text_error


func send_binary(bytes: PackedByteArray) -> Error:
	sent_binary.append(bytes.duplicate())
	return send_binary_error


func get_current_outbound_buffered_amount() -> int:
	return buffered_amount


func get_available_packet_count() -> int:
	return packets.size()


func get_packet() -> PackedByteArray:
	if packet_errors.is_empty():
		_last_packet_error = OK
	else:
		_last_packet_error = int(packet_errors.pop_front())
	if packet_is_text.is_empty():
		_last_was_string = false
	else:
		_last_was_string = bool(packet_is_text.pop_front())
	if packets.is_empty():
		return PackedByteArray()
	return packets.pop_front()


func get_packet_error() -> Error:
	return _last_packet_error


func was_string_packet() -> bool:
	return _last_was_string


func get_close_code() -> int:
	return close_code


func get_close_reason() -> String:
	return close_reason
