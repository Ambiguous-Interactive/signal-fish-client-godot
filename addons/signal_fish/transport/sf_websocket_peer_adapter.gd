class_name SFWebSocketPeerAdapter
extends RefCounted

var _peer: WebSocketPeer = null


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
	return _peer.send_text(text)


func send_binary(bytes: PackedByteArray) -> Error:
	return _peer.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)


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
