extends SceneTree

const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)

var _failures: Array = []


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("transport tests passed")
		quit(0)
	else:
		push_error("transport tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	_test_fake_connect_open_send_receive_and_close()
	_test_fake_failure_and_backpressure_getter()
	_test_fake_fail_on_connect_close_does_not_emit_closed()
	_test_fake_inject_failure_close_does_not_emit_closed()
	_test_websocket_invalid_scheme_and_send_error_without_network()
	_test_websocket_never_opened_closed_emits_failed_without_closed()


func _test_fake_connect_open_send_receive_and_close() -> void:
	var transport = SFFakeTransportScript.new()
	var opened_count := [0]
	var closed_events: Array = []
	var packets: Array = []
	transport.opened.connect(func() -> void: opened_count[0] += 1)
	transport.closed.connect(
		func(code: int, reason: String) -> void: closed_events.append([code, reason])
	)
	transport.packet_received.connect(
		func(payload: PackedByteArray, is_text: bool) -> void:
			packets.append({"payload": payload, "is_text": is_text})
	)

	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	_assert_equal(WebSocketPeer.STATE_CONNECTING, transport.get_ready_state(), "fake connecting")
	transport.inject_open()
	transport.inject_open()
	_assert_equal(1, opened_count[0], "fake opened once")
	_assert_equal(WebSocketPeer.STATE_OPEN, transport.get_ready_state(), "fake open state")

	_assert_equal(OK, transport.send_text("hello"), "fake send text")
	_assert_equal(PackedStringArray(["hello"]), PackedStringArray(transport.sent_text), "sent text")
	var binary := PackedByteArray([1, 2, 3])
	_assert_equal(OK, transport.send_binary(binary), "fake send binary")
	_assert_equal(binary, transport.sent_binary[0], "sent binary")

	transport.inject_text("server text")
	transport.inject_server_message({"type": "Pong"})
	transport.inject_binary(PackedByteArray([202, 254]))
	_assert_equal(3, packets.size(), "fake packet count")
	_assert_equal(true, packets[0]["is_text"], "fake text packet flag")
	_assert_equal("server text", packets[0]["payload"].get_string_from_utf8(), "fake text packet")
	_assert_equal('{"type":"Pong"}', packets[1]["payload"].get_string_from_utf8(), "server message")
	_assert_equal(false, packets[2]["is_text"], "fake binary packet flag")
	_assert_equal(PackedByteArray([202, 254]), packets[2]["payload"], "fake binary packet")

	transport.inject_close(1001, "going away")
	transport.inject_close(1006, "duplicate")
	_assert_equal(1, closed_events.size(), "fake closed once")
	_assert_equal([1001, "going away"], closed_events[0], "fake close event")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake closed state")


func _test_fake_failure_and_backpressure_getter() -> void:
	var connect_failure_transport = SFFakeTransportScript.new()
	var failures: Array = []
	connect_failure_transport.failed.connect(func(error: String) -> void: failures.append(error))
	connect_failure_transport.fail_on_connect = true
	_assert_equal(
		ERR_CANT_CONNECT,
		connect_failure_transport.connect_to_url("ws://example.test/socket"),
		"fake fail on connect"
	)
	_assert_equal(1, failures.size(), "fake connect failure count")
	_assert_string_contains(failures[0], "connect failure", "fake connect failure message")

	var transport = SFFakeTransportScript.new()
	transport.failed.connect(func(error: String) -> void: failures.append(error))
	transport.inject_failure("boom")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake failure state")
	_assert_equal("boom", failures[1], "fake injected failure")
	transport.buffered_amount = 512
	_assert_equal(512, transport.get_buffered_amount(), "fake buffered amount")


func _test_fake_fail_on_connect_close_does_not_emit_closed() -> void:
	var transport = SFFakeTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport.fail_on_connect = true
	_assert_equal(
		ERR_CANT_CONNECT,
		transport.connect_to_url("ws://example.test/socket"),
		"fake fail on connect"
	)
	transport.close()

	_assert_equal(["failed"], terminal_events, "fake fail-on-connect terminal ordering")


func _test_fake_inject_failure_close_does_not_emit_closed() -> void:
	var transport = SFFakeTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.inject_failure("boom")
	transport.close()

	_assert_equal(["failed"], terminal_events, "fake injected failure terminal ordering")


func _test_websocket_invalid_scheme_and_send_error_without_network() -> void:
	var transport = SFWebSocketTransportScript.new()
	var failures: Array = []
	transport.failed.connect(func(error: String) -> void: failures.append(error))
	var token := "sf_token_secret_123"

	_assert_equal(
		ERR_INVALID_PARAMETER,
		transport.connect_to_url("http://example.test/socket?access_token=%s" % token),
		"websocket invalid scheme"
	)
	_assert_equal(1, failures.size(), "websocket invalid scheme failure count")
	_assert_string_contains(failures[0], "invalid WebSocket URL scheme", "invalid scheme message")
	_assert_string_not_contains(failures[0], token, "invalid scheme message redacts query token")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "invalid scheme state")
	_assert_equal(0, transport.get_buffered_amount(), "invalid scheme buffered amount")

	_assert_equal(ERR_UNCONFIGURED, transport.send_text("not open"), "websocket send text not open")
	_assert_equal(
		ERR_UNCONFIGURED,
		transport.send_binary(PackedByteArray([1])),
		"websocket send binary not open"
	)
	_assert_equal(3, failures.size(), "websocket send failures")


func _test_websocket_never_opened_closed_emits_failed_without_closed() -> void:
	var transport = SFWebSocketTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport._peer = WebSocketPeer.new()
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
	transport.close()
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "never-opened terminal signal ordering")


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
		var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
		_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
		return false
	return true


func _assert_string_not_contains(actual: String, substring: String, label: String) -> bool:
	if actual.find(substring) != -1:
		_failures.append(
			"%s: expected %s not to contain %s" % [label, var_to_str(actual), var_to_str(substring)]
		)
		return false
	return true


func _assert_string_contains(actual: String, expected_substring: String, label: String) -> bool:
	if actual.find(expected_substring) == -1:
		_failures.append(
			(
				"%s: expected %s to contain %s"
				% [label, var_to_str(actual), var_to_str(expected_substring)]
			)
		)
		return false
	return true
