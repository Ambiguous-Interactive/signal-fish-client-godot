extends RefCounted

## Off-contract server frames must never forge client session state: the
## in-room states are reachable only through the RoomJoined/Reconnected
## baselines, because a forged state defeats the pre-auth/room send guards
## (issue #100). Receives the client runner so config/transport fakes stay in
## one place.

const PLAYER_A := ClientFixtures.PLAYER_A

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
		_test_game_starting_projects_finalized_state,
		_test_spectator_baseline_ends_player_role,
		_test_spectator_live_room_events,
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


func _test_spectator_baseline_ends_player_role() -> void:
	var client := _in_room_client()
	var fake: SFFakeTransportScript = client.transport
	fake.inject_server_message(
		{"type": "SpectatorJoined", "data": ClientFixtures.spectator_joined_data()}
	)
	_assert_equal("", client.get_player_id(), "spectator baseline clears former player id")
	_assert_equal(false, client.get_supports_authority(), "spectator has no authority slot")
	var sent_before := fake.sent_text.size()
	for row: Array in _runner.call("_send_method_cases"):
		if (
			row[0]
			not in [
				"leave_room",
				"send_game_data",
				"send_game_data_binary",
				"set_ready",
				"start_game",
				"request_authority",
				"provide_connection_info",
				"send_signal",
				"send_transport_status",
			]
		):
			continue
		var action: Callable = row[1]
		_assert_equal(ERR_UNAUTHORIZED, action.call(client), "%s refuses spectator role" % row[0])
	_assert_equal(sent_before, fake.sent_text.size(), "spectator commands send no text")
	_assert_equal([], fake.sent_binary, "spectator commands send no binary")
	_assert_equal(OK, client.ping(), "spectator can ping")
	_assert_equal(OK, client.leave_spectator(), "spectator can leave")
	fake.inject_server_message({"type": "RoomJoined", "data": ClientFixtures.room_joined_data()})
	_assert_equal(PLAYER_A, client.get_player_id(), "later player baseline restores seat")
	_assert_equal(OK, client.send_game_data({"turn": 1}), "later player can send")
	client.free()
	_done()


func _test_spectator_live_room_events() -> void:
	# Server #1139 routes public room events after the spectator baseline (#368).
	var client := _authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var events: Array[String] = []
	var errors: Array[String] = _runner.call("_track_protocol_errors", client)
	client.spectator_joined.connect(
		func(_info: SFTypesScript.SpectatorJoinedInfo) -> void:
			_assert_equal(1, client.get_players().size(), "snapshot installed before signal")
			events.append("baseline")
	)
	client.player_joined.connect(
		func(_player_info: SFTypesScript.PlayerInfo) -> void:
			_assert_equal(2, client.get_players().size(), "live roster installed before signal")
			events.append("player")
	)
	client.authority_changed.connect(
		func(authority: String, _you: bool) -> void:
			_assert_equal(
				authority, client.get_authority_player(), "authority cached before signal"
			)
			events.append("authority")
	)
	client.lobby_state_changed.connect(
		func(state: int, _ready: PackedStringArray, _all_ready: bool) -> void:
			_assert_equal(state, client.get_lobby_state(), "lobby cached before signal")
			events.append("lobby")
	)
	client.game_starting.connect(
		func(_peers: Array[SFTypesScript.PeerConnectionInfo]) -> void: events.append("starting")
	)
	client.game_data_received.connect(
		func(sender: String, data: Variant) -> void:
			_assert_equal(PLAYER_A, sender, "live sender preserved")
			_assert_equal({"turn": 7.0}, data, "live gameplay preserved")
			events.append("data")
	)
	var newcomer := "10000000-0000-0000-0000-000000000003"
	for frame: Dictionary in [
		{"type": "SpectatorJoined", "data": ClientFixtures.spectator_joined_data()},
		{"type": "PlayerJoined", "data": {"player": ClientFixtures.player(newcomer, "Carol")}},
		{
			"type": "AuthorityChanged",
			"data": {"authority_player": newcomer, "you_are_authority": false}
		},
		{
			"type": "LobbyStateChanged",
			"data":
			{"lobby_state": "finalized", "ready_players": [PLAYER_A, newcomer], "all_ready": true}
		},
		{"type": "GameStarting", "data": {"peer_connections": [ClientFixtures.peer_connection()]}},
		{"type": "GameData", "data": {"from_player": PLAYER_A, "data": {"turn": 7}}},
		{"type": "PlayerReconnected", "data": {"player_id": newcomer}},
		{"type": "PlayerLeft", "data": {"player_id": newcomer}},
	]:
		fake.inject_server_message(frame)
	_assert_equal(
		["baseline", "player", "authority", "lobby", "starting", "data"],
		events,
		"public event wire order"
	)
	_assert_equal([], errors, "live spectator events decode")
	_assert_equal(1, client.get_players().size(), "live departure updates spectator roster")
	_assert_equal("", client.get_authority_player(), "departed authority cleared")
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING,
		client.get_session_state(),
		"public lifecycle preserves spectator role"
	)
	_assert_equal(
		ERR_UNAUTHORIZED, client.send_game_data({}), "live data does not grant send permission"
	)
	client.free()
	_done()


func _test_game_starting_projects_finalized_state() -> void:
	for kind: int in 6:
		var client: SignalFishClientScript
		match kind:
			0:
				client = _connected_client()
			1:
				client = _authenticated_client()
			5:
				client = _spectating_client()
			_:
				client = _in_room_client()
		var fake: SFFakeTransportScript = client.transport
		if kind in [3, 4, 5]:
			fake.inject_server_message(
				{
					"type": "LobbyStateChanged",
					"data":
					{
						"lobby_state": "finalized" if kind == 4 else "lobby",
						"ready_players": [],
						"all_ready": true
					}
				}
			)
		var expected_state: SignalFishClientScript.SessionState = client.get_session_state()
		var expected_lobby: int = client.get_lobby_state()
		if kind >= 2:
			expected_lobby = SFTypesScript.LobbyState.FINALIZED
			if kind != 5:
				expected_state = SignalFishClientScript.SessionState.IN_ROOM_FINALIZED
		var observed: Array = []
		client.game_starting.connect(
			func(_peers: Array[SFTypesScript.PeerConnectionInfo]) -> void:
				observed.append([client.get_session_state(), client.get_lobby_state()])
		)
		for _repeat: int in 2:
			fake.inject_server_message({"type": "GameStarting", "data": {"peer_connections": []}})
		_assert_equal(
			[[expected_state, expected_lobby], [expected_state, expected_lobby]],
			observed,
			"game start projects baseline-owned state before each listener: %d" % kind
		)
		if kind == 5:
			_assert_equal(
				ERR_UNAUTHORIZED, client.send_game_data({}), "started spectator stays read-only"
			)
		client.free()
	var closing := _in_room_client()
	var closing_transport: SFFakeTransportScript = closing.transport
	closing.game_starting.connect(
		func(_peers: Array[SFTypesScript.PeerConnectionInfo]) -> void: closing.close()
	)
	closing_transport.inject_server_message(
		{"type": "GameStarting", "data": {"peer_connections": []}}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		closing.get_session_state(),
		"listener close owns final state"
	)
	_assert_equal("", closing.get_room_id(), "listener close clears room")
	closing.free()
	_done()
