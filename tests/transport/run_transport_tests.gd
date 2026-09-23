extends SceneTree

const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SFWebSocketTransportScript = preload(
	"res://addons/signal_fish/transport/sf_websocket_transport.gd"
)
const TestWebSocketPeerAdapterScript = preload(
	"res://tests/transport/test_websocket_peer_adapter.gd"
)
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array = []
var _test_done := false
# Completion sentinel: a runtime abort inside _run() would otherwise leave
# the process hanging until CI kills it.
var _run_completed := false
# Session under test for _redial_packet_handler. The connection binds the
# long-lived SceneTree instead of a lambda capturing the transport local.
var _redial_transport: SFWebSocketTransportScript = null


func _done() -> void:
	_test_done = true


func _init() -> void:
	_run()
	if not _run_completed:
		push_error("transport tests aborted before completion")
		quit(1)
		return
	if _failures.is_empty():
		print("transport tests passed")
		quit(0)
	else:
		push_error("transport tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	var cases: Array[Callable] = [
		_test_fake_connect_open_send_receive_and_close,
		_test_fake_fail_on_send_mirrors_real_cascade,
		_test_fake_reconnect_resets_terminal_flags,
		_test_fake_failure_and_backpressure_getter,
		_test_fake_fail_on_connect_close_does_not_emit_closed,
		_test_fake_inject_failure_close_does_not_emit_closed,
		_test_fake_connecting_close_fails_without_closed,
		_test_fake_terminal_sessions_do_not_reopen_or_emit_packets,
		_test_fake_reconnect_clears_sent_history,
		_test_websocket_invalid_scheme_and_send_error_without_network,
		_test_websocket_never_opened_closed_emits_failed_without_closed,
		_test_websocket_case_insensitive_scheme_validation,
		_test_websocket_connect_resets_close_active_peer,
		_test_websocket_connecting_close_fails_without_closed,
		_test_websocket_connecting_close_surfaces_caller_reason,
		_test_websocket_read_error_is_terminal_once,
		_test_websocket_closed_state_delivers_queued_packets,
		_test_close_at_closed_drains_queued_packets,
	]
	CompletionGuard.self_check(self, _failures)
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)
	_run_completed = true


func _test_fake_connect_open_send_receive_and_close() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
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
	var first_payload: PackedByteArray = packets[0]["payload"]
	var server_payload: PackedByteArray = packets[1]["payload"]
	_assert_equal(true, packets[0]["is_text"], "fake text packet flag")
	_assert_equal("server text", first_payload.get_string_from_utf8(), "fake text packet")
	_assert_equal('{"type":"Pong"}', server_payload.get_string_from_utf8(), "server message")
	_assert_equal(false, packets[2]["is_text"], "fake binary packet flag")
	_assert_equal(PackedByteArray([202, 254]), packets[2]["payload"], "fake binary packet")

	transport.inject_close(1001, "going away")
	transport.inject_close(1006, "duplicate")
	_assert_equal(1, closed_events.size(), "fake closed once")
	_assert_equal([1001, "going away"], closed_events[0], "fake close event")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake closed state")
	_done()


func _test_fake_fail_on_send_mirrors_real_cascade() -> void:
	# Issue #24 send-failure parity: the fake must kill the session exactly
	# like the real transport's synchronous send failure.
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	var failures: Array = []
	transport.failed.connect(func(error: String) -> void: failures.append(error))
	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.inject_open()
	transport.fail_on_send = true
	_assert_equal(
		ERR_CONNECTION_ERROR, transport.send_text("lost"), "failing send returns the error"
	)
	_assert_equal(
		ERR_UNCONFIGURED,
		transport.send_binary(PackedByteArray([1])),
		"post-failure binary send refused"
	)
	_assert_equal(1, failures.size(), "failed emitted once")
	var send_failure: String = failures[0]
	_assert_string_contains(send_failure, "failed to send", "failure names the send")
	_assert_equal([], transport.sent_text, "failed text not recorded")
	_assert_equal([], transport.sent_binary, "failed binary not recorded")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "session dead")
	_assert_equal(0, transport.get_buffered_amount(), "dead session reports zero buffered")
	_assert_equal(ERR_UNCONFIGURED, transport.send_text("late"), "post-failure send refused")
	_assert_equal(1, failures.size(), "failed emitted exactly once")
	_done()


