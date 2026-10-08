extends RefCounted

## Off-contract server frames must never forge client session state: the
## in-room states are reachable only through the RoomJoined/Reconnected
## baselines, because a forged state defeats the pre-auth/room send guards
## (issue #100). Receives the client runner so config/transport fakes stay in
## one place.

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

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
		_test_roomless_lobby_state_change_is_inert,
		_test_cross_flow_left_events_are_inert,
		_test_pre_auth_baselines_are_refused,
		_test_mid_session_authentication_error_clears_room_state,
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
	var pre_auth_events: Array[int] = []
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
	var in_room_left_events: Array[int] = []
	in_room.spectator_left.connect(
		func(
			_room_id: String,
			_room_code: String,
			_reason: int,
			_current: Array[SFTypesScript.SpectatorInfo]
		) -> void:
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
	var spectator_left_events: Array[int] = []
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


## Issue #340: a baseline that precedes this dial's `Authenticated` is
## hostile input forging in-room state (the #100 class). Upstream only ever
## sends a baseline after `Authenticated` on a legitimate dial (fresh join
## and reconnect alike), so the refusal is safe: it must be loud
## (protocol_error), apply no room state, retain no reconnection identity,
## keep the join signal silent, and leave the send guard closed.
func _test_pre_auth_baselines_are_refused() -> void:
	var cases := [
		[
			"RoomJoined",
			{
				"type": "RoomJoined",
				"data":
				_runner.call("_room_joined_data", {"reconnection_token": _room_fixture_token()})
			},
			"room_joined",
		],
		[
			"SpectatorJoined",
			{"type": "SpectatorJoined", "data": _spectator_joined_data()},
			"spectator_joined",
		],
	]
	for case: Array in cases:
		var event_type: String = case[0]
		var join_signal: String = case[2]
		var frame: Dictionary = case[1]
		var client := _connected_client()
		var fake: SFFakeTransportScript = client.transport
		var errors: Array[String] = []
		client.protocol_error.connect(func(error: String) -> void: errors.append(error))
		var join_events: Array[int] = []
		client.connect(join_signal, func(_info: Variant) -> void: join_events.append(1))
		fake.inject_server_message(frame)
		_assert_equal(1, errors.size(), "%s: refusal is loud" % event_type)
		_assert_string_contains(
			errors[0], "before an authenticated session", "%s: refusal explains itself" % event_type
		)
		_assert_equal([], join_events, "%s: join stays consumer-silent" % event_type)
		_assert_equal(
			SignalFishClientScript.SessionState.AUTHENTICATING,
			client.get_session_state(),
			"%s: session state untouched" % event_type
		)
		_assert_equal(false, client.is_authenticated(), "%s: stays unauthenticated" % event_type)
		_assert_equal("", client.get_room_id(), "%s: room id not forged" % event_type)
		_assert_equal("", client.get_room_code(), "%s: room code not forged" % event_type)
		_assert_equal("", client.get_player_id(), "%s: player id not forged" % event_type)
		_assert_equal([], client.get_players(), "%s: player roster not forged" % event_type)
		_assert_equal([], client.get_spectators(), "%s: spectator roster not forged" % event_type)
		_assert_equal(
			SFTypesScript.LobbyState.UNKNOWN,
			client.get_lobby_state(),
			"%s: lobby cache untouched" % event_type
		)
		_assert_equal(
			"", client._context_auth_token, "%s: no reconnection identity retained" % event_type
		)
		_assert_equal(ERR_UNAUTHORIZED, client.ping(), "%s: send guard intact" % event_type)
		var errors_after_guard := errors.size()
		# Recovery: the refusal must not poison the dial. A legitimate
		# `Authenticated` followed by the same baseline applies normally.
		var expected_state: SignalFishClientScript.SessionState = (
			SignalFishClientScript.SessionState.IN_ROOM_WAITING
			if event_type == "RoomJoined"
			else SignalFishClientScript.SessionState.SPECTATING
		)
		fake.inject_server_message(
			{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
		)
		fake.inject_server_message(frame)
		_assert_equal([1], join_events, "%s: legitimate baseline applies after auth" % event_type)
		_assert_equal(
			errors_after_guard,
			errors.size(),
			"%s: no refusal for the legitimate baseline" % event_type
		)
		_assert_equal(
			expected_state,
			client.get_session_state(),
			"%s: session state follows the baseline" % event_type
		)
		client.free()
	_done()


## Issue #342: a mid-session AuthenticationError tears the room state down
## (mirroring the room_left posture). The real server closes the link after
## an auth failure, but a relay that holds the socket open must not leave
## the client reporting a room it can no longer be in.
func _test_mid_session_authentication_error_clears_room_state() -> void:
	var client := _in_room_client()
	var fake: SFFakeTransportScript = client.transport
	var auth_error_events: Array[int] = []
	client.authentication_error.connect(
		func(_message: String, _code: int) -> void: auth_error_events.append(1)
	)
	# Arm the v3 signal-plan gate first: the error must disarm it with the room.
	fake.inject_server_message(
		{
			"type": "SessionPlan",
			"data": ClientFixtures.session_plan_data("40000000-0000-0000-0000-000000000004")
		}
	)
	_assert_equal(true, client._session_plan_seen, "plan gate armed before the error")
	fake.inject_server_message(
		{
			"type": "AuthenticationError",
			"data": {"error": "session revoked", "error_code": "UNAUTHORIZED"}
		}
	)
	_assert_equal([1], auth_error_events, "authentication_error surfaces once")
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		client.get_session_state(),
		"session falls back to unauthenticated"
	)
	_assert_equal(false, client.is_authenticated(), "is_authenticated reports false")
	_assert_equal("", client.get_room_id(), "room id cleared")
	_assert_equal("", client.get_room_code(), "room code cleared")
	_assert_equal("", client.get_player_id(), "player id cleared")
	_assert_equal([], client.get_players(), "player roster cleared")
	_assert_equal([], client.get_spectators(), "spectator roster cleared")
	_assert_equal(SFTypesScript.LobbyState.UNKNOWN, client.get_lobby_state(), "lobby cache cleared")
	_assert_equal(false, client._session_plan_seen, "v3 signal-plan gate disarmed")
	_assert_equal("", client._session_plan_generation, "plan generation cleared")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTED,
		client.get_connection_state(),
		"the held-open socket keeps the link up inside the post-error silence window"
	)
	# The auth error must keep the baseline refusal armed for the rest of
	# the dial (issue #340): a hostile baseline after the error must not
	# forge state or rotate the retained reconnection identity.
	var errors: Array[String] = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	var forged: Dictionary = _runner.call(
		"_room_joined_data", {"reconnection_token": "forged-room-token-not-secret"}
	)
	fake.inject_server_message({"type": "RoomJoined", "data": forged})
	fake.inject_server_message({"type": "SpectatorJoined", "data": _spectator_joined_data()})
	_assert_equal(2, errors.size(), "both post-error baselines are refused loudly")
	_assert_string_contains(errors[0], "before an authenticated session", "room refusal message")
	_assert_string_contains(
		errors[1], "before an authenticated session", "spectator refusal message"
	)
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		client.get_session_state(),
		"post-error baselines cannot restore the session"
	)
	_assert_equal("", client.get_room_id(), "post-error baselines cannot forge the room")
	_assert_equal(
		_room_fixture_token(),
		client._context_auth_token,
		"post-error baselines cannot rotate the retained token"
	)
	client.free()
	_done()


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


func _assert_string_contains(haystack: String, needle: String, label: String) -> bool:
	if haystack.contains(needle):
		return true
	_failures.append("%s: expected %s to contain %s" % [label, haystack, needle])
	return false
