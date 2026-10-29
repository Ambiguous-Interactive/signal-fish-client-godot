extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
const BODY_BYTES := 4096
const PACKETS := 64

var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _credit_bytes := 0
var _received := 0
var _first_gap: Dictionary = {}
var _failures: Array[String] = []
var _last_poll_us := 0
var _started := Time.get_ticks_msec()
var _sent := 0


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capacity="):
			_peer.inbound_buffer_size = argument.get_slice("=", 1).to_int()
		elif argument.begins_with("--max-queued-packets="):
			_peer.max_queued_packets = argument.get_slice("=", 1).to_int()
		elif argument.begins_with("--credit="):
			_credit_bytes = argument.get_slice("=", 1).to_int()
		else:
			_failures.append("unknown argument: " + argument)
	if _credit_bytes < 0 or _credit_bytes > 0 and _credit_bytes < BODY_BYTES:
		_failures.append("credit must be zero or admit one complete body")
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_server.poll()
	if Time.get_ticks_msec() - _started > 10000:
		_failures.append("watchdog")
		_finish()
	return false


func _body(sequence: int) -> String:
	return ("%08d" % sequence) + "x".repeat(BODY_BYTES - 8)


func _poll() -> void:
	var started := Time.get_ticks_usec()
	var before := _peer.get_available_packet_count()
	_peer.poll()
	var observation := {
		"start_us": started,
		"interval_us": 0 if _last_poll_us == 0 else started - _last_poll_us,
		"duration_us": Time.get_ticks_usec() - started,
		"queued_before": before,
		"queued_after": _peer.get_available_packet_count()
	}
	_last_poll_us = started
	print("WEBSOCKET_RECEIVE_POLL " + JSON.stringify(observation))
	while _peer.get_available_packet_count() > 0:
		var bytes := _peer.get_packet()
		var text := bytes.get_string_from_utf8()
		var sequence := text.left(8).to_int()
		var exact := bytes == _body(_received).to_utf8_buffer()
		if not exact and _first_gap.is_empty():
			_first_gap = {"expected": _received, "received": sequence, "poll": observation}
		if _peer.get_packet_error() != OK or not _peer.was_string_packet() or not exact:
			if _failures.is_empty():
				_failures.append("exact receive prefix")
		print(
			(
				"WEBSOCKET_RECEIVE_PACKET "
				+ JSON.stringify({"sequence": sequence, "bytes": bytes.size(), "exact": exact})
			)
		)
		_received += 1


func _run() -> void:
	if not _failures.is_empty():
		_finish()
		return
	if _server.listen() != OK:
		_failures.append("listen failed")
		_finish()
		return
	if _peer.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()) != OK:
		_failures.append("connect failed")
		_finish()
		return
	var deadline := Time.get_ticks_msec() + 5000
	while _peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_poll()
		if Time.get_ticks_msec() >= deadline:
			_failures.append("connect timeout")
			_finish()
			return
		await process_frame
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_failures.append("open failed")
		_finish()
		return
	var sent := 0
	while sent < PACKETS:
		var batch := PACKETS - sent
		if _credit_bytes > 0:
			batch = mini(batch, int(_credit_bytes / float(BODY_BYTES)))
		for sequence: int in range(sent, sent + batch):
			if _server.send_text_frame(_body(sequence)) != OK:
				_failures.append("burst send failed")
				_finish()
				return
			_sent += 1
		sent += batch
		# Hold the consumer while the complete finite burst reaches the socket.
		await create_timer(0.1).timeout
		_poll()
		var batch_deadline := Time.get_ticks_msec() + 1000
		while _received < sent and Time.get_ticks_msec() < batch_deadline:
			await process_frame
			_poll()
		if _received != sent:
			_failures.append("finite burst count")
			break
	# A later message exposes an interior gap even when the dropped tail was final.
	if _server.send_text_frame(_body(PACKETS)) != OK:
		_failures.append("sentinel send failed")
	else:
		_sent += 1
	deadline = Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and _received < PACKETS + 1:
		await process_frame
		_poll()
	if _received != PACKETS + 1:
		_failures.append("complete receive count")
	_finish()


func _finish() -> void:
	print(
		(
			"WEBSOCKET_RECEIVE_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"engine": Engine.get_version_info()["string"],
					"capacity": _peer.inbound_buffer_size,
					"max_queued_packets": _peer.max_queued_packets,
					"body_bytes": BODY_BYTES,
					"target_packets": PACKETS + 1,
					"offered_packets": _sent,
					"credit_bytes": _credit_bytes,
					"credit_scope": "local consumer body bytes; no network acknowledgement",
					"received": _received,
					"first_gap": _first_gap,
					"failures": _failures
				}
			)
		)
	)
	_peer.close()
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
