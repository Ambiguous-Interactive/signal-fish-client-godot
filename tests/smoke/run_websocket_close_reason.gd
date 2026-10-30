extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
const TIMEOUT_MS := 2000
const CLOSE_CODE := 3400

var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _reason_kind := "two"
var _origin := "server"
var _full_fragment := false
var _capacity := 31
var _reason := ""
var _failures: Array[String] = []
var _opened := false
var _finished := false
var _started := Time.get_ticks_msec()


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var wire_option := _server.configure_wire_argument(argument)
		if wire_option != ERR_UNAVAILABLE:
			if wire_option != OK:
				_failures.append("invalid paced-write option: " + argument)
			continue
		var option := argument.get_slice("=", 0)
		var value := argument.substr(option.length() + 1)
		if not argument.begins_with(option + "="):
			_failures.append("option requires =value")
		elif (
			option == "--reason"
			and (
				value
				in ["empty", "ascii", "two", "three", "four", "mixed", "max-ascii", "max-mixed"]
			)
		):
			_reason_kind = value
		elif option == "--origin" and value in ["server", "client"]:
			_origin = value
		elif option == "--full-fragment" and value in ["true", "false"]:
			_full_fragment = value == "true"
		elif option == "--capacity" and value.is_valid_int():
			_capacity = value.to_int()
		else:
			_failures.append("invalid option: " + argument)
	var reasons := {
		"empty": "",
		"ascii": "server_shutdown",
		"two": String.chr(233) + "abc",
		"three": String.chr(0x20ac) + "abc",
		"four": String.chr(0x1f41f) + "abc",
		"mixed": "ok/" + String.chr(233) + String.chr(0x20ac) + String.chr(0x1f41f) + "/end",
		"max-ascii": "x".repeat(123),
		"max-mixed":
		(
			(String.chr(233) + String.chr(0x20ac) + String.chr(0x1f41f)).repeat(13)
			+ String.chr(0x1f41f)
			+ String.chr(233)
		)
	}
	_reason = reasons[_reason_kind]
	if _capacity < 31 or _capacity > 131071:
		_failures.append("capacity must be 31..131071")
	if _reason.to_utf8_buffer().size() + 2 > _capacity:
		_failures.append("capacity must admit the close payload")
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_server.poll()
	if not _finished and Time.get_ticks_msec() - _started > 8000:
		_failures.append("watchdog")
		_finish()
	return false


func _run() -> void:
	if not _failures.is_empty():
		_finish()
		return
	_peer.inbound_buffer_size = _capacity
	if _server.listen() != OK:
		_failures.append("listen failed")
		_finish()
		return
	if _peer.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()) != OK:
		_failures.append("connect failed")
		_finish()
		return
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while (
		_peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING
		and Time.get_ticks_msec() < deadline
	):
		_peer.poll()
		await process_frame
	_opened = _peer.get_ready_state() == WebSocketPeer.STATE_OPEN
	if not _opened:
		_failures.append("open failed")
		_finish()
		return
	if _full_fragment and not await _fill_fragment():
		_finish()
		return
	if _origin == "server":
		_server.close_connection(CLOSE_CODE, _reason)
	else:
		_peer.close(CLOSE_CODE, _reason)
	deadline = Time.get_ticks_msec() + TIMEOUT_MS
	while (
		_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED and Time.get_ticks_msec() < deadline
	):
		_peer.poll()
		await process_frame
	if (
		_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED
		or _peer.get_close_code() != CLOSE_CODE
		or _peer.get_close_reason() != _reason
		or _peer.get_available_packet_count() != 0
	):
		_failures.append("exact close code, reason and empty packet queue")
	deadline = Time.get_ticks_msec() + TIMEOUT_MS
	while _server.client_close_codes.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if _server.client_close_codes != [CLOSE_CODE]:
		_failures.append("matching client close frame")
	if _server.client_close_reasons != [_reason.to_utf8_buffer()]:
		_failures.append("matching client close reason bytes")
	_finish()


func _fill_fragment() -> bool:
	if (
		_server._send_frame(ServerScript.OP_BINARY, "x".repeat(_capacity).to_utf8_buffer(), false)
		!= OK
	):
		_failures.append("fragment send failed")
		return false
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while _server.wire_report()["pending_bytes"] > 0 and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	var settle := Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < settle:
		_peer.poll()
		await process_frame
	if (
		_server.wire_report()["pending_bytes"] != 0
		or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN
		or _peer.get_available_packet_count() != 0
	):
		_failures.append("unfinished full fragment state")
		return false
	return true


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _server.wire_error != OK:
		_failures.append("paced socket write failed")
	print(
		(
			"CLOSE_REASON_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"engine": Engine.get_version_info()["string"],
					"origin": _origin,
					"reason_kind": _reason_kind,
					"full_fragment": _full_fragment,
					"capacity": _capacity,
					"opened": _opened,
					"state": _peer.get_ready_state(),
					"close_code": _peer.get_close_code(),
					"reason_hex": _peer.get_close_reason().to_utf8_buffer().hex_encode(),
					"expected_reason_hex": _reason.to_utf8_buffer().hex_encode(),
					"client_close_codes": _server.client_close_codes,
					"client_reason_hex":
					_server.client_close_reasons.map(
						func(reason: PackedByteArray) -> String: return reason.hex_encode()
					),
					"wire": _server.wire_report(),
					"failures": _failures
				}
			)
		)
	)
	_peer.close(-1)
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