func _test_fake_reconnect_resets_terminal_flags() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
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
	_done()


func _test_fake_failure_and_backpressure_getter() -> void:
	var connect_failure_transport: SFFakeTransportScript = SFFakeTransportScript.new()
	var failures: Array = []
	connect_failure_transport.failed.connect(func(error: String) -> void: failures.append(error))
	connect_failure_transport.fail_on_connect = true
	_assert_equal(
		ERR_CANT_CONNECT,
		connect_failure_transport.connect_to_url("ws://example.test/socket"),
		"fake fail on connect"
	)
	_assert_equal(1, failures.size(), "fake connect failure count")
	var connect_failure: String = failures[0]
	_assert_string_contains(connect_failure, "connect failure", "fake connect failure message")

	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	transport.failed.connect(func(error: String) -> void: failures.append(error))
	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.inject_open()
	transport.buffered_amount = 512
	_assert_equal(512, transport.get_buffered_amount(), "fake buffered amount")
	transport.inject_failure("boom")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake failure state")
	_assert_equal("boom", failures[1], "fake injected failure")
	_assert_equal(0, transport.get_buffered_amount(), "fake terminal buffered amount")
	_done()


func _test_fake_fail_on_connect_close_does_not_emit_closed() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
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
	_done()


func _test_fake_inject_failure_close_does_not_emit_closed() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.inject_failure("boom")
	transport.close()

	_assert_equal(["failed"], terminal_events, "fake injected failure terminal ordering")
	_done()


func _test_fake_connecting_close_fails_without_closed() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	var terminal_events: Array = []
	var failures: Array = []
	transport.failed.connect(
		func(error: String) -> void:
			terminal_events.append("failed")
			failures.append(error)
	)
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport.close()
	_assert_equal([], terminal_events, "fake idle close does not emit terminal event")
	_assert_equal(OK, transport.connect_to_url("ws://example.test/socket"), "fake connect")
	transport.close(1000, "abort")

	_assert_equal(["failed"], terminal_events, "fake connecting close terminal ordering")
	var connecting_failure: String = failures[0]
	_assert_string_contains(
		connecting_failure, "abort", "fake connecting close surfaces caller reason"
	)
	_assert_equal(
		WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "fake connecting close state"
	)
	_done()


func _test_fake_reconnect_clears_sent_history() -> void:
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	_assert_equal(OK, transport.connect_to_url("ws://example.test/one"), "fake first connect")
	transport.inject_open()
	transport.send_text("first session")
	transport.send_binary(PackedByteArray([9]))
	_assert_equal(1, transport.sent_text.size(), "fake first session sent text")
	_assert_equal(1, transport.sent_binary.size(), "fake first session sent binary")

	_assert_equal(OK, transport.connect_to_url("ws://example.test/two"), "fake second connect")
	_assert_equal([], transport.sent_text, "fake reconnect clears sent text")
	_assert_equal([], transport.sent_binary, "fake reconnect clears sent binary")

	transport.fail_on_connect = true
	_assert_equal(
		ERR_CANT_CONNECT, transport.connect_to_url("ws://example.test/three"), "fake fail"
	)
	transport.fail_on_connect = false
	_assert_equal([], transport.sent_text, "fake failed connect clears sent text")
	_done()


func _test_fake_terminal_sessions_do_not_reopen_or_emit_packets() -> void:
	var failed_transport: SFFakeTransportScript = SFFakeTransportScript.new()
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

	var closed_transport: SFFakeTransportScript = SFFakeTransportScript.new()
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
	_done()


