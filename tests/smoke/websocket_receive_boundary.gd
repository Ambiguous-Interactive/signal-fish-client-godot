extends Node

const BODY_BYTES := 4096
const PACKETS := 64

var _peer := WebSocketPeer.new()
var _options: Dictionary
var _received: Array[int] = []
var _failures: Array[String] = []
var _first_gap: Dictionary = {}
var _last_poll_us := 0
var _finished := false
var _sent := 0
var _started_ms := 0


func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	_options = JSON.parse_string(FileAccess.get_file_as_string("res://receive-options.json"))
	var capacity: int = _options["capacity"]
	var packet_count: int = _options["max_queued_packets"]
	if capacity > 0:
		_peer.inbound_buffer_size = capacity
	if packet_count > 0:
		_peer.max_queued_packets = packet_count
	_run()


func _body(sequence: int) -> String:
	return ("%08d" % sequence) + "x".repeat(BODY_BYTES - 8)


func _poll() -> void:
	var now := Time.get_ticks_usec()
	_peer.poll()
	print(
		(
			"WEBSOCKET_WEB_POLL "
			+ JSON.stringify(
				{
					"start_us": now,
					"interval_us": 0 if _last_poll_us == 0 else now - _last_poll_us,
					"queued": _peer.get_available_packet_count(),
					"state": _peer.get_ready_state()
				}
			)
		)
	)
	_last_poll_us = now
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		var sequence := packet.get_string_from_utf8().left(8).to_int()
		var exact := packet == _body(sequence).to_utf8_buffer()
		if sequence != _received.size() and _first_gap.is_empty():
			_first_gap = {"expected": _received.size(), "received": sequence}
		if not exact or not _peer.was_string_packet() or _peer.get_packet_error() != OK:
			_failures.append("packet bytes, type or read error")
		_received.append(sequence)
		print(
			(
				"WEBSOCKET_WEB_PACKET "
				+ JSON.stringify({"sequence": sequence, "exact": exact, "bytes": packet.size()})
			)
		)


func _run() -> void:
	if _peer.connect_to_url(str(_options["url"])) != OK:
		_failures.append("connect failed")
		_finish()
		return
	var deadline := Time.get_ticks_msec() + 5000
	while (
		_peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING
		and Time.get_ticks_msec() < deadline
	):
		_poll()
		await get_tree().process_frame
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_failures.append("open timeout")
		_finish()
		return
	var credit: int = _options["credit_bytes"]
	var batch_packets := PACKETS if credit == 0 else mini(PACKETS, int(credit / float(BODY_BYTES)))
	while _sent < PACKETS:
		var count := mini(PACKETS - _sent, batch_packets)
		if _peer.send_text("%d:%d" % [_sent, count]) != OK:
			_failures.append("burst command failed")
			break
		_sent += count
		var hold_ms: int = _options["hold_ms"]
		await get_tree().create_timer(hold_ms / 1000.0).timeout
		deadline = Time.get_ticks_msec() + 1000
		_poll()
		while _received.size() < _sent and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
			_poll()
		if _received.size() != _sent:
			_failures.append("finite burst count")
			break
	if _peer.send_text("64:1") != OK:
		_failures.append("sentinel command failed")
	else:
		_sent += 1
	deadline = Time.get_ticks_msec() + 1000
	while _received.size() < PACKETS + 1 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		_poll()
	if _received.size() != PACKETS + 1:
		_failures.append("complete receive count")
	if not _first_gap.is_empty():
		_failures.append("exact receive prefix")
	_finish()


func _process(_delta: float) -> void:
	var watchdog_ms: int = _options.get("watchdog_ms", 20000)
	if not _finished and Time.get_ticks_msec() - _started_ms > watchdog_ms:
		_failures.append("watchdog")
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	print(
		(
			"WEBSOCKET_WEB_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty(),
					"engine": Engine.get_version_info()["string"],
					"capacity": _peer.inbound_buffer_size,
					"max_queued_packets": _peer.max_queued_packets,
					"received": _received,
					"first_gap": _first_gap,
					"offered_packets": _sent,
					"failures": _failures
				}
			)
		)
	)
	_peer.close()
