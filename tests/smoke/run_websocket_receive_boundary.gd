extends SceneTree

const ServerScript = preload("res://tests/smoke/ws_test_server.gd")
const PACKETS := 64
const CONNECT_TIMEOUT_MS := 5000
# Three seconds: the healthy Windows x86-64 watch runs never needed more
# than 563 ms between consecutive deliveries, and the benign Wine pacing
# stall recorded in #520 needed 1135 ms, so a one-second window left under
# twice the headroom.
const READ_TIMEOUT_MS := 3000
const BATCH_HOLD_MS := 100
const WATCHDOG_MARGIN_MS := 1000

var _body_bytes := 4096
var _empty_fragments := false
var _server := ServerScript.new()
var _peer := WebSocketPeer.new()
var _credit_bytes := 0
var _fragment_bytes := 0
var _fragment_control := "none"
var _message_type := "text"
var _received := 0
var _first_gap: Dictionary = {}
var _first_gap_expected := -1
var _failures: Array[String] = []
var _pending_waits: Array[Dictionary] = []
var _last_poll_us := 0
var _started := Time.get_ticks_msec()
var _sent := 0
var _batch_packets := PACKETS
var _watchdog_ms := CONNECT_TIMEOUT_MS


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var wire_option := _server.configure_wire_argument(argument)
		if wire_option != ERR_UNAVAILABLE:
			if wire_option != OK:
				_failures.append("invalid paced-write option: " + argument)
			continue
		var option := argument.get_slice("=", 0)
		if (
			option
			not in [
				"--capacity",
				"--max-queued-packets",
				"--credit",
				"--fragment-bytes",
				"--fragment-control",
				"--message-type",
				"--body-bytes",
				"--empty-fragments"
			]
		):
			_failures.append("unknown argument: " + argument)
			continue
		if not argument.begins_with(option + "="):
			_failures.append(option + " requires =value")
			continue
		var value := argument.substr(option.length() + 1)
		if option == "--empty-fragments":
			if value not in ["true", "false"]:
				_failures.append("empty fragments must be true or false")
			else:
				_empty_fragments = value == "true"
			continue
		if option == "--message-type":
			if value not in ["text", "binary", "alternating"]:
				_failures.append("message type must be text, binary or alternating")
			else:
				_message_type = value
			continue
		if option == "--fragment-control":
			if value not in ["none", "ping", "pong"]:
				_failures.append("fragment control must be none, ping or pong")
			else:
				_fragment_control = value
			continue
		if not value.is_valid_int():
			_failures.append(option + " must be an integer")
			continue
		var number := value.to_int()
		if option == "--body-bytes":
			_body_bytes = number
		elif option == "--credit":
			_credit_bytes = number
		elif option == "--fragment-bytes":
			_fragment_bytes = number
		elif number <= 0:
			_failures.append(option + " must be positive")
		elif option == "--capacity":
			_peer.inbound_buffer_size = number
		else:
			_peer.max_queued_packets = number
	if _body_bytes < 8 or _body_bytes > 65535:
		_failures.append("body bytes must be 8..65535")
	if _empty_fragments and _fragment_bytes == 0:
		_failures.append("empty fragments require fragmented messages")
	if _credit_bytes < 0 or _credit_bytes > 0 and _credit_bytes < _body_bytes:
		_failures.append("credit must be zero or admit one complete body")
	if _fragment_control != "none" and _fragment_bytes == 0:
		_failures.append("fragment control requires fragmented messages")
	if _fragment_bytes < 0 or _fragment_bytes >= _body_bytes:
		_failures.append("fragment bytes must be zero or smaller than one body")
	if _failures.is_empty():
		if _credit_bytes > 0:
			_batch_packets = mini(PACKETS, int(_credit_bytes / float(_body_bytes)))
		var batches := ceili(PACKETS / float(_batch_packets))
		_watchdog_ms = (
			CONNECT_TIMEOUT_MS
			+ batches * (BATCH_HOLD_MS + READ_TIMEOUT_MS)
			+ READ_TIMEOUT_MS
			+ WATCHDOG_MARGIN_MS
		)
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_server.poll()
	if Time.get_ticks_msec() - _started > _watchdog_ms:
		_failures.append("watchdog")
		_finish()
	return false


func _is_text(sequence: int) -> bool:
	return _message_type == "text" or _message_type == "alternating" and sequence % 2 == 0


func _body(sequence: int) -> PackedByteArray:
	var bytes := ("%08d" % sequence).to_utf8_buffer()
	bytes.resize(_body_bytes)
	for offset: int in range(8, _body_bytes):
		bytes[offset] = 120 if _is_text(sequence) else (offset + sequence) % 256
	return bytes


