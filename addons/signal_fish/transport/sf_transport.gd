class_name SFTransport
extends RefCounted

## Adapter contract: adapters emit these signals; the base class never does.
@warning_ignore("unused_signal")
signal opened
@warning_ignore("unused_signal")
signal packet_received(payload: PackedByteArray, is_text: bool)
@warning_ignore("unused_signal")
signal closed(code: int, reason: String)
@warning_ignore("unused_signal")
signal failed(error: String)


## Contract: any non-OK return must be accompanied by a synchronous `failed`
## emission, so clients observing only signals never hang in a connecting state.
func connect_to_url(_url: String) -> Error:
	push_error("SFTransport.connect_to_url() must be implemented by a transport adapter")
	return ERR_UNAVAILABLE


func poll() -> void:
	pass


## Contract: `ERR_BUSY` is the sanctioned non-terminal backpressure refusal
## (drop, stay live, no `failed`); every other non-OK return must emit `failed`.
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
