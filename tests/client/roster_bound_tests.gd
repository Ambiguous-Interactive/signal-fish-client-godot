extends RefCounted

## Roster bound tests (issue #274). A hostile relay streaming distinct joins
## must not grow session state without a bound; receives the client runner
## instance so connect/auth fakes stay defined in one place.

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"

var _failures: Array[String] = []
var _test_done := false
var _runner: Object = null


func _done() -> void:
	_test_done = true


static func run(runner: Object) -> Array[String]:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_over_cap_baseline_clamps,
		_test_roster_growth_stays_bounded,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## Issue #274: precedent `MAX_MISSED_EVENTS` — cap plus one diagnostic per
## refused event. Data-driven across both rosters: baselines clamp to the
## cap, refused joins stay untracked, and a freed slot accepts again.


func _test_over_cap_baseline_clamps() -> void:
	var cap := SFTypeUtils.MAX_TRACKED_PEERS
	for flow: String in ["players", "spectators"]:
		var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
		var errors: Array[String] = _runner.call("_track_protocol_errors", client)
		var members: Array = []
		for index: int in cap + 1:
			members.append(_bulk_roster_member(flow, index))
		_inject_roster_baseline(client, flow, members)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s baseline clamps to the cap" % flow)
		_assert_equal(1, errors.size(), "%s clamped baseline emits one diagnostic" % flow)
		_assert_string_contains(errors[0], "dropped 1", "%s diagnostic counts the drop" % flow)
		client.free()
	_done()


func _test_roster_growth_stays_bounded() -> void:
	var cap := SFTypeUtils.MAX_TRACKED_PEERS
	for flow: String in ["players", "spectators"]:
		var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
		var fake: SFFakeTransportScript = client.transport
		var errors: Array[String] = _runner.call("_track_protocol_errors", client)
		var joins: Array[String] = []
		if flow == "players":
			client.player_joined.connect(
				func(player: SFTypesScript.PlayerInfo) -> void: joins.append(player.id)
			)
		else:
			client.new_spectator_joined.connect(
				func(spectator: SFTypesScript.SpectatorInfo, _current: Array, _reason: int) -> void:
					joins.append(spectator.id)
			)

		var members: Array = []
		for index: int in cap:
			members.append(_bulk_roster_member(flow, index))
		_inject_roster_baseline(client, flow, members)
		_assert_equal(
			cap, _roster_of(client, flow).size(), "%s baseline installs the full roster" % flow
		)
		_assert_equal(0, errors.size(), "%s baseline at the cap stays silent" % flow)

		var stranger_id: String = _bulk_roster_member(flow, cap)["id"]
		var zero_id: String = _bulk_roster_member(flow, 0)["id"]

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(stranger_id, "Stranger")}}
			)
		else:
			fake.inject_server_message(
				{
					"type": "NewSpectatorJoined",
					"data": {"spectator": _spectator(stranger_id, "Stranger")}
				}
			)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s roster stays at the cap" % flow)
		_assert_equal(1, errors.size(), "%s over-cap join emits one diagnostic" % flow)
		_assert_string_contains(errors[0], "cap %d" % cap, "%s diagnostic names the cap" % flow)
		_assert_equal([stranger_id], joins, "%s refused join still surfaces" % flow)

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(zero_id, "Fresh")}}
			)
		else:
			fake.inject_server_message(
				{"type": "NewSpectatorJoined", "data": {"spectator": _spectator(zero_id, "Fresh")}}
			)
		_assert_equal(
			cap, _roster_of(client, flow).size(), "%s upsert at the cap adds no entry" % flow
		)
		_assert_equal(1, errors.size(), "%s known-id join stays silent" % flow)
		_assert_equal(
			"Fresh", _roster_of(client, flow)[0].name, "%s known-id join updates in place" % flow
		)

		if flow == "players":
			fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": zero_id}})
		else:
			fake.inject_server_message(
				{"type": "SpectatorDisconnected", "data": {"spectator_id": zero_id}}
			)
		_assert_equal(cap - 1, _roster_of(client, flow).size(), "%s leave frees a slot" % flow)
		_assert_equal(1, errors.size(), "%s leave stays silent" % flow)

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(stranger_id, "Back")}}
			)
		else:
			fake.inject_server_message(
				{
					"type": "NewSpectatorJoined",
					"data": {"spectator": _spectator(stranger_id, "Back")}
				}
			)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s freed slot accepts the join" % flow)
		_assert_equal(1, errors.size(), "%s accepted join stays silent" % flow)
		_assert_equal(
			stranger_id, _roster_of(client, flow)[cap - 1].id, "%s join lands at the tail" % flow
		)
		_assert_equal(
			[stranger_id, zero_id, stranger_id], joins, "%s join events all surface" % flow
		)
		client.free()
	_done()


func _inject_roster_baseline(client: SignalFishClientScript, flow: String, members: Array) -> void:
	var fake: SFFakeTransportScript = client.transport
	if flow == "players":
		var baseline: Dictionary = _runner.call("_room_joined_data", {"current_players": members})
		fake.inject_server_message({"type": "RoomJoined", "data": baseline})
		return
	fake.inject_server_message(
		{
			"type": "SpectatorJoined",
			"data":
			{
				"room_id": "20000000-0000-0000-0000-000000000009",
				"room_code": "SPEC1",
				"spectator_id": PLAYER_B,
				"game_name": "reef-rally",
				"current_players": [],
				"current_spectators": members,
				"lobby_state": "waiting"
			}
		}
	)


func _roster_of(client: SignalFishClientScript, flow: String) -> Array:
	if flow == "players":
		return client.get_players()
	return client.get_spectators()


func _bulk_roster_member(flow: String, index: int) -> Dictionary:
	var id := "000000aa-0000-0000-0000-%012d" % index
	return _player(id, "P%04d" % index) if flow == "players" else _spectator(id, "P%04d" % index)


func _player(id: String, display_name: String) -> Dictionary:
	return _runner.call("_player", id, display_name)


func _spectator(id: String, display_name: String) -> Dictionary:
	return _runner.call("_spectator", id, display_name)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	return _runner.call("_assert_equal", expected, actual, label)


func _assert_string_contains(actual: String, expected_substring: String, label: String) -> bool:
	return _runner.call("_assert_string_contains", actual, expected_substring, label)
