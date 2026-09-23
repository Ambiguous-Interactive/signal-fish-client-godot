extends RefCounted

## Off-contract server frames must never forge client session state: the
## in-room states are reachable only through the RoomJoined/Reconnected
## baselines, because a forged state defeats the pre-auth/room send guards
## (issue #100). Receives the client runner so config/transport fakes stay in
## one place.

const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

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
		_test_roomless_lobby_state_change_is_inert,
		_test_cross_flow_left_events_are_inert,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## A LobbyStateChanged without a room baseline stays informational: emitted,
## but the lobby cache and the session state are untouched.
func _test_roomless_lobby_state_change_is_inert() -> void:
	var lobby_frame := {
		"type": "LobbyStateChanged",
		"data": {"lobby_state": "finalized", "ready_players": [], "all_ready": false}
	}
	var pre_auth := _connected_client()
	var pre_auth_fake: SFFakeTransportScript = pre_auth.transport
	var pre_auth_events: Array = []
	pre_auth.lobby_state_changed.connect(
		func(state: int, _players: PackedStringArray, _all_ready: bool) -> void:
			pre_auth_events.append(state)
	)
	pre_auth_fake.inject_server_message(lobby_frame)
	_assert_equal([SFTypesScript.LobbyState.FINALIZED], pre_auth_events, "frame still emitted")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATING,
		pre_auth.get_session_state(),
		"pre-auth session state untouched"
	)
	_assert_equal(false, pre_auth.is_authenticated(), "is_authenticated stays false pre-auth")
	_assert_equal(ERR_UNAUTHORIZED, pre_auth.ping(), "pre-auth send guard intact")
	_assert_equal(SFTypesScript.LobbyState.UNKNOWN, pre_auth.get_lobby_state(), "cache untouched")
	pre_auth.free()

	var authenticated := _authenticated_client()
	var authenticated_fake: SFFakeTransportScript = authenticated.transport
	authenticated_fake.inject_server_message(lobby_frame)
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		authenticated.get_session_state(),
		"roomless frame cannot forge an in-room state"
	)
	_assert_equal(
		SFTypesScript.LobbyState.UNKNOWN, authenticated.get_lobby_state(), "cache untouched"
	)
	authenticated.free()
	_done()


## Issue #106: a `RoomLeft` for a spectating session and a `SpectatorLeft`
## for a player-in-room session are off-contract. They must stay emitted but
## inert: no roster/id wipe, no session flip, and above all no erasure of the
## retained reconnection identity.
func _test_cross_flow_left_events_are_inert() -> void:
	var spectator_left_frame := {
		"type": "SpectatorLeft",
		"data":
		{
			"room_id": "20000000-0000-0000-0000-000000000009",
			"room_code": "SPEC1",
			"reason": "voluntary_leave",
			"current_spectators": []
		}
	}
	var in_room := _in_room_client()
	var in_room_fake: SFFakeTransportScript = in_room.transport
	var in_room_left_events: Array = []
	in_room.spectator_left.connect(
		func(_room_id: String, _room_code: String, _reason: int, _current: Array) -> void:
			in_room_left_events.append(1)
	)
	in_room_fake.inject_server_message(spectator_left_frame)
	_assert_equal([1], in_room_left_events, "cross-flow frame still emitted")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_WAITING,
		in_room.get_session_state(),
		"player session state untouched"
	)
	_assert_equal(_room_fixture_id(), in_room.get_room_id(), "room baseline untouched")
	_assert_equal(_room_fixture_player(), in_room.get_player_id(), "player id untouched")
	_assert_equal(
		_room_fixture_token(), in_room._context_auth_token, "reconnection identity retained"
	)
	in_room.free()

	var room_left_frame := {"type": "RoomLeft"}
	var spectating := _spectating_client()
	var spectating_fake: SFFakeTransportScript = spectating.transport
	var spectator_left_events: Array = []
	spectating.room_left.connect(func() -> void: spectator_left_events.append(1))
	spectating_fake.inject_server_message(room_left_frame)
	_assert_equal([1], spectator_left_events, "cross-flow frame still emitted")
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING,
		spectating.get_session_state(),
		"spectator session state untouched"
	)
	_assert_equal("SPEC1", spectating.get_room_code(), "spectator baseline untouched")
	_assert_equal(1, spectating.get_players().size(), "spectator roster untouched")
	spectating.free()
	_done()


func _connected_client() -> SignalFishClientScript:
	var client: SignalFishClientScript = _runner.call(
		"_connect_new_client", _runner.call("_make_config")
	)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	return client


func _authenticated_client() -> SignalFishClientScript:
	var client := _connected_client()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message(
		{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
	)
	return client


func _in_room_client() -> SignalFishClientScript:
	var client := _authenticated_client()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message(
		{
			"type": "RoomJoined",
			"data": _runner.call("_room_joined_data", {"reconnection_token": _room_fixture_token()})
		}
	)
	return client


func _spectating_client() -> SignalFishClientScript:
	var client := _authenticated_client()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "SpectatorJoined", "data": _spectator_joined_data()})
	return client


func _spectator_joined_data() -> Dictionary:
	return {
		"room_id": "20000000-0000-0000-0000-000000000009",
		"room_code": "SPEC1",
		"spectator_id": "30000000-0000-0000-0000-000000000003",
		"game_name": "reef-rally",
		"current_players": [_runner.call("_player", _room_fixture_player(), "Alice")],
		"current_spectators": [],
		"lobby_state": "waiting"
	}


func _room_fixture_id() -> String:
	return "20000000-0000-0000-0000-000000000001"


func _room_fixture_player() -> String:
	return "10000000-0000-0000-0000-000000000001"


func _room_fixture_token() -> String:
	return "test-reconnect-token-not-secret"


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected == actual:
		return true
	_failures.append("%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)])
	return false
