extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _failures: Array[String] = []
var _started := Time.get_ticks_msec()
var _opened := 0
var _closing_state := -1
var _fresh: Dictionary = {}


func _initialize() -> void:
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


func _run() -> void:
	if _server.listen() != OK:
		_failures.append("listen")
		_finish()
		return
	if not await _open():
		_finish()
		return
	if _server._send_frame(ServerScript.OP_TEXT, "x".repeat(127).to_utf8_buffer(), false) != OK:
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
	if _peer.get_available_packet_count() != 0:
		_failures.append("unfinished fragment became packet")
	_peer.close(3400, "replace")
	_closing_state = _peer.get_ready_state()
	if _closing_state != WebSocketPeer.STATE_CLOSING:
		_failures.append("closing state")
	if not await _open():
		_finish()
		return
	if _server.send_text_frame("fresh") != OK:
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
			"body": packet.get_string_from_utf8(),
			"error": _peer.get_packet_error()
		}
		print("REDIAL_PACKET " + JSON.stringify(_fresh))
		if (
			packet != "fresh".to_utf8_buffer()
			or not _peer.was_string_packet()
			or _peer.get_packet_error() != OK
		):
			_failures.append("fresh exact bytes")
	_finish()


func _finish() -> void:
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
					"engine": Engine.get_version_info()["string"]
				}
			)
		)
	)
	_peer.close(-1)
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
