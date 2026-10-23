extends RefCounted

const ConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const Types = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SessionTypes = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const FakeTransport = preload("res://tests/transport/sf_fake_transport.gd")
const Fixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const OPERATION_ID := "30000000-0000-0000-0000-000000000001"

var _failures: Array[String] = []
var _test_done := false
var _runner: Object


class DrainTransport:
	extends "res://addons/signal_fish/transport/sf_websocket_transport.gd"
	const PeerScript = preload("res://tests/transport/test_websocket_peer_adapter.gd")
	var peer := PeerScript.new()

	# gdscript-private-helper: allow _make_peer
	func _make_peer() -> SFWebSocketPeerAdapterScript:
		return peer


func _done() -> void:
	_test_done = true


static func run(runner: Object) -> Array[String]:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_recovered_leave_and_correlated_result_before_close,
		_test_recovered_removal_preserves_player_role,
		_test_recovered_roster_notification_and_replay,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _test_recovered_leave_and_correlated_result_before_close() -> void:
	# Server #888 @ 471b6be8509e4f1397abfcd6f07609e20a75235c.
	# The injected peer retains packets at CLOSED, as the browser adapter does.
	for reason: String in ["voluntary_leave", "removed", "room_closed"]:
		var client := ClientScript.new()
		var errors: Array[String] = []
		client.protocol_error.connect(func(error: String) -> void: errors.append(error))
		var config: ConfigScript = _runner.call("_make_config")
		config.set("max_inbound_packets_per_poll", 1)
		_assert_equal(OK, client.configure(config), "detach configure")
		var transport := DrainTransport.new()
		client.transport = transport
		_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "detach connect")
		transport.peer.ready_state = WebSocketPeer.STATE_OPEN
		client.poll()
		for frame: Dictionary in [
			{"type": "Authenticated", "data": Fixtures.authenticated_data()},
			{
				"type": "RoomJoined",
				"data": Fixtures.room_joined_data({"reconnection_token": "old-test-token"})
			},
			{"type": "SpectatorJoined", "data": Fixtures.spectator_joined_data()},
		]:
			_queue(transport, frame)
			client.poll()
		var trace: Array[String] = []
		var payload := _left_data(reason)
		var terminal_roster: Array = payload["current_spectators"]
		client.room_operation_result.connect(
			func(result: SessionTypes.RoomOperationResultInfo) -> void:
				trace.append("result")
				_assert_equal(OPERATION_ID, result.operation_id, "recovered operation identity")
				_assert_equal("SpectatorLeft", result.result_type, "recovered result type")
				_assert_equal(payload, result.data, "recovered correlated payload retained")
				_assert_equal(
					ClientScript.SessionState.SPECTATING,
					client.get_session_state(),
					"correlated result stays informational"
				)
		)
		client.spectator_left.connect(
			func(
				room_id: String,
				room_code: String,
				exit_reason: int,
				current: Array[Types.SpectatorInfo]
			) -> void:
				trace.append("left")
				_assert_equal(Fixtures.ROOM_ID, room_id, "recovered leave room id")
				_assert_equal("ABC123", room_code, "recovered leave room code")
				_assert_equal(
					Types.spectator_reason_from_string(reason), exit_reason, "recovered exit reason"
				)
				_assert_equal(terminal_roster.size(), current.size(), "recovered terminal roster")
				_assert_equal("", client.get_room_id(), "room cleared before leave signal")
				_assert_equal([], client.get_players(), "player roster cleared before leave signal")
				_assert_equal(
					[], client.get_spectators(), "viewer roster cleared before leave signal"
				)
				_assert_equal("", client._context_auth_token, "spectator identity stays clear")
				_assert_equal(
					ClientScript.SessionState.AUTHENTICATED,
					client.get_session_state(),
					"leave returns to authenticated before signal"
				)
		)
		client.going_away.connect(func(_deadline: int, _retry: int) -> void: trace.append("away"))
		client.disconnected.connect(
			func(code: int, close_reason: String) -> void:
				trace.append("closed")
				_assert_equal(4000, code, "shutdown close code")
				_assert_equal("server shutdown", close_reason, "shutdown close reason")
		)
		for frame: Dictionary in [
			{
				"type": "RoomOperationResult",
				"data":
				{"operation_id": OPERATION_ID, "result": {"type": "SpectatorLeft", "data": payload}}
			},
			{"type": "SpectatorLeft", "data": payload},
			{"type": "GoingAway", "data": {"deadline_ms": 1000, "retry_after_secs": 1}},
		]:
			_queue(transport, frame)
		transport.peer.ready_state = WebSocketPeer.STATE_CLOSED
		transport.peer.close_code = 4000
		transport.peer.close_reason = "server shutdown"
		for expected: Array in [
			["result"], ["result", "left"], ["result", "left", "away", "closed"]
		]:
			client.poll()
			_assert_equal(expected, trace, "terminal queue drains in order at one frame per poll")
		client.poll()
		_assert_equal(["result", "left", "away", "closed"], trace, "terminal signals emit once")
		_assert_equal([], errors, "recovered terminal frames decode without errors")
		client.free()
	_done()


