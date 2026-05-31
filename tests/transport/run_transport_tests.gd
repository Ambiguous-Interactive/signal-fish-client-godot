extends SceneTree

const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)
const TestWebSocketPeerAdapterScript = preload(
	"res://tests/transport/test_websocket_peer_adapter.gd"
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
	_test_fake_reconnect_resets_terminal_flags()
	_test_fake_failure_and_backpressure_getter()
	_test_fake_fail_on_connect_close_does_not_emit_closed()
	_test_fake_inject_failure_close_does_not_emit_closed()
	_test_fake_connecting_close_fails_without_closed()
	_test_fake_terminal_sessions_do_not_reopen_or_emit_packets()
	_test_websocket_invalid_scheme_and_send_error_without_network()
	_test_websocket_never_opened_closed_emits_failed_without_closed()
	_test_websocket_case_insensitive_scheme_validation()
	_test_websocket_connect_resets_close_active_peer()
	_test_websocket_connecting_close_fails_without_closed()
	_test_websocket_read_error_is_terminal_once()


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


func _test_fake_reconnect_resets_terminal_flags() -> void:
	var transport = SFFakeTransportScript.new()
	var opened_count := [0]
	var closed_events: Array = []
	var failures: Array = []
	transport.opened.connect(func() -> void: opened_count[0] += 1)
	transport.closed.connect(
		func(code: int, reason: String) -> void: closed_events.append([code, reason])
	)
	transport.failed.connect(func(error: String) -> void: failures.append(error))

	_assert_equal(OK, transport.connect_to_url("ws://example.test/one"), "fake first connect")
	transport.inject_open()
	transport.inject_close(1000, "done")
	_assert_equal(1, opened_count[0], "fake first open")
	_assert_equal([[1000, "done"]], closed_events, "fake first close")

	_assert_equal(OK, transport.connect_to_url("ws://example.test/two"), "fake second connect")
	transport.inject_open()
	transport.inject_close(1001, "again")
	_assert_equal(2, opened_count[0], "fake reconnect opened")
	_assert_equal([[1000, "done"], [1001, "again"]], closed_events, "fake reconnect closed")

	transport.fail_on_connect = true
	_assert_equal(
		ERR_CANT_CONNECT, transport.connect_to_url("ws://example.test/three"), "fake fail"
	)
	transport.fail_on_connect = false
	_assert_equal(OK, transport.connect_to_url("ws://example.test/four"), "fake connect after fail")
	transport.inject_open()
	_assert_equal(3, opened_count[0], "fake open after failed connect")
	_assert_equal(1, failures.size(), "fake reconnect failure count")


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
	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.inject_open()
	transport.buffered_amount = 512
	_assert_equal(512, transport.get_buffered_amount(), "fake buffered amount")
	transport.inject_failure("boom")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake failure state")
	_assert_equal("boom", failures[1], "fake injected failure")
	_assert_equal(0, transport.get_buffered_amount(), "fake terminal buffered amount")


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


func _test_fake_connecting_close_fails_without_closed() -> void:
	var transport = SFFakeTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport.close()
	_assert_equal([], terminal_events, "fake idle close does not emit terminal event")
	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.close(1000, "abort")

	_assert_equal(["failed"], terminal_events, "fake connecting close terminal ordering")
	_assert_equal(
		WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake connecting close state"
	)


func _test_fake_terminal_sessions_do_not_reopen_or_emit_packets() -> void:
	var failed_transport = SFFakeTransportScript.new()
	var failed_events: Array = []
	var failed_packets: Array = []
	failed_transport.opened.connect(func() -> void: failed_events.append("opened"))
	failed_transport.failed.connect(func(_error: String) -> void: failed_events.append("failed"))
	failed_transport.closed.connect(
		func(_code: int, _reason: String) -> void: failed_events.append("closed")
	)
	failed_transport.packet_received.connect(
		func(_payload: PackedByteArray, _is_text: bool) -> void: failed_packets.append("packet")
	)

	_assert_equal(OK, failed_transport.connect_to_url("ws://example.test/socket"), "fake connect")
	failed_transport.inject_open()
	failed_transport.inject_failure("boom")
	failed_transport.inject_close(1000, "late close")
	failed_transport.inject_open()
	failed_transport.inject_text("late")
	failed_transport.inject_binary(PackedByteArray([1]))
	_assert_equal(["opened", "failed"], failed_events, "fake failure terminal boundary")
	_assert_equal([], failed_packets, "fake failure suppresses late packets")
	_assert_equal(
		ERR_UNCONFIGURED,
		failed_transport.send_text("late send"),
		"fake failed session rejects text send"
	)

	var closed_transport = SFFakeTransportScript.new()
	var closed_events: Array = []
	var closed_packets: Array = []
	closed_transport.opened.connect(func() -> void: closed_events.append("opened"))
	closed_transport.failed.connect(func(_error: String) -> void: closed_events.append("failed"))
	closed_transport.closed.connect(
		func(_code: int, _reason: String) -> void: closed_events.append("closed")
	)
	closed_transport.packet_received.connect(
		func(_payload: PackedByteArray, _is_text: bool) -> void: closed_packets.append("packet")
	)

	_assert_equal(OK, closed_transport.connect_to_url("ws://example.test/socket"), "fake connect 2")
	closed_transport.inject_open()
	closed_transport.inject_close(1000, "done")
	closed_transport.inject_failure("late failure")
	closed_transport.inject_open()
	closed_transport.inject_text("late")
	_assert_equal(["opened", "closed"], closed_events, "fake closed terminal boundary")
	_assert_equal([], closed_packets, "fake close suppresses late packets")
	_assert_equal(
		ERR_UNCONFIGURED,
		closed_transport.send_binary(PackedByteArray([1])),
		"fake closed session rejects binary send"
	)


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
	_assert_equal(1, failures.size(), "websocket invalid scheme is terminal once")


func _test_websocket_never_opened_closed_emits_failed_without_closed() -> void:
	var transport = SFWebSocketTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	var peer = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	transport._peer = peer
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
	transport.close()
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "never-opened terminal signal ordering")


