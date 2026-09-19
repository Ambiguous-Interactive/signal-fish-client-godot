extends SceneTree

# P2 reconnection suite (PLAN §4.4 reconnection, §4.7 auto-reconnect): manual
# `reconnect()` wire bytes and guards, server-issued reconnection_token
# capture/clear, opt-in auto-reconnect backoff with an injected clock, terminal
# reconnection codes, and attempt exhaustion. All timing is simulated through
# `_process(delta)` — no sleeps, no wall clock.

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const ROOM_ID := "20000000-0000-0000-0000-000000000001"
const TOKEN_V1 := "test-reconnect-token-not-secret"
const TOKEN_V2 := "test-reconnect-token-rotated-not-secret"

# Plan-locked backoff constants (client RECONNECT_*): attempt -> [min, max]
# expected scheduled delay with RECONNECT_JITTER_FRACTION 0.25.
const DELAY_BOUNDS := {
	1: [0.5, 0.625],
	2: [1.0, 1.25],
	3: [2.0, 2.5],
	4: [4.0, 5.0],
	5: [8.0, 10.0],
	6: [15.0, 18.75],
}

var _failures: Array = []


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("reconnect tests passed")
		quit(0)
	else:
		push_error("reconnect tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	_test_reconnection_token_decodes_from_baselines()
	_test_manual_reconnect_guards_and_wire_bytes()
	_test_manual_reconnect_completes_and_refreshes_context()
	_test_auto_reconnect_requires_context_and_not_user_close()
	_test_spectator_baseline_clears_context()
	_test_auto_reconnect_backoff_growth_bounds()
	_test_auto_reconnect_stops_on_terminal_codes()
	_test_auto_reconnect_exhaustion_emits_connection_failed()
	_test_reconnect_tokens_are_redacted()


func _test_reconnection_token_decodes_from_baselines() -> void:
	var cases := [
		["string token", TOKEN_V1, TOKEN_V1],
		["absent token", null, ""],
		["null token", "null", ""],
		["empty token", "", ""],
	]
	for case: Array in cases:
		var data := _room_joined_data()
		if case[1] == "null":
			data["reconnection_token"] = null
		elif case[1] != null:
			data["reconnection_token"] = case[1]
		var event := SFEventsScript.decode_text(
			SFMessagesScript.encode({"type": "RoomJoined", "data": data})
		)
		if not _assert_equal(
			SFTypesScript.LobbyState.WAITING, event.args[0].lobby_state, "%s: decodes" % case[0]
		):
			continue
		_assert_equal(case[2], event.args[0].reconnection_token, "%s: RoomJoined" % case[0])

	var reconnected_data := _room_joined_data({"lobby_state": "lobby"})
	reconnected_data["reconnection_token"] = TOKEN_V1
	reconnected_data["missed_events"] = [{"type": "Pong"}]
	var event := SFEventsScript.decode_text(
		SFMessagesScript.encode({"type": "Reconnected", "data": reconnected_data})
	)
	_assert_equal(TOKEN_V1, event.args[0].reconnection_token, "Reconnected carries token")
	_assert_equal(1, event.args[1].size(), "missed_events decoded")


func _test_manual_reconnect_guards_and_wire_bytes() -> void:
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	_assert_equal(ERR_UNCONFIGURED, client.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1), "unconfigured")

	_assert_equal(OK, client.configure(_make_config()), "configure")
	_assert_equal(ERR_INVALID_PARAMETER, client.reconnect("", ROOM_ID, TOKEN_V1), "empty player_id")
	_assert_equal(ERR_INVALID_PARAMETER, client.reconnect(PLAYER_A, "", TOKEN_V1), "empty room_id")
	_assert_equal(ERR_INVALID_PARAMETER, client.reconnect(PLAYER_A, ROOM_ID, ""), "empty token")
	var no_endpoint := SignalFishConfigScript.new()
	no_endpoint.app_id = "test-app"
	_assert_equal(OK, client.configure(no_endpoint), "configure without endpoint")
	_assert_equal(
		ERR_INVALID_PARAMETER, client.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1), "no endpoint"
	)
	_assert_equal(5, errors.size(), "each refused reconnect emits protocol_error")

	_assert_equal(OK, client.configure(_make_config()), "reconfigure with endpoint")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	_assert_equal(ERR_BUSY, client.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1), "while connected")
	_assert_equal(6, errors.size(), "busy reconnect emits protocol_error")
	client.free()

	# Happy path: on transport open the first wire bytes are the Reconnect
	# handshake, never Authenticate.
	var reconnector := _make_reconnect_client(TOKEN_V1)
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATING,
		reconnector.get_session_state(),
		"reconnect dials into AUTHENTICATING"
	)
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1))
	_assert_equal(
		[expected], reconnector.transport.sent_text, "first wire bytes are the Reconnect handshake"
	)
	reconnector.free()