func _test_recovered_removal_preserves_player_role() -> void:
	for reason: String in ["voluntary_leave", "removed", "room_closed"]:
		var client: ClientScript = _runner.call("_make_authenticated_client")
		var fake: FakeTransport = client.transport
		fake.inject_server_message(
			{
				"type": "RoomJoined",
				"data": Fixtures.room_joined_data({"reconnection_token": "current-test-token"})
			}
		)
		var received: Array[int] = []
		client.spectator_left.connect(
			func(
				_room_id: String,
				_code: String,
				exit_reason: int,
				_current: Array[Types.SpectatorInfo]
			) -> void:
				received.append(exit_reason)
		)
		fake.inject_server_message({"type": "SpectatorLeft", "data": _left_data(reason)})
		_assert_equal(
			[Types.spectator_reason_from_string(reason)], received, "cross-flow reason surfaces"
		)
		_assert_equal(Fixtures.ROOM_ID, client.get_room_id(), "cross-flow player room retained")
		_assert_equal(Fixtures.PLAYER_A, client.get_player_id(), "cross-flow player seat retained")
		_assert_equal(
			"current-test-token", client._context_auth_token, "cross-flow identity retained"
		)
		_assert_equal(OK, client.send_game_data({"turn": 1}), "player gameplay remains available")
		client.free()
	_done()


func _test_recovered_roster_notification_and_replay() -> void:
	var client: ClientScript = _runner.call("_make_authenticated_client")
	var fake: FakeTransport = client.transport
	fake.inject_server_message({"type": "RoomJoined", "data": Fixtures.room_joined_data()})
	var live: Array[Array] = []
	client.spectator_disconnected.connect(
		func(id: String, reason: int, current: Array[Types.SpectatorInfo]) -> void:
			_assert_equal([], client.get_spectators(), "departed viewer removed before room signal")
			live.append([id, reason, current.size()])
	)
	var departure := {
		"type": "SpectatorDisconnected",
		"data": {"spectator_id": Fixtures.PLAYER_B, "reason": "removed", "current_spectators": []}
	}
	fake.inject_server_message(departure)
	_assert_equal(
		[[Fixtures.PLAYER_B, Types.SpectatorReason.REMOVED, 0]],
		live,
		"one recovered live notification"
	)
	var replayed: Array[Types.DecodedEvent] = []
	client.reconnected.connect(
		func(_info: Types.RoomJoinedInfo, missed: Array[Types.DecodedEvent]) -> void:
			replayed.append_array(missed)
			_assert_equal(
				[], client.get_spectators(), "reconnected baseline already excludes viewer"
			)
	)
	fake.inject_close(1006, "connection lost")
	fake = FakeTransport.new()
	client.transport = fake
	_assert_equal(
		OK,
		client.reconnect(Fixtures.PLAYER_A, Fixtures.ROOM_ID, "replay-test-token"),
		"replay redial"
	)
	fake.inject_open()
	fake.inject_server_message({"type": "Authenticated", "data": Fixtures.authenticated_data()})
	var baseline := Fixtures.room_joined_data(
		{"current_spectators": [], "missed_events": [departure]}
	)
	fake.inject_server_message({"type": "Reconnected", "data": baseline})
	fake.inject_server_message({"type": "Reconnected", "data": baseline})
	_assert_equal(1, live.size(), "replay does not re-emit the live notification")
	if _assert_equal(1, replayed.size(), "recovered departure replayed once"):
		_assert_equal(&"spectator_disconnected", replayed[0].signal_name, "typed replay event")
		_assert_equal(
			[Fixtures.PLAYER_B, Types.SpectatorReason.REMOVED, []],
			replayed[0].args,
			"consumer replay preserves viewer, reason and roster"
		)
	client.free()
	_done()


func _left_data(reason: String) -> Dictionary:
	return {
		"room_id": Fixtures.ROOM_ID,
		"room_code": "ABC123",
		"reason": reason,
		"current_spectators":
		[] if reason == "room_closed" else [Fixtures.spectator(Fixtures.PLAYER_A, "Other viewer")]
	}


func _queue(transport: DrainTransport, frame: Dictionary) -> void:
	transport.peer.packets.append(JSON.stringify(frame).to_utf8_buffer())
	transport.peer.packet_is_text.append(true)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected == actual:
		return true
	_failures.append("%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)])
	return false