func _test_websocket_case_insensitive_scheme_validation() -> void:
	var transport = SFWebSocketTransportScript.new()

	_assert(transport._is_valid_websocket_url("WS://example.test/socket"), "uppercase ws scheme")
	_assert(transport._is_valid_websocket_url("WSS://example.test/socket"), "uppercase wss scheme")
	_assert(transport._is_valid_websocket_url("wSs://example.test/socket"), "mixed wss scheme")
	_assert(not transport._is_valid_websocket_url("HTTP://example.test/socket"), "invalid scheme")


func _test_websocket_connect_resets_close_active_peer() -> void:
	var transport = SFWebSocketTransportScript.new()
	var peer = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_OPEN
	transport._peer = peer
	transport._opened_emitted = true
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	_assert_equal(
		ERR_INVALID_PARAMETER,
		transport.connect_to_url("http://example.test/socket"),
		"websocket reset invalid scheme"
	)

	_assert_equal(
		[
			[
				SFWebSocketTransportScript.SESSION_RESET_CLOSE_CODE,
				SFWebSocketTransportScript.SESSION_RESET_CLOSE_REASON
			]
		],
		peer.close_calls,
		"websocket reset closes active peer"
	)
	_assert_equal(["failed"], terminal_events, "websocket new invalid session failure")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "websocket reset state")


func _test_websocket_connecting_close_fails_without_closed() -> void:
	var transport = SFWebSocketTransportScript.new()
	var peer = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_CONNECTING
	transport._peer = peer
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport.close(1000, "abort")
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "websocket connecting close terminal ordering")
	_assert_equal([[1000, ""]], peer.close_calls, "websocket connecting close closes peer")
	_assert_equal(
		WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "websocket connecting close state"
	)


func _test_websocket_read_error_is_terminal_once() -> void:
	var transport = SFWebSocketTransportScript.new()
	var peer = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_OPEN
	peer.packets.append(PackedByteArray([1, 2, 3]))
	peer.packet_errors.append(ERR_FILE_CORRUPT)
	peer.packet_is_text.append(false)
	transport._peer = peer
	transport._opened_emitted = true
	var terminal_events: Array = []
	var packets: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)
	transport.packet_received.connect(
		func(_payload: PackedByteArray, _is_text: bool) -> void: packets.append("packet")
	)

	transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
	transport.poll()
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "websocket read error terminal once")
	_assert_equal([], packets, "websocket read error suppresses corrupt packet")
	_assert_equal([[1000, ""]], peer.close_calls, "websocket read error closes peer")
	_assert_equal(
		WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "websocket read error state"
	)


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append("%s: expected condition to be true" % label)
		return false
	return true


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
