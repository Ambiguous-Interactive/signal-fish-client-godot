extends SceneTree

## Opt-in headless smoke test for the real WebSocketPeer adapter path.
## Runs a local RFC 6455 server (tests/smoke/ws_test_server.gd) and drives
## SFWebSocketTransport against it: open, text/binary echo round-trip,
## client- and server-initiated close handshakes, and a refused dial.
## Run via: bash scripts/run-runtime-checks.sh smoke

const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)
const WsTestServerScript = preload("res://tests/smoke/ws_test_server.gd")

const WAIT_TIMEOUT_SEC := 5.0
const WATCHDOG_MS := 30000

var _failures: Array = []
var _server: WsTestServerScript = null
var _transport: SFWebSocketTransportScript = null
var _opened_count := 0
var _packets: Array = []
var _closed_events: Array = []
var _failure_messages: Array = []
var _done := false
var _started_ms := 0


func _initialize() -> void:
	_started_ms = Time.get_ticks_msec()
	_run()


func _process(_delta: float) -> bool:
	if _server != null:
		_server.poll()
	if _transport != null:
		_transport.poll()
	if not _done and Time.get_ticks_msec() - _started_ms > WATCHDOG_MS:
		_finish_watchdog()
	return false


func _run() -> void:
	var passed := true
	if passed:
		passed = _phase_ok(await _smoke_echo_round_trip_and_client_close(), "echo round-trip")
	if passed:
		passed = _phase_ok(await _smoke_server_initiated_close(), "remote close")
	if passed:
		passed = _phase_ok(await _smoke_failed_dial_is_terminal(), "refused dial")
	if _server != null:
		_server.stop()
	_server = null
	_transport = null
	_done = true
	if _failures.is_empty():
		print("websocket smoke passed")
		quit(0)
		return
	push_error("websocket smoke failed: %d failure(s)" % _failures.size())
	for failure: String in _failures:
		push_error(failure)
	quit(1)


func _phase_ok(result: Variant, label: String) -> bool:
	if result == true:
		return true
	_failures.append("%s phase did not complete" % label)
	return false


func _smoke_echo_round_trip_and_client_close() -> bool:
	_start_server()
	_reset_transport()
	_assert_equal(
		OK, _transport.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()), "smoke connect"
	)
	if not await _wait_until(func() -> bool: return _opened_count == 1, "transport open"):
		return false
	_assert_equal(WebSocketPeer.STATE_OPEN, _transport.get_ready_state(), "smoke open state")

	_assert_equal(OK, _transport.send_text("hello-smoke"), "smoke send text")
	if not await _wait_until(
		func() -> bool: return _server.received_text.size() == 1, "server text receipt"
	):
		return false
	_assert_equal("hello-smoke", _server.received_text[0], "server text content")
	if not await _wait_until(func() -> bool: return _packets.size() == 1, "text echo receipt"):
		return false

	var binary := PackedByteArray([1, 2, 3, 250])
	_assert_equal(OK, _transport.send_binary(binary), "smoke send binary")
	if not await _wait_until(
		func() -> bool: return _server.received_binary.size() == 1, "server binary receipt"
	):
		return false
	_assert_equal(binary, _server.received_binary[0], "server binary content")
	if not await _wait_until(func() -> bool: return _packets.size() == 2, "binary echo receipt"):
		return false

	var text_payload: PackedByteArray = _packets[0]["payload"]
	_assert_equal(true, _packets[0]["is_text"], "text echo is_text flag")
	_assert_equal("hello-smoke", text_payload.get_string_from_utf8(), "text echo content")
	_assert_equal(false, _packets[1]["is_text"], "binary echo is_text flag")
	_assert_equal(binary, _packets[1]["payload"], "binary echo content")
	_assert_equal(0, _transport.get_buffered_amount(), "buffered amount drained")

	_transport.close(3400, "smoke-done")
	if not await _wait_until(func() -> bool: return _closed_events.size() == 1, "client close"):
		return false
	_assert_equal([[3400, "smoke-done"]], _closed_events, "client close code/reason")
	if not await _wait_until(
		func() -> bool: return _server.client_close_codes.size() == 1, "server close receipt"
	):
		return false
	_assert_equal(3400, _server.client_close_codes[0], "server close code")
	_assert_equal([], _failure_messages, "echo phase failures")
	return _failures.is_empty()


