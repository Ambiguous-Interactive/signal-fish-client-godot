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


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected == actual:
		return true
	_failures.append("%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)])
	return false
