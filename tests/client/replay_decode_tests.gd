extends RefCounted

## Baseline decode matrices for `RoomJoined`/`Reconnected`: reconnection
## tokens (issue #72) and the v3 `replay`/`sender_watermarks` fields (issue
## #114). Pure decode: no client wiring, no clock.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const TOKEN_V1 := "test-reconnect-token-not-secret"

var _failures: Array = []
var _test_done := false
var _runner: Object = null


func _done() -> void:
	_test_done = true


static func run(runner: Variant) -> Array:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_tokens_decode_from_baselines,
		_test_replay_statuses_decode,
		_test_watermarks_decode_and_round_trip,
		_test_hostile_shapes_fail_closed,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _test_tokens_decode_from_baselines() -> void:
	var cases := [
		["string token", TOKEN_V1, TOKEN_V1],
		["absent token", null, ""],
		["null token", "null", ""],
		["empty token", "", ""],
	]
	for case: Array in cases:
		var overrides: Dictionary = {}
		if case[1] == "null":
			overrides["reconnection_token"] = null
		elif case[1] != null:
			overrides["reconnection_token"] = case[1]
		var event := _decode_envelope("RoomJoined", overrides)
		if not _assert(event.signal_name != &"protocol_error", "%s: RoomJoined decodes" % case[0]):
			continue
		var info: SFTypesScript.RoomJoinedInfo = event.args[0]
		_assert_equal(case[2], info.reconnection_token, "%s: RoomJoined" % case[0])

	var event := _decode_envelope(
		"Reconnected",
		{"reconnection_token": TOKEN_V1, "missed_events": [{"type": "Pong"}]},
	)
	_assert_equal(TOKEN_V1, event.args[0].reconnection_token, "Reconnected carries token")
	var missed: Array = event.args[1]
	_assert_equal(1, missed.size(), "missed_events decoded")
	_done()


func _test_replay_statuses_decode() -> void:
	var cases := [
		["complete", {"replay": "complete"}, SFTypesScript.ReplayStatus.COMPLETE],
		["truncated", {"replay": "truncated"}, SFTypesScript.ReplayStatus.TRUNCATED],
		["unavailable", {"replay": "unavailable"}, SFTypesScript.ReplayStatus.UNAVAILABLE],
		["absent (v2)", {}, SFTypesScript.ReplayStatus.UNKNOWN],
		["null", {"replay": null}, SFTypesScript.ReplayStatus.UNKNOWN],
	]
	for case: Array in cases:
		var overrides: Dictionary = case[1]
		var event := _decode_reconnected(overrides)
		if not _assert(event.signal_name != &"protocol_error", "%s: Reconnected decodes" % case[0]):
			continue
		var info: SFTypesScript.RoomJoinedInfo = event.args[0]
		_assert_equal(case[2], info.replay_status, "%s: replay status" % case[0])
		_assert_equal([], info.sender_watermarks, "%s: no watermarks" % case[0])
	_done()


func _test_watermarks_decode_and_round_trip() -> void:
	var watermarks := [
		{"player_id": _player_a(), "epoch": 1, "seq": 42},
		{"player_id": _player_b(), "epoch": 2, "seq": 7},
	]
	var event := _decode_reconnected({"replay": "complete", "sender_watermarks": watermarks})
	if not _assert(event.signal_name != &"protocol_error", "watermarks: Reconnected decodes"):
		return
	var info: SFTypesScript.RoomJoinedInfo = event.args[0]
	_assert_equal(SFTypesScript.ReplayStatus.COMPLETE, info.replay_status, "watermarks: status")
	var decoded: Array = info.sender_watermarks
	var first: SFTypesScript.SenderWatermark = decoded[0]
	_assert_equal(2, decoded.size(), "watermarks decode")
	_assert_equal(_player_a(), first.player_id, "watermark player")
	_assert_equal(1, first.epoch, "watermark epoch")
	_assert_equal(42, first.seq, "watermark seq")
	# The engine's JSON round-trip float-ifies whole numbers; raw stays verbatim.
	_assert_equal(
		{"player_id": _player_a(), "epoch": 1.0, "seq": 42.0},
		first.to_dict(),
		"watermark round-trips verbatim"
	)
	_done()


func _test_hostile_shapes_fail_closed() -> void:
	var cases := [
		["unknown status token", {"replay": "later"}],
		["wrong-typed status", {"replay": 3}],
		["watermarks not an array", {"sender_watermarks": "nope"}],
		["watermark not an object", {"sender_watermarks": [_player_a()]}],
		["watermark missing player_id", {"sender_watermarks": [{"epoch": 1, "seq": 1}]}],
		[
			"watermark epoch beyond u32",
			{"sender_watermarks": [{"player_id": _player_a(), "epoch": 4294967296, "seq": 1}]},
		],
		[
			"watermark negative seq",
			{"sender_watermarks": [{"player_id": _player_a(), "epoch": 1, "seq": -1}]},
		],
	]
	for case: Array in cases:
		var overrides: Dictionary = case[1]
		var event := _decode_reconnected(overrides)
		_assert_equal(&"protocol_error", event.signal_name, "%s: fails closed" % case[0])
	_done()


func _decode_reconnected(overrides: Dictionary = {}) -> SFTypesScript.DecodedEvent:
	var data: Dictionary = _runner.call(
		"_room_joined_data", {"lobby_state": "lobby", "missed_events": [{"type": "Pong"}]}
	)
	data.merge(overrides, true)
	return SFEventsScript.decode_text(
		SFMessagesScript.encode({"type": "Reconnected", "data": data})
	)


func _decode_envelope(type_name: String, overrides: Dictionary) -> SFTypesScript.DecodedEvent:
	var data: Dictionary = _runner.call("_room_joined_data", overrides)
	return SFEventsScript.decode_text(SFMessagesScript.encode({"type": type_name, "data": data}))


func _player_a() -> String:
	return ClientFixtures.PLAYER_A


func _player_b() -> String:
	return ClientFixtures.PLAYER_B


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