func _test_manual_reconnect_completes_and_refreshes_context() -> void:
	var client := _make_reconnect_client(TOKEN_V1)
	client.set_auto_reconnect(true)
	var reconnected_count := [0]
	var missed_count := [0]
	client.reconnected.connect(
		func(_info, missed: Array) -> void:
			reconnected_count[0] += 1
			missed_count[0] = missed.size()
	)
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = [
		{"type": "Pong"}, {"type": "PlayerLeft", "data": {"player_id": PLAYER_B}}
	]
	client.transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(1, reconnected_count[0], "reconnected emitted")
	_assert_equal(2, missed_count[0], "missed_events handed to consumer")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"baseline restores session state"
	)
	_assert_equal(ROOM_ID, client.get_room_id(), "baseline restores room")
	# A fresh baseline replaces the retained context; later auto-reconnects
	# must use the rotated token, and the dial credentials are consumed.
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 1.0)
	_assert_equal(OK, _wait_open(client), "auto dial after baseline")
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V2))
	_assert_equal([expected], client.transport.sent_text, "auto dial uses rotated token")
	client.free()


func _test_auto_reconnect_requires_context_and_not_user_close() -> void:
	# [enabled, baseline]: "none" never joined, "tokenless" joined without a
	# reconnection_token, "token" joined with one.
	var cases := [
		["default off, in-room with token", false, "token"],
		["enabled but never joined a room", true, "none"],
		["enabled, in-room without token", true, "tokenless"],
	]
	for case: Array in cases:
		var client := _make_client(case[1], case[2])
		client.transport.inject_close(-1, "")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CLOSED,
			client.get_connection_state(),
			"%s: no dial" % case[0]
		)
		client.free()

	# With context, an abnormal close dials again.
	var client := _make_client(true, "token")
	client.transport.inject_close(-1, "")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "context: dial happens")
	client.free()

	# A user-initiated clean close never auto-reconnects, even with context.
	client = _make_client(true, "token")
	_assert_equal(OK, client.close(1000, "bye"), "clean close")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"clean close: no dial"
	)
	client.free()


func _test_spectator_baseline_clears_context() -> void:
	var client := _make_client(true, "token")
	(
		client
		. transport
		. inject_server_message(
			{
				"type": "SpectatorJoined",
				"data":
				{
					"room_id": ROOM_ID,
					"room_code": "ABC123",
					"spectator_id": PLAYER_B,
					"game_name": "reef-rally",
					"current_players": [],
					"current_spectators": [],
					"lobby_state": "waiting",
				}
			}
		)
	)
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING, client.get_session_state(), "spectating"
	)
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"spectator baseline: no reconnect (protocol has none)"
	)
	client.free()


func _test_auto_reconnect_backoff_growth_bounds() -> void:
	var client := _make_client(true, "token")
	# Six attempts to also cover the 15s cap row (default budget is five).
	client._config.reconnect_max_attempts = 6
	client._reconnect_rng.seed = 20260919
	for attempt: int in [1, 2, 3, 4, 5, 6]:
		client.transport.inject_close(4999, "dropped")
		var bounds: Array = DELAY_BOUNDS[attempt]
		if not _assert_between(
			client._reconnect_delay_remaining, bounds[0], bounds[1], "attempt %d delay" % attempt
		):
			break
		_assert_equal(attempt, client._auto_reconnect_attempts, "attempt %d counted" % attempt)
		client.transport = SFFakeTransportScript.new()
		_step(client, bounds[1])
		_assert_equal(OK, _wait_open(client), "attempt %d dials" % attempt)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTED,
			client.get_connection_state(),
			"attempt %d open" % attempt
		)
	client.free()


func _test_auto_reconnect_stops_on_terminal_codes() -> void:
	var cases := [
		["RECONNECTION_TOKEN_INVALID", "RECONNECTION_TOKEN_INVALID", true],
		["RECONNECTION_EXPIRED", "RECONNECTION_EXPIRED", true],
		["RECONNECTION_FAILED is retryable", "RECONNECTION_FAILED", false],
	]
	for case: Array in cases:
		var client := _make_client(true, "token")
		client.transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "%s: dial" % case[0])
		(
			client
			. transport
			. inject_server_message(
				{
					"type": "ReconnectionFailed",
					"data": {"reason": "test", "error_code": case[1]},
				}
			)
		)
		client.transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		var dialed := (
			client.get_connection_state() == SignalFishClientScript.ConnectionState.CONNECTING
		)
		_assert_equal(not case[2], dialed, "%s: retry decision" % case[0])
		client.free()