func _test_websocket_invalid_scheme_and_send_error_without_network() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var failures: Array = []
	transport.failed.connect(func(error: String) -> void: failures.append(error))
	var token := "sf_token_secret_123"

	_assert_equal(
		ERR_INVALID_PARAMETER,
		transport.connect_to_url("http://example.test/socket?access_token=%s" % token),
		"websocket invalid scheme"
	)
	_assert_equal(1, failures.size(), "websocket invalid scheme failure count")
	var scheme_failure: String = failures[0]
	_assert_string_contains(
		scheme_failure, "invalid WebSocket URL scheme", "invalid scheme message"
	)
	_assert_string_not_contains(scheme_failure, token, "invalid scheme message redacts query token")
	_assert_equal(WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "invalid scheme state")
	_assert_equal(0, transport.get_buffered_amount(), "invalid scheme buffered amount")

	_assert_equal(ERR_UNCONFIGURED, transport.send_text("not open"), "websocket send text not open")
	_assert_equal(
		ERR_UNCONFIGURED,
		transport.send_binary(PackedByteArray([1])),
		"websocket send binary not open"
	)
	_assert_equal(1, failures.size(), "websocket invalid scheme is terminal once")
	_done()


func _test_websocket_never_opened_closed_emits_failed_without_closed() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var terminal_events: Array = []
	transport.failed.connect(func(_error: String) -> void: terminal_events.append("failed"))
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	transport._peer = peer
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
	transport.close()
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "never-opened terminal signal ordering")
	_done()


func _test_websocket_case_insensitive_scheme_validation() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()

	_assert(transport._is_valid_websocket_url("WS://example.test/socket"), "uppercase ws scheme")
	_assert(transport._is_valid_websocket_url("WSS://example.test/socket"), "uppercase wss scheme")
	_assert(transport._is_valid_websocket_url("wSs://example.test/socket"), "mixed wss scheme")
	_assert(not transport._is_valid_websocket_url("HTTP://example.test/socket"), "invalid scheme")
	_done()


func _test_websocket_connect_resets_close_active_peer() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
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
	_done()


func _test_websocket_connecting_close_fails_without_closed() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_CONNECTING
	transport._peer = peer
	var terminal_events: Array = []
	var failures: Array = []
	transport.failed.connect(
		func(error: String) -> void:
			terminal_events.append("failed")
			failures.append(error)
	)
	transport.closed.connect(
		func(_code: int, _reason: String) -> void: terminal_events.append("closed")
	)

	transport.close(1000, "abort")
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)

	_assert_equal(["failed"], terminal_events, "websocket connecting close terminal ordering")
	var connecting_failure: String = failures[0]
	_assert_string_contains(
		connecting_failure, "abort", "websocket connecting close surfaces reason"
	)
	_assert_equal([[1000, "abort"]], peer.close_calls, "websocket connecting close closes peer")
	_assert_equal(
		WebSocketPeer.STATE_CLOSED, transport.get_ready_state(), "websocket connecting close state"
	)
	_done()


func _test_websocket_connecting_close_surfaces_caller_reason() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	peer.ready_state = WebSocketPeer.STATE_CONNECTING
	transport._peer = peer
	var failures: Array = []
	transport.failed.connect(func(error: String) -> void: failures.append(error))

	transport.close(4321, "custom abort")

	_assert_equal(1, failures.size(), "websocket custom abort failure count")
	var abort_failure: String = failures[0]
	_assert_string_contains(abort_failure, "custom abort", "websocket custom abort reason")
	_assert_equal([[4321, "custom abort"]], peer.close_calls, "websocket custom abort close args")

	var retry_transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var retry_peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	retry_peer.ready_state = WebSocketPeer.STATE_CONNECTING
	retry_transport._peer = retry_peer
	retry_transport.failed.connect(func(error: String) -> void: failures.append(error))
	retry_transport.close(4321)
	var code_only_failure: String = failures[1]
	_assert_string_contains(
		code_only_failure, "close code 4321", "websocket abort code-only message"
	)
	_assert_equal([[4321, ""]], retry_peer.close_calls, "websocket code-only close args")
	_done()


