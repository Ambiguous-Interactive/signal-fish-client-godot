extends RefCounted

const Events = preload("res://addons/signal_fish/protocol/sf_events.gd")
const TypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const Types = preload("res://addons/signal_fish/protocol/sf_types.gd")
const Client = preload("res://addons/signal_fish/signal_fish_client.gd")
const Fake = preload("res://tests/transport/sf_fake_transport.gd")
const Fixtures = preload("res://tests/client/client_fixtures.gd")
const Guard = preload("res://tests/completion_guard.gd")

var _runner: Object
var _failures: Array[String] = []
var _test_done := false


static func run(runner: Object) -> Array[String]:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_metadata_validation,
		_test_restore_before_callback_and_duplicate_fences,
		_test_legacy_and_room_boundaries,
		_test_replay_preserves_authoritative_baseline,
		_test_reconnect_roster_cap,
	]
	Guard.drive(self, cases, _failures)
	Guard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _frame(epoch: int) -> Dictionary:
	var player := Fixtures.player(Fixtures.PLAYER_B, "Current Bob")
	player["is_ready"] = true
	player["is_authority"] = true
	var data := {"player_id": Fixtures.PLAYER_B, "player": player}
	if epoch >= 0:
		data["epoch"] = epoch
		player["epoch"] = epoch
		player["seq"] = 0
	return {"type": "PlayerReconnected", "data": data}


func _inject(client: Client, frame: Dictionary) -> void:
	var fake: Fake = client.transport
	fake.inject_server_message(frame)


func _test_metadata_validation() -> void:
	for epoch: int in [-1, 0, 4]:
		var good := _frame(epoch)
		_assert(Events.decode_envelope(good).signal_name == &"player_reconnected", "valid metadata")
		for value: Variant in [null, false, "bad", {}, {"id": Fixtures.PLAYER_B}]:
			var frame := good.duplicate(true)
			frame["data"]["player"] = value
			_assert(
				(
					(Events.decode_envelope(frame).signal_name == &"player_reconnected")
					== (value == null)
				),
				"optional metadata accepts null and rejects malformed values"
			)
		for change: Dictionary in [
			{"id": Fixtures.PLAYER_A},
			{"epoch": 9},
			{"seq": 2},
			{"is_ready": "true"},
			{"is_authority": null},
		]:
			var frame := good.duplicate(true)
			var metadata: Dictionary = frame["data"]["player"]
			metadata.merge(change, true)
			_assert(
				Events.decode_envelope(frame).signal_name == &"protocol_error",
				"mismatched metadata"
			)
	for epoch: Variant in [-1, 0.5, 4294967296, "2", true]:
		var frame := _frame(2)
		frame["data"]["epoch"] = epoch
		_assert(
			Events.decode_envelope(frame).signal_name == &"protocol_error", "invalid outer epoch"
		)
	_done()


func _test_restore_before_callback_and_duplicate_fences() -> void:
	for spectator: bool in [false, true]:
		for epoch: int in [-1, 4]:
			var client: Client = _runner.call("_make_in_room_client")
			if spectator:
				_inject(
					client, {"type": "SpectatorJoined", "data": Fixtures.spectator_joined_data()}
				)
			var state := client.get_session_state()
			var callbacks: Array[String] = []
			client.player_joined.connect(
				func(_player: Types.PlayerInfo) -> void: callbacks.append("joined")
			)
			client.player_reconnected.connect(
				func(id: String) -> void:
					var callback_players := client.get_players()
					_assert(callback_players.size() == 2, "full roster before callback")
					var callback_player: Types.PlayerInfo = callback_players[
						callback_players.size() - 1
					]
					_assert(
						callback_player.id == id and callback_player.name == "Current Bob",
						"current identity before callback"
					)
					_assert(
						callback_player.is_ready and callback_player.is_authority,
						"current flags before callback"
					)
					callbacks.append(id)
			)
			var frame := _frame(epoch)
			_inject(client, frame)
			_assert(callbacks == [Fixtures.PLAYER_B], "one reconnect and no synthetic join")
			_inject(
				client,
				{
					"type": "AuthorityChanged",
					"data": {"authority_player": Fixtures.PLAYER_A, "you_are_authority": true}
				}
			)
			_inject(
				client,
				{
					"type": "LobbyStateChanged",
					"data": {"lobby_state": "waiting", "ready_players": [], "all_ready": false}
				}
			)
			_inject(client, frame)
			if epoch >= 0:
				_inject(client, _frame(epoch - 1))
			_assert(callbacks.size() == 1, "duplicate and stale reconnect stay silent")
			var players := client.get_players()
			var player: Types.PlayerInfo = players[players.size() - 1]
			_assert(
				not player.is_ready and not player.is_authority, "duplicate preserves newer flags"
			)
			if spectator:
				_assert(client.get_session_state() == state, "spectator role survives")
			_inject(client, {"type": "PlayerLeft", "data": {"player_id": Fixtures.PLAYER_B}})
			_inject(client, _frame(epoch + 1 if epoch >= 0 else -1))
			_assert(callbacks.size() == 2, "next disconnect and reconnect restores again")
			client.free()
	_done()


