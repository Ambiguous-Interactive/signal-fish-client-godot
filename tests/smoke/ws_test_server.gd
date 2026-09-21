extends RefCounted

## Minimal RFC 6455 WebSocket server bound to 127.0.0.1 for headless smoke
## tests. Supports one connection at a time, echoes text/binary frames,
## answers pings, and completes close handshakes in both directions. No TLS,
## no extensions, no fragmentation; frames over 1 MiB drop the connection.

const MAX_BUFFER_BYTES := 1024 * 1024
const OP_CONTINUATION := 0x0
const OP_TEXT := 0x1
const OP_BINARY := 0x2
const OP_CLOSE := 0x8
const OP_PING := 0x9
const OP_PONG := 0xA
const WS_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var received_text: Array = []
var received_binary: Array = []
var client_close_codes: Array = []

var _server: TCPServer = null
var _connection: StreamPeerTCP = null
var _buffer := PackedByteArray()
var _handshake_done := false
var _close_frame_sent := false


func listen() -> Error:
	_server = TCPServer.new()
	var error: Error = _server.listen(0, "127.0.0.1")
	if error != OK:
		_server = null
	return error


func get_port() -> int:
	if _server == null:
		return 0
	return _server.get_local_port()


func stop() -> void:
	_drop_connection()
	if _server != null:
		_server.stop()
		_server = null


func close_connection(code: int, reason: String) -> void:
	if _connection == null or _close_frame_sent:
		return
	var payload := PackedByteArray([(code >> 8) & 0xFF, code & 0xFF])
	payload.append_array(reason.to_utf8_buffer())
	_close_frame_sent = true
	_send_frame(OP_CLOSE, payload)


func poll() -> void:
	if _server == null or not _server.is_listening():
		return
	if _server.is_connection_available():
		var pending: StreamPeerTCP = _server.take_connection()
		if _connection != null:
			# Phases are sequential; a fresh inbound dial always takes over
			# the single slot so a lingering peer socket cannot block it.
			_drop_connection()
		_connection = pending
		_connection.set_no_delay(true)
	_drop_dead_connection()
	if _connection == null:
		return
	_read_available()
	if _connection == null:
		return
	if not _handshake_done:
		_try_handshake()
		if not _handshake_done:
			return
	_process_frames()


func _drop_dead_connection() -> void:
	if _connection == null:
		return
	if _connection.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop_connection()


func _drop_connection() -> void:
	if _connection != null:
		_connection.disconnect_from_host()
		_connection = null
	_buffer = PackedByteArray()
	_handshake_done = false
	_close_frame_sent = false


func _read_available() -> void:
	while _connection != null and _connection.get_available_bytes() > 0:
		var result: Array = _connection.get_partial_data(_connection.get_available_bytes())
		if result[0] != OK:
			_drop_connection()
			return
		var chunk: PackedByteArray = result[1]
		_buffer.append_array(chunk)
		if _buffer.size() > MAX_BUFFER_BYTES:
			_drop_connection()
			return


func _try_handshake() -> void:
	var header_end := _find_header_end()
	if header_end == -1:
		if _buffer.size() > MAX_BUFFER_BYTES:
			_drop_connection()
		return
	var head := _buffer.slice(0, header_end).get_string_from_utf8()
	var key := _extract_websocket_key(head)
	if key.is_empty():
		_drop_connection()
		return
	var response := (
		"HTTP/1.1 101 Switching Protocols\r\n"
		+ "Upgrade: websocket\r\n"
		+ "Connection: Upgrade\r\n"
		+ "Sec-WebSocket-Accept: %s\r\n\r\n" % _accept_key(key)
	)
	_connection.put_data(response.to_utf8_buffer())
	_buffer = _buffer.slice(header_end)
	_handshake_done = true


func _find_header_end() -> int:
	for i in range(_buffer.size() - 3):
		if (
			_buffer[i] == 13
			and _buffer[i + 1] == 10
			and _buffer[i + 2] == 13
			and _buffer[i + 3] == 10
		):
			return i + 4
	return -1


func _extract_websocket_key(head: String) -> String:
	var lower := head.to_lower()
	var key_index := lower.find("sec-websocket-key:")
	if key_index == -1:
		return ""
	var line_end := lower.find("\r\n", key_index)
	if line_end == -1:
		return ""
	return head.substr(key_index + 18, line_end - key_index - 18).strip_edges()


func _accept_key(key: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA1)
	context.update(key.to_utf8_buffer())
	context.update(WS_GUID.to_utf8_buffer())
	return Marshalls.raw_to_base64(context.finish())


func _process_frames() -> void:
	while _connection != null and _buffer.size() >= 2:
		var frame := _parse_frame()
		if frame.is_empty():
			return
		var opcode: int = frame["opcode"]
		var payload: PackedByteArray = frame["payload"]
		_handle_frame(opcode, payload)


func _parse_frame() -> Dictionary:
	var byte_zero: int = _buffer[0]
	var byte_one: int = _buffer[1]
	var opcode: int = byte_zero & 0x0F
	var masked: bool = (byte_one & 0x80) != 0
	var length: int = byte_one & 0x7F
	var offset := 2
	if length == 126:
		if _buffer.size() < 4:
			return {}
		length = (_buffer[2] << 8) | _buffer[3]
		offset = 4
	elif length == 127:
		if _buffer.size() < 10:
			return {}
		for i in range(2, 10):
			length = (length << 8) | _buffer[i]
		offset = 10
	if length < 0 or length > MAX_BUFFER_BYTES:
		_drop_connection()
		return {}
	var mask := PackedByteArray()
	if masked:
		if _buffer.size() < offset + 4:
			return {}
		mask = _buffer.slice(offset, offset + 4)
		offset += 4
	if _buffer.size() < offset + length:
		return {}
	var payload := _buffer.slice(offset, offset + length)
	if masked:
		payload = _unmask(payload, mask)
	_buffer = _buffer.slice(offset + length)
	return {"opcode": opcode, "payload": payload}


func _unmask(payload: PackedByteArray, mask: PackedByteArray) -> PackedByteArray:
	var unmasked := PackedByteArray()
	unmasked.resize(payload.size())
	for i in range(payload.size()):
		unmasked[i] = payload[i] ^ mask[i % 4]
	return unmasked


func _handle_frame(opcode: int, payload: PackedByteArray) -> void:
	match opcode:
		OP_TEXT:
			received_text.append(payload.get_string_from_utf8())
			_send_frame(OP_TEXT, payload)
		OP_BINARY:
			received_binary.append(payload.duplicate())
			_send_frame(OP_BINARY, payload)
		OP_CLOSE:
			if payload.size() >= 2:
				client_close_codes.append((payload[0] << 8) | payload[1])
			if not _close_frame_sent:
				_close_frame_sent = true
				_send_frame(OP_CLOSE, payload)
		OP_PING:
			_send_frame(OP_PONG, payload)
		OP_CONTINUATION, OP_PONG:
			pass


func _send_frame(opcode: int, payload: PackedByteArray) -> void:
	if _connection == null:
		return
	var length := payload.size()
	if length > 0xFFFF:
		_drop_connection()
		return
	var header := PackedByteArray([0x80 | opcode])
	if length <= 125:
		header.append(length)
	else:
		header.append(126)
		header.append((length >> 8) & 0xFF)
		header.append(length & 0xFF)
	_connection.put_data(header + payload)