func _send(sequence: int) -> Error:
	var opcode := ServerScript.OP_TEXT if _is_text(sequence) else ServerScript.OP_BINARY
	if _fragment_bytes > 0:
		var control := 0
		if _fragment_control == "ping":
			control = ServerScript.OP_PING
		elif _fragment_control == "pong":
			control = ServerScript.OP_PONG
		return _server.send_message_fragments(
			_body(sequence), opcode, _fragment_bytes, control, _empty_fragments
		)
	return _server._send_frame(opcode, _body(sequence))


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
	var queued: Array[PackedByteArray] = []
	var arrivals := PackedInt64Array()
	var modes: Array[bool] = []
	var errors: Array[int] = []
	while _peer.get_available_packet_count() > 0:
		queued.append(_peer.get_packet())
		arrivals.append(Time.get_ticks_usec())
		modes.append(_peer.was_string_packet())
		errors.append(_peer.get_packet_error())
	for index: int in queued.size():
		var bytes := queued[index]
		var delivered_us := arrivals[index]
		var sequence := bytes.slice(0, 8).get_string_from_ascii().to_int()
		var exact := bytes == _body(_received)
		var exact_mode := modes[index] == _is_text(_received)
		if not exact and _first_gap.is_empty():
			_first_gap_expected = _received
			_first_gap = {"expected": _received, "received": sequence, "poll": observation}
		if errors[index] != OK or not exact_mode or not exact:
			if _failures.is_empty():
				_failures.append("exact receive prefix")
		print(
			(
				"WEBSOCKET_RECEIVE_PACKET "
				+ JSON.stringify(
					{
						"sequence": sequence,
						"bytes": bytes.size(),
						"exact": exact,
						"exact_mode": exact_mode,
						"delivered_us": delivered_us
					}
				)
			)
		)
		_received += 1


func _record_pending_wait(fallback: int, started_ms: int, deadline_ms: int) -> void:
	var expected := _first_gap_expected if _first_gap_expected >= 0 else fallback
	var wait: Dictionary = {
		"expected": expected,
		"waited_ms": Time.get_ticks_msec() - started_ms,
		"deadline_margin_ms": deadline_ms - Time.get_ticks_msec(),
	}
	_pending_waits.append(wait)


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
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
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
		var batch := mini(PACKETS - sent, _batch_packets)
		for sequence: int in range(sent, sent + batch):
			if _send(sequence) != OK:
				_failures.append("burst send failed")
				_finish()
				return
			_sent += 1
		sent += batch
		# Hold the consumer while the complete finite burst reaches the socket.
		await create_timer(BATCH_HOLD_MS / 1000.0).timeout
		_poll()
		var batch_started := Time.get_ticks_msec()
		var batch_deadline := batch_started + READ_TIMEOUT_MS
		while _received < sent and Time.get_ticks_msec() < batch_deadline:
			await process_frame
			_poll()
		if _received != sent:
			_record_pending_wait(_received, batch_started, batch_deadline)
			_failures.append("finite burst count")
			break
	# A later message exposes an interior gap even when the dropped tail was final.
	if _send(PACKETS) != OK:
		_failures.append("sentinel send failed")
	else:
		_sent += 1
	deadline = Time.get_ticks_msec() + READ_TIMEOUT_MS
	var sentinel_started := Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline and _received < PACKETS + 1:
		await process_frame
		_poll()
	if _received != PACKETS + 1:
		_record_pending_wait(_received, sentinel_started, deadline)
		_failures.append("complete receive count")
	_finish()


func _finish() -> void:
	if _server.wire_error != OK:
		_failures.append("paced socket write failed")
	print(
		(
			"WEBSOCKET_RECEIVE_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"wire": _server.wire_report(),
					"engine": Engine.get_version_info()["string"],
					"capacity": _peer.inbound_buffer_size,
					"max_queued_packets": _peer.max_queued_packets,
					"body_bytes": _body_bytes,
					"fragment_bytes": _fragment_bytes,
					"empty_fragments": _empty_fragments,
					"fragment_control": _fragment_control,
					"message_type": _message_type,
					"watchdog_ms": _watchdog_ms,
					"target_packets": PACKETS + 1,
					"offered_packets": _sent,
					"credit_bytes": _credit_bytes,
					"credit_scope": "local consumer body bytes; no network acknowledgement",
					"received": _received,
					"first_gap": _first_gap,
					"pending_wait": _pending_waits,
					"failures": _failures
				}
			)
		)
	)
	_peer.close()
	_server.stop()
	quit(0 if _failures.is_empty() else 1)
