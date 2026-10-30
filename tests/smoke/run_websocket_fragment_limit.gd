extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
const CONTROL_BODY := "interleaved-control"
const PHASE_TIMEOUT_MS := 2000

var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _capacity := 4095
var _message_type := "binary"
var _fragment_control := "none"
var _oversize := false
var _body := PackedByteArray()
var _failures: Array[String] = []
var _started := Time.get_ticks_msec()
var _opened := false
var _initial_offered := false
var _final_offered := false
var _initial_state := -1
var _received := 0
var _receipt: Dictionary = {}
var _following: Dictionary = {}
var _finished := false


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
		elif option == "--capacity" and value.is_valid_int():
			_capacity = value.to_int()
		elif option == "--message-type" and value in ["text", "binary"]:
			_message_type = value
		elif option == "--fragment-control" and value in ["none", "ping", "pong"]:
			_fragment_control = value
		elif option == "--oversize" and value in ["true", "false"]:
			_oversize = value == "true"
		else:
			_failures.append("invalid option: " + argument)
	if _capacity < 8 or _capacity > 65535:
		_failures.append("capacity must be 8..65535")
	if _fragment_control != "none" and _capacity < CONTROL_BODY.length():
		_failures.append("capacity must admit the control body")
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_server.poll()
	if not _finished and Time.get_ticks_msec() - _started > 8000:
		_failures.append("watchdog")
		_finish()
	return false


func _open() -> bool:
	if not _failures.is_empty():
		return false
	_peer.inbound_buffer_size = _capacity
	if _server.listen() != OK:
		_failures.append("listen failed")
		return false
	if _peer.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()) != OK:
		_failures.append("connect failed")
		return false
	var deadline := Time.get_ticks_msec() + PHASE_TIMEOUT_MS
	while (
		_peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING
		and Time.get_ticks_msec() < deadline
	):
		_peer.poll()
		await process_frame
	_opened = _peer.get_ready_state() == WebSocketPeer.STATE_OPEN
	if not _opened:
		_failures.append("open failed")
	return _opened


func _offer_tail() -> bool:
	if _fragment_control != "none":
		var opcode := ServerScript.OP_PING if _fragment_control == "ping" else ServerScript.OP_PONG
		if _server._send_frame(opcode, CONTROL_BODY.to_utf8_buffer()) != OK:
			_failures.append("control send failed")
			return false
	var tail := PackedByteArray([120]) if _oversize else PackedByteArray()
	if _server._send_frame(ServerScript.OP_CONTINUATION, tail) != OK:
		_failures.append("final continuation send failed")
		return false
	_final_offered = true
	if not _oversize:
		if _server._send_frame(ServerScript.OP_BINARY, PackedByteArray([255, 1])) != OK:
			_failures.append("following message send failed")
			return false
	return true


func _run() -> void:
	if not await _open():
		_finish()
		return
	_body.resize(_capacity)
	for offset: int in range(_capacity):
		_body[offset] = 120 if _message_type == "text" else offset % 256
	var opcode := ServerScript.OP_TEXT if _message_type == "text" else ServerScript.OP_BINARY
	if _server._send_frame(opcode, _body, false) != OK:
		_failures.append("initial fragment send failed")
		_finish()
		return
	_initial_offered = true
	var deadline := Time.get_ticks_msec() + PHASE_TIMEOUT_MS
	while _server.wire_report()["pending_bytes"] > 0 and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	if _server.wire_report()["pending_bytes"] != 0:
		_failures.append("initial fragment write timeout")
		_finish()
		return
	deadline = Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	_initial_state = _peer.get_ready_state()
	if _initial_state != WebSocketPeer.STATE_OPEN or _peer.get_available_packet_count() != 0:
		_failures.append("incomplete message state")
		_finish()
		return
	if not _offer_tail():
		_finish()
		return
	deadline = Time.get_ticks_msec() + PHASE_TIMEOUT_MS
	while (
		_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED
		and _peer.get_available_packet_count() == 0
		and Time.get_ticks_msec() < deadline
	):
		_peer.poll()
		await process_frame
	_check_result()
	if not _oversize and _failures.is_empty():
		await _check_following()
	_finish()


func _check_result() -> void:
	_received = _peer.get_available_packet_count()
	if _oversize:
		if (
			_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED
			or _peer.get_close_code() != 1009
			or _received != 0
		):
			_failures.append("oversize must close 1009 without a packet")
		return
	if _received not in [1, 2]:
		_failures.append("complete message missing")
		return
	var packet := _peer.get_packet()
	_receipt = {
		"bytes": packet.size(),
		"is_text": _peer.was_string_packet(),
		"error": _peer.get_packet_error(),
		"exact": packet == _body
	}
	if (
		packet != _body
		or _peer.was_string_packet() != (_message_type == "text")
		or _peer.get_packet_error() != OK
	):
		_failures.append("complete exact bytes and type")
	if _fragment_control == "ping":
		if (
			_server.received_pongs.size() != 1
			or _server.received_pongs[0] != CONTROL_BODY.to_utf8_buffer()
		):
			_failures.append("exact pong response missing")


func _check_following() -> void:
	var deadline := Time.get_ticks_msec() + PHASE_TIMEOUT_MS
	while _peer.get_available_packet_count() == 0 and Time.get_ticks_msec() < deadline:
		_peer.poll()
		await process_frame
	if _peer.get_available_packet_count() != 1:
		_failures.append("following message missing")
		return
	var packet := _peer.get_packet()
	_following = {
		"bytes": packet.size(),
		"is_text": _peer.was_string_packet(),
		"error": _peer.get_packet_error(),
		"exact": packet == PackedByteArray([255, 1])
	}
	if (
		packet != PackedByteArray([255, 1])
		or _peer.was_string_packet()
		or _peer.get_packet_error() != OK
	):
		_failures.append("following exact bytes and type")


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _server.wire_error != OK:
		_failures.append("paced socket write failed")
	print(
		(
			"FRAGMENT_LIMIT_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"wire": _server.wire_report(),
					"engine": Engine.get_version_info()["string"],
					"capacity": _capacity,
					"message_type": _message_type,
					"fragment_control": _fragment_control,
					"oversize": _oversize,
					"opened": _opened,
					"initial_offered": _initial_offered,
					"final_offered": _final_offered,
					"initial_state": _initial_state,
					"final_state": _peer.get_ready_state(),
					"close_code": _peer.get_close_code(),
					"received": _received,
					"receipt": _receipt,
					"following": _following,
					"pongs": _server.received_pongs.size(),
					"failures": _failures
				}
			)
		)
	)
	_peer.close(-1)
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