func _test_auto_reconnect_exhaustion_emits_connection_failed() -> void:
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 2
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	for attempt: int in [1, 2]:
		client.transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "attempt %d dials" % attempt)
	_assert_equal(2, client._auto_reconnect_attempts, "budget consumed")
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(1, failures.size(), "exhaustion emits connection_failed once")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"exhaustion: no further dial"
	)
	_assert_equal(2, client._auto_reconnect_attempts, "attempts stop at budget")
	client.free()


func _test_reconnect_tokens_are_redacted() -> void:
	var client := _make_client(true, "token")
	_assert(client._secrets.has(TOKEN_V1), "baseline token registered as secret")
	var reconnector := _make_reconnect_client(TOKEN_V2)
	_assert(reconnector._secrets.has(TOKEN_V2), "manual reconnect token registered as secret")
	var line := "dropped while holding %s" % TOKEN_V2
	_assert_string_not_contains(
		SFLogScript.redact(line, reconnector._secrets), TOKEN_V2, "token redacted"
	)
	reconnector.free()
	client.free()


# -- helpers -----------------------------------------------------------------


func _make_config() -> SignalFishConfigScript:
	var config := SignalFishConfigScript.new()
	config.app_id = "test-app"
	config.endpoint_url = "ws://example.test/socket"
	return config


## Builds a configured client; [param baseline_mode] selects the room baseline
## received after connect: "none", "tokenless", or "token" (TOKEN_V1).
func _make_client(auto_reconnect: bool, baseline_mode: String) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.set_auto_reconnect(auto_reconnect)
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	client.transport.inject_open()
	match baseline_mode:
		"tokenless":
			client.transport.inject_server_message(
				{"type": "RoomJoined", "data": _room_joined_data()}
			)
		"token":
			var data := _room_joined_data()
			data["reconnection_token"] = TOKEN_V1
			client.transport.inject_server_message({"type": "RoomJoined", "data": data})
	return client


func _make_reconnect_client(token: String) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.reconnect(PLAYER_A, ROOM_ID, token), "reconnect dial")
	client.transport.inject_open()
	return client


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	var errors: Array = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	return errors


## Advances the injected clock; auto_poll is off in configs built here, so
## `_process` only drives the reconnect timer.
func _step(client: SignalFishClientScript, delta: float) -> void:
	client._process(delta)


func _wait_open(client: SignalFishClientScript) -> Error:
	# The dial is synchronous on the fake transport; open it and confirm the
	# reconnect handshake went out instead of Authenticate.
	client.transport.inject_open()
	var sent: Array = client.transport.sent_text
	if sent.is_empty():
		_failures.append("expected a handshake after open, got none")
		return FAILED
	if sent[0] == SFMessagesScript.encode(SFMessagesScript.authenticate("test-app")):
		_failures.append("auto dial sent Authenticate instead of Reconnect")
		return FAILED
	return OK


func _room_joined_data(overrides: Dictionary = {}) -> Dictionary:
	var data := {
		"room_id": ROOM_ID,
		"room_code": "ABC123",
		"player_id": PLAYER_A,
		"game_name": "reef-rally",
		"max_players": 4,
		"supports_authority": true,
		"current_players": [_player(PLAYER_A, "Alice")],
		"is_authority": true,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket",
		"current_spectators": [],
	}
	for key: String in overrides:
		data[key] = overrides[key]
	return data


func _player(id: String, display_name: String) -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"is_authority": id == PLAYER_A,
		"is_ready": false,
		"connected_at": "2026-05-29T00:00:00Z"
	}


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


func _assert_between(actual: float, minimum: float, maximum: float, label: String) -> bool:
	if actual < minimum or actual > maximum:
		_failures.append(
			"%s: expected delay in [%s, %s], got %s" % [label, minimum, maximum, actual]
		)
		return false
	return true


func _assert_string_not_contains(actual: String, substring: String, label: String) -> bool:
	if actual.find(substring) != -1:
		_failures.append(
			"%s: expected %s not to contain %s" % [label, var_to_str(actual), var_to_str(substring)]
		)
		return false
	return true