func _smoke_server_initiated_close() -> bool:
	_reset_transport()
	_assert_equal(
		OK, _transport.connect_to_url("ws://127.0.0.1:%d" % _server.get_port()), "smoke reconnect"
	)
	if not await _wait_until(func() -> bool: return _opened_count == 1, "reopen"):
		return false
	_server.close_connection(4321, "server-bye")
	if not await _wait_until(func() -> bool: return _closed_events.size() == 1, "remote close"):
		return false
	_assert_equal([[4321, "server-bye"]], _closed_events, "remote close code/reason")
	_assert_equal([], _failure_messages, "remote close phase failures")
	return _failures.is_empty()


func _smoke_failed_dial_is_terminal() -> bool:
	_reset_transport()
	var probe := TCPServer.new()
	_assert_equal(OK, probe.listen(0, "127.0.0.1"), "dead-port probe listen")
	var dead_port: int = probe.get_local_port()
	probe.stop()
	_assert_equal(OK, _transport.connect_to_url("ws://127.0.0.1:%d" % dead_port), "dead dial")
	if not await _wait_until(
		func() -> bool: return _failure_messages.size() == 1, "refused dial failure"
	):
		return false
	_assert_equal(0, _opened_count, "refused dial opened count")
	_assert_equal([], _closed_events, "refused dial closed events")
	_assert_equal(WebSocketPeer.STATE_CLOSED, _transport.get_ready_state(), "refused dial state")
	return _failures.is_empty()


func _reset_transport() -> void:
	_opened_count = 0
	_packets = []
	_closed_events = []
	_failure_messages = []
	_transport = SFWebSocketTransportScript.new()
	_transport.opened.connect(func() -> void: _opened_count += 1)
	_transport.packet_received.connect(
		func(payload: PackedByteArray, is_text: bool) -> void:
			_packets.append({"payload": payload, "is_text": is_text})
	)
	_transport.closed.connect(
		func(code: int, reason: String) -> void: _closed_events.append([code, reason])
	)
	_transport.failed.connect(func(error: String) -> void: _failure_messages.append(error))


func _start_server() -> void:
	_server = WsTestServerScript.new()
	_assert_equal(OK, _server.listen(), "smoke server listen")
	if _server.get_port() <= 0:
		_failures.append("smoke server reported no port")


func _wait_until(condition: Callable, label: String) -> bool:
	var deadline_ms := Time.get_ticks_msec() + int(WAIT_TIMEOUT_SEC * 1000)
	while true:
		var satisfied: bool = condition.call()
		if satisfied:
			return true
		if Time.get_ticks_msec() > deadline_ms:
			var transport_state := "null"
			if _transport != null:
				transport_state = str(_transport.get_ready_state())
			_failures.append(
				(
					(
						"%s: timed out (transport_state=%s opened=%d packets=%d closed=%d"
						+ " failures=%d server_text=%d server_binary=%d server_close=%d)"
					)
					% [
						label,
						transport_state,
						_opened_count,
						_packets.size(),
						_closed_events.size(),
						_failure_messages.size(),
						_server.received_text.size(),
						_server.received_binary.size(),
						_server.client_close_codes.size()
					]
				)
			)
			return false
		await process_frame
	return true


func _finish_watchdog() -> void:
	_done = true
	push_error(
		"websocket smoke watchdog timeout after %dms" % (Time.get_ticks_msec() - _started_ms)
	)
	for failure: String in _failures:
		push_error(failure)
	quit(1)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected == actual:
		return
	var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
	var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
	_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
