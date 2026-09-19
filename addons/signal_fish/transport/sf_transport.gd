class_name SFTransport
extends RefCounted

signal opened
signal packet_received(payload: PackedByteArray, is_text: bool)
signal closed(code: int, reason: String)
signal failed(error: String)


func connect_to_url(_url: String) -> Error:
	push_error("SFTransport.connect_to_url() must be implemented by a transport adapter")
	return ERR_UNAVAILABLE


func poll() -> void:
	pass


func send_text(_text: String) -> Error:
	push_error("SFTransport.send_text() must be implemented by a transport adapter")
	return ERR_UNAVAILABLE


func send_binary(_bytes: PackedByteArray) -> Error:
	push_error("SFTransport.send_binary() must be implemented by a transport adapter")
	return ERR_UNAVAILABLE


func get_buffered_amount() -> int:
	return 0


func get_ready_state() -> int:
	return WebSocketPeer.STATE_CLOSED


func close(_code := 1000, _reason := "") -> void:
	pass