func _test_websocket_read_error_is_terminal_once() -> void:
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
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
	_done()


func _test_websocket_closed_state_delivers_queued_packets() -> void:
	# Issue #70: packets queued at STATE_CLOSED must surface before `closed`.
	# The scripted peer models the web peer, which keeps messages received
	# before the close event queued; native wslay drops them engine-side, so
	# this drain is the only recovery a transport can offer.
	# Cases: [label, queued packets, per-poll cap, expected packets after
	# poll 1, expected events after poll 1, expected packets after poll 2,
	# expected events after poll 2].
	var message := "kicked".to_utf8_buffer()
	var second := "last".to_utf8_buffer()
	var cases := [
		[
			"drains within the cap in one poll",
			[message],
			64,
			1,
			["opened", ["closed", 1000, "gone"]],
			null,
			null
		],
		[
			"defers close while the cap leaves packets queued",
			[message, second],
			1,
			1,
			["opened"],
			2,
			["opened", ["closed", 1000, "gone"]]
		],
	]
	for case: Array in cases:
		var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
		var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
		transport._peer = peer
		transport.max_packets_per_poll = case[2]
		var events: Array = []
		var packets: Array = []
		transport.opened.connect(func() -> void: events.append("opened"))
		transport.failed.connect(func(_error: String) -> void: events.append("failed"))
		transport.closed.connect(
			func(code: int, reason: String) -> void: events.append(["closed", code, reason])
		)
		transport.packet_received.connect(
			func(_payload: PackedByteArray, _is_text: bool) -> void: packets.append("packet")
		)

		peer.ready_state = WebSocketPeer.STATE_OPEN
		transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
		peer.ready_state = WebSocketPeer.STATE_CLOSED
		peer.close_code = 1000
		peer.close_reason = "gone"
		var queued: Array = case[1]
		peer.packets = queued.duplicate()
		transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
		_assert_equal(case[3], packets.size(), "%s: packets after poll 1" % case[0])
		_assert_equal(case[4], events, "%s: events after poll 1" % case[0])
		if case[5] != null:
			transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
			_assert_equal(case[5], packets.size(), "%s: packets after poll 2" % case[0])
			_assert_equal(case[6], events, "%s: events after poll 2" % case[0])
	# A read error on a packet queued at CLOSED fails the session instead of
	# emitting `closed` — the failure wins, mirroring the OPEN-state path.
	var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	transport._peer = peer
	var events: Array = []
	var packets: Array = []
	transport.failed.connect(func(_error: String) -> void: events.append("failed"))
	transport.closed.connect(func(_code: int, _reason: String) -> void: events.append("closed"))
	transport.packet_received.connect(
		func(_payload: PackedByteArray, _is_text: bool) -> void: packets.append("packet")
	)
	peer.ready_state = WebSocketPeer.STATE_OPEN
	transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	peer.packets = [PackedByteArray([1])]
	peer.packet_errors = [ERR_FILE_CORRUPT]
	transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
	_assert_equal(["failed"], events, "read error at closed is terminal once")
	_assert_equal([], packets, "read error at closed suppresses the packet")

	# A synchronous redial from a packet handler during the CLOSED drain must
	# not fail the fresh dial with the old session's close (review finding).
	var redial_transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	_redial_transport = redial_transport
	var redial_peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	redial_transport._peer = redial_peer
	var redial_events: Array = []
	redial_transport.opened.connect(func() -> void: redial_events.append("opened"))
	redial_transport.failed.connect(func(_error: String) -> void: redial_events.append("failed"))
	redial_transport.closed.connect(
		func(_code: int, _reason: String) -> void: redial_events.append("closed")
	)
	redial_transport.packet_received.connect(_redial_packet_handler)
	redial_peer.ready_state = WebSocketPeer.STATE_OPEN
	redial_transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
	redial_peer.ready_state = WebSocketPeer.STATE_CLOSED
	redial_peer.packets = [PackedByteArray([1])]
	redial_transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
	_assert_equal(["opened"], redial_events, "redial mid-drain survives the old session")
	_assert_equal(
		WebSocketPeer.STATE_CONNECTING, redial_transport.get_ready_state(), "redial state intact"
	)
	_done()