func _test_legacy_and_room_boundaries() -> void:
	var client: Client = _runner.call("_make_in_room_client")
	var frame := _frame(2)
	var legacy_data: Dictionary = frame["data"]
	legacy_data.erase("player")
	_inject(client, frame)
	_assert(client.get_players().size() == 1, "legacy frame invents no metadata")
	_inject(client, _frame(2))
	_assert(client.get_players().size() == 2, "later metadata can restore missing peer")
	_inject(client, {"type": "PlayerLeft", "data": {"player_id": Fixtures.PLAYER_B}})
	_assert(client.get_players().size() == 1, "terminal leave removes peer")
	_inject(client, {"type": "RoomLeft"})
	_inject(client, _frame(3))
	_assert(client.get_players().is_empty(), "roomless metadata cannot resurrect peer")
	_inject(client, {"type": "RoomJoined", "data": Fixtures.room_joined_data()})
	_inject(client, _frame(2))
	_assert(client.get_players().size() == 2, "fresh baseline clears reconnect latches")
	client.free()
	_done()


func _test_replay_preserves_authoritative_baseline() -> void:
	var client: Client = _runner.call("_make_in_room_client")
	client.close()
	client.transport = Fake.new()
	_assert(
		client.reconnect(Fixtures.PLAYER_A, Fixtures.ROOM_ID, "fixture-only") == OK,
		"reconnect starts"
	)
	var fake: Fake = client.transport
	fake.inject_open()
	_inject(client, {"type": "Authenticated", "data": Fixtures.authenticated_data()})
	var current := Fixtures.player(Fixtures.PLAYER_B, "Baseline Bob")
	current["epoch"] = 8
	current["seq"] = 7
	var data := Fixtures.room_joined_data(
		{"current_players": [current], "missed_events": [_frame(3)]}
	)
	var events: Array[Types.DecodedEvent] = []
	client.reconnected.connect(
		func(_info: Types.RoomJoinedInfo, missed: Array[Types.DecodedEvent]) -> void:
			events.append_array(missed)
	)
	_inject(client, {"type": "Reconnected", "data": data})
	_assert(events.size() == 1, "metadata replay remains available to consumer")
	_assert(client.get_players()[0].name == "Baseline Bob", "replay cannot overwrite baseline")
	_inject(client, _frame(3))
	_assert(client.get_players()[0].name == "Baseline Bob", "old epoch cannot overwrite baseline")
	client.free()
	_done()


func _test_reconnect_roster_cap() -> void:
	var client: Client = _runner.call("_make_in_room_client")
	var members: Array = []
	for index: int in TypeUtils.MAX_TRACKED_PEERS:
		members.append(Fixtures.player("000000aa-0000-0000-0000-%012d" % index, "Member"))
	_inject(
		client,
		{"type": "RoomJoined", "data": Fixtures.room_joined_data({"current_players": members})}
	)
	_inject(client, _frame(2))
	_assert(
		client.get_players().size() == TypeUtils.MAX_TRACKED_PEERS, "reconnect respects roster cap"
	)
	_inject(client, {"type": "PlayerLeft", "data": {"player_id": members[0]["id"]}})
	_inject(client, _frame(2))
	var players := client.get_players()
	_assert(players.size() == TypeUtils.MAX_TRACKED_PEERS, "freed roster slot accepts reconnect")
	_assert(players[players.size() - 1].id == Fixtures.PLAYER_B, "refused reconnect can retry")
	client.free()
	_done()
