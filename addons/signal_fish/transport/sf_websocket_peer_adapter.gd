class_name SFWebSocketPeerAdapter
extends RefCounted

var _peer: WebSocketPeer = null
var _native_send_capacity := not OS.has_feature("web")


func _init(peer: WebSocketPeer = null) -> void:
	if peer == null:
		_peer = WebSocketPeer.new()
	else:
		_peer = peer


func connect_to_url(url: String) -> Error:
	return _peer.connect_to_url(url)


func poll() -> void:
	_peer.poll()


func get_ready_state() -> int:
	return _peer.get_ready_state()


func close(code := 1000, reason := "") -> void:
	_peer.close(code, reason)


func send_text(text: String) -> Error:
	if _native_send_capacity:
		var error := _send_capacity_error(text.to_utf8_buffer().size())
		if error != OK:
			return error
	return _send_result(_send_text(text))


func send_binary(bytes: PackedByteArray) -> Error:
	if _native_send_capacity:
		var error := _send_capacity_error(bytes.size())
		if error != OK:
			return error
	return _send_result(_send_binary(bytes))


func _send_text(text: String) -> Error:
	return _peer.send_text(text)


func _send_binary(bytes: PackedByteArray) -> Error:
	return _peer.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)


func _get_outbound_buffer_size() -> int:
	return _peer.outbound_buffer_size


func _send_capacity_error(frame_bytes: int) -> Error:
	if get_ready_state() != WebSocketPeer.STATE_OPEN:
		return OK
	var capacity := _get_outbound_buffer_size()
	if capacity <= 0:
		return OK
	if frame_bytes > capacity:
		return ERR_INVALID_DATA
	if get_current_outbound_buffered_amount() + frame_bytes > capacity:
		return ERR_BUSY
	return OK


func _send_result(error: Error) -> Error:
	# Godot 4.3/4.4.1/4.7.2 wsl_peer.cpp: OOM is a prequeue byte/count refusal (#510).
	if _native_send_capacity and error == ERR_OUT_OF_MEMORY:
		return ERR_BUSY
	return error


func get_current_outbound_buffered_amount() -> int:
	return _peer.get_current_outbound_buffered_amount()


func get_available_packet_count() -> int:
	return _peer.get_available_packet_count()


func get_packet() -> PackedByteArray:
	return _peer.get_packet()


func get_packet_error() -> Error:
	return _peer.get_packet_error()


func was_string_packet() -> bool:
	return _peer.was_string_packet()


func get_close_code() -> int:
	return _peer.get_close_code()


func get_close_reason() -> String:
	return _peer.get_close_reason()