func _redial_packet_handler(_payload: PackedByteArray, _is_text: bool) -> void:
	# Mimics connect_to_url's session swap synchronously from the packet path.
	var fresh: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	fresh.ready_state = WebSocketPeer.STATE_CONNECTING
	_redial_transport._peer = fresh
	_redial_transport._reset_session_flags()


## Issue #101: an explicit close() at STATE_CLOSED must honor the same
## issue-#70 drain contract as the poll path instead of dropping the queue.
func _test_close_at_closed_drains_queued_packets() -> void:
	var message := "kicked".to_utf8_buffer()
	var second := "last".to_utf8_buffer()
	# Cases: [label, queued packets, per-poll cap, expected packets after
	# close, expected events after close].
	var cases := [
		[
			"close drains queued packets before closed",
			[message],
			64,
			1,
			["opened", ["closed", 1000, "gone"]],
		],
		[
			"close defers closed while the cap leaves packets queued",
			[message, second],
			1,
			1,
			["opened"],
		],
	]
	for case: Array in cases:
		var transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
		var peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
		transport._peer = peer
		transport.max_packets_per_poll = case[2]
		var events: Array = []
		var packets: Array = []
		transport.opened.connect(func() -> void: events.append("opened"))
		transport.failed.connect(func(_error: String) -> void: events.append("failed"))
		transport.closed.connect(
			func(code: int, reason: String) -> void: events.append(["closed", code, reason])
		)
		transport.packet_received.connect(
			func(_payload: PackedByteArray, _is_text: bool) -> void: packets.append("packet")
		)
		peer.ready_state = WebSocketPeer.STATE_OPEN
		transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
		peer.ready_state = WebSocketPeer.STATE_CLOSED
		peer.close_code = 1000
		peer.close_reason = "gone"
		var queued: Array = case[1]
		peer.packets = queued.duplicate()
		transport.close(1000, "consumer")
		_assert_equal(case[3], packets.size(), "%s: packets after close" % case[0])
		_assert_equal(case[4], events, "%s: events after close" % case[0])
		if events.has(["closed", 1000, "gone"]):
			continue
		# The deferred remainder resurfaces on the consumer's next poll.
		transport._handle_polled_state(WebSocketPeer.STATE_CLOSED)
		_assert_equal(2, packets.size(), "%s: packets after follow-up poll" % case[0])
		_assert_equal(
			["opened", ["closed", 1000, "gone"]],
			events,
			"%s: events after follow-up poll" % case[0]
		)
	# A read error during the close-drain fails the session instead of
	# emitting `closed` — the shared drain mirrors the poll path.
	var error_transport: SFWebSocketTransportScript = SFWebSocketTransportScript.new()
	var error_peer: TestWebSocketPeerAdapterScript = TestWebSocketPeerAdapterScript.new()
	error_transport._peer = error_peer
	var error_events: Array = []
	error_transport.failed.connect(func(_error: String) -> void: error_events.append("failed"))
	error_transport.closed.connect(
		func(_code: int, _reason: String) -> void: error_events.append("closed")
	)
	error_peer.ready_state = WebSocketPeer.STATE_OPEN
	error_transport._handle_polled_state(WebSocketPeer.STATE_OPEN)
	error_peer.ready_state = WebSocketPeer.STATE_CLOSED
	error_peer.packets = [PackedByteArray([1])]
	error_peer.packet_errors = [ERR_FILE_CORRUPT]
	error_transport.close(1000, "consumer")
	_assert_equal(["failed"], error_events, "read error during close-drain is terminal once")
	_done()


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
