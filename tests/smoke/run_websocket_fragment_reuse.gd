extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _failures: Array[String] = []
var _started := Time.get_ticks_msec()
var _opened := 0
var _closing_state := -1
var _fresh: Dictionary = {}
var _partial_type := "text"
var _fresh_type := "text"
var _replacement := "closing"
var _queued_before_partial := false
var _retired_queued := 0
var _pending_wire_before_replace := false


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var wire_option := _server.configure_wire_argument(argument)
		if wire_option != ERR_UNAVAILABLE:
			if wire_option != OK:
				_failures.append("invalid paced-write option: " + argument)
			continue
		var option := argument.get_slice("=", 0)
		var value := argument.get_slice("=", 1)
		if not argument.begins_with(option + "="):
			_failures.append("option requires =value")
		elif option == "--replacement":
			if value not in ["closing", "aborted", "handshake"]:
				_failures.append("replacement must be closing, aborted or handshake")
			else:
				_replacement = value
		elif option == "--pending-wire-before-replace":
			if value not in ["true", "false"]:
				_failures.append("pending-wire-before-replace must be true or false")
			else:
				_pending_wire_before_replace = value == "true"
		elif option == "--queued-before-partial":
			if value not in ["true", "false"]:
				_failures.append("queued-before-partial must be true or false")
			else:
				_queued_before_partial = value == "true"
		elif option not in ["--partial-type", "--fresh-type"] or value not in ["text", "binary"]:
			_failures.append("expected --partial-type=text|binary or --fresh-type=text|binary")
		elif option == "--partial-type":
			_partial_type = value
		else:
			_fresh_type = value
	if _pending_wire_before_replace and _replacement == "handshake":
		_failures.append("pending wire replacement requires closing or aborted")
	if _pending_wire_before_replace and _server.wire_chunk_bytes == 0:
		_failures.append("pending wire replacement requires paced writes")
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_server.poll()
	if Time.get_ticks_msec() - _started > 12000:
		_failures.append("watchdog")
		_finish()
	return false


func _open() -> bool:
	if _peer.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()) != OK:
		_failures.append("connect failed")
		return false
	var deadline := Time.get_ticks_msec() + 4000
	while (
		_peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING
		and Time.get_ticks_msec() < deadline
	):
		_peer.poll()
		await process_frame
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_failures.append("open failed")
		return false
	_opened += 1
	return true


func _queue_retired() -> bool:
	if not _queued_before_partial:
		return true
	if _server.send_text_frame("retired") != OK:
		_failures.append("retired send")
		return false
	var deadline := Time.get_ticks_msec() + 2000
	while _peer.get_available_packet_count() == 0 and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	_retired_queued = _peer.get_available_packet_count()
	if _retired_queued != 1:
		_failures.append("retired packet missing")
		return false
	return true


func _prepare() -> bool:
	if not _failures.is_empty():
		return false
	if _server.listen() != OK:
		_failures.append("listen")
		return false
	return await _open()


func _run() -> void:
	if not await _prepare():
		_finish()
		return
	if not await _queue_retired():
		_finish()
		return
	var partial_opcode := (
		ServerScript.OP_TEXT if _partial_type == "text" else ServerScript.OP_BINARY
	)
	if _server._send_frame(partial_opcode, "x".repeat(127).to_utf8_buffer(), false) != OK:
		_failures.append("fragment send")
		_finish()
		return
	if _server._send_frame(ServerScript.OP_PING, PackedByteArray()) != OK:
		_failures.append("barrier ping send")
		_finish()
		return
	var deadline := Time.get_ticks_msec() + 2000
	while _server.received_pongs.is_empty() and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	if _server.received_pongs.size() != 1 or not _server.received_pongs[0].is_empty():
		_failures.append("empty pong barrier")
		_finish()
		return
	if _peer.get_available_packet_count() != _retired_queued:
		_failures.append("unfinished fragment became packet")
	if _pending_wire_before_replace:
		if _server._send_frame(ServerScript.OP_CONTINUATION, PackedByteArray()) != OK:
			_failures.append("pending old continuation send")
			_finish()
			return
	_peer.close(-1 if _replacement == "aborted" else 3400, "replace")
	_closing_state = _peer.get_ready_state()
	if _replacement == "aborted":
		if _closing_state != WebSocketPeer.STATE_CLOSED:
			_failures.append("aborted state")
	elif _closing_state != WebSocketPeer.STATE_CLOSING:
		_failures.append("closing state")
	if _replacement == "handshake":
		deadline = Time.get_ticks_msec() + 2000
		while (
			_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED
			and Time.get_ticks_msec() < deadline
		):
			_peer.poll()
			await process_frame
		if _peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			_failures.append("close handshake timeout")
			_finish()
			return
		if _peer.get_close_code() != 3400 or _peer.get_close_reason() != "replace":
			_failures.append("close handshake result")
	if not await _open():
		_finish()
		return
	var fresh_bytes := (
		"fresh".to_utf8_buffer()
		if _fresh_type == "text"
		else PackedByteArray([0, 255, 128, 1, 254])
	)
	var fresh_opcode := ServerScript.OP_TEXT if _fresh_type == "text" else ServerScript.OP_BINARY
	if _server._send_frame(fresh_opcode, fresh_bytes) != OK:
		_failures.append("fresh send")
	deadline = Time.get_ticks_msec() + 2000
	while _peer.get_available_packet_count() == 0 and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	if _peer.get_available_packet_count() != 1:
		_failures.append("fresh receipt missing")
	else:
		var packet := _peer.get_packet()
		_fresh = {
			"bytes": packet.size(),
			"hex": packet.hex_encode(),
			"is_text": _peer.was_string_packet(),
			"error": _peer.get_packet_error()
		}
		print("REDIAL_PACKET " + JSON.stringify(_fresh))
		if (
			packet != fresh_bytes
			or _peer.was_string_packet() != (_fresh_type == "text")
			or _peer.get_packet_error() != OK
		):
			_failures.append("fresh exact bytes")
	_finish()


func _finish() -> void:
	if _pending_wire_before_replace and _server.wire_retired_bytes == 0:
		_failures.append("old queued output was not retired")
	if _server.wire_error != OK:
		_failures.append("paced socket write failed")
	print(
		(
			"REDIAL_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"failures": _failures,
					"opened": _opened,
					"closing_state": _closing_state,
					"empty_pongs": _server.received_pongs.size(),
					"fresh": _fresh,
					"replacement": _replacement,
					"retired_queued": _retired_queued,
					"pending_wire_before_replace": _pending_wire_before_replace,
					"partial_type": _partial_type,
					"fresh_type": _fresh_type,
					"wire": _server.wire_report(),
					"engine": Engine.get_version_info()["string"]
				}
			)
		)
	)
	_peer.close(-1)
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
