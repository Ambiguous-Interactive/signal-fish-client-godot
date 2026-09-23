extends SceneTree

# P2 reconnection suite (PLAN §4.4/§4.7): all timing is simulated via _process — no wall clock.

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_A := ClientFixtures.PLAYER_A
const PLAYER_B := ClientFixtures.PLAYER_B
const ROOM_ID := ClientFixtures.ROOM_ID
const TOKEN_V1 := "test-reconnect-token-not-secret"
const TOKEN_V2 := "test-reconnect-token-rotated-not-secret"

# Plan-locked (client RECONNECT_*): attempt -> [min, max] with RECONNECT_JITTER_FRACTION 0.25.
const DELAY_BOUNDS := {
	1: [0.5, 0.625],
	2: [1.0, 1.25],
	3: [2.0, 2.5],
	4: [4.0, 5.0],
	5: [8.0, 10.0],
	6: [15.0, 18.75],
}

var _failures: Array = []
var _test_done := false
# Sentinel: an abort inside _run() unwinds before quit(); CI would hang instead of reporting red.
var _run_completed := false
## Protocol-error trackers for every client built by `_make_client` /
## `_make_reconnect_client`; reconnection flows must stay error-free, so
## tests end with `_assert_no_protocol_errors()` checking them all.
var _error_trackers: Array = []


func _done() -> void:
	_test_done = true


func _init() -> void:
	_run()
	if not _run_completed:
		push_error("reconnect tests aborted before completion")
		quit(1)
		return
	if _failures.is_empty():
		print("reconnect tests passed")
		quit(0)
	else:
		push_error("reconnect tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	var cases: Array[Callable] = [
		_test_reconnection_token_decodes_from_baselines,
		_test_manual_reconnect_guards_and_wire_bytes,
		_test_manual_reconnect_completes_and_refreshes_context,
		_test_manual_reconnect_dial_refreshes_auto_reconnect_context,
		_test_reconnect_reuses_last_dialed_url,
		_test_auto_reconnect_requires_context_and_not_user_close,
		_test_spectator_baseline_clears_context,
		_test_leaving_room_clears_reconnect_context,
		_test_clean_close_clears_reconnect_context,
		_test_failed_auto_dial_does_not_stall_episode,
		_test_timer_dial_sync_refusal_arms_next_attempt_once,
		_test_late_baseline_while_closing_is_ignored,
		_test_auto_reconnect_backoff_growth_bounds,
		_test_auto_reconnect_stops_on_terminal_codes,
		_test_auto_reconnect_retries_after_transport_failure,
		_test_user_close_mid_dial_stops_retrying,
		_test_close_cancels_pending_retry_timer,
		_test_close_from_disconnected_handler_wins_over_retry,
		_test_handler_redial_failure_burns_one_attempt,
		_test_close_from_connection_failed_handler_wins_over_retry,
		_test_double_nested_close_cascade_wins_over_retry,
		_test_scheme_refused_reconnect_drops_dial_credentials,
		_test_duplicate_authenticated_sends_handshake_once,
		_test_duplicate_reconnected_is_fully_silent,
		_test_unsolicited_reconnected_is_loud,
		_test_dial_contract_survives_authentication_error,
		_test_duplicate_protocol_info_is_fully_silent,
		_test_handshake_send_failure_resolves_attempt,
		_test_handshake_send_failure_killing_link_cascades,
		_test_refused_authenticate_resolves_the_dial,
		_test_auto_reconnect_exhaustion_emits_connection_failed,
		_test_redial_from_exhaustion_handler_keeps_the_fresh_identity,
		_test_failure_driven_exhaustion_and_budget_recovery,
		_test_reconnect_tokens_are_redacted,
	]
	CompletionGuard.self_check(self, _failures)
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)
	_run_completed = true


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
		var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
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
	var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		SFMessagesScript.encode({"type": "Reconnected", "data": reconnected_data})
	)
	_assert_equal(TOKEN_V1, event.args[0].reconnection_token, "Reconnected carries token")
	var missed: Array = event.args[1]
	_assert_equal(1, missed.size(), "missed_events decoded")
	_done()


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

	# Upstream parity: every dial re-authenticates; dials stay silent so join-on-auth cannot race.
	var reconnector := _make_reconnect_client(TOKEN_V1)
	var auth_events: Array = []
	reconnector.authenticated.connect(
		func(_app: String, _org: String, _limits: SFTypesScript.RateLimitInfo) -> void:
			auth_events.append(1)
	)
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATING,
		reconnector.get_session_state(),
		"reconnect dials into AUTHENTICATING"
	)
	var auth_bytes := SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))
	_assert_equal([auth_bytes], reconnector.transport.sent_text, "first wire bytes authenticate")
	var reconnector_transport: SFFakeTransportScript = reconnector.transport
	reconnector_transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	_assert_equal([], auth_events, "reconnect dials do not emit authenticated")
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1))
	_assert_equal(
		[auth_bytes, expected],
		reconnector.transport.sent_text,
		"Reconnect handshake follows Authenticated"
	)
	reconnector.free()
	_done()


func _test_manual_reconnect_completes_and_refreshes_context() -> void:
	var client := _make_reconnect_client(TOKEN_V1)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	client.set_auto_reconnect(true)
	var reconnected_count := [0]
	var missed_count := [0]
	client.reconnected.connect(
		func(_info: SFTypesScript.RoomJoinedInfo, missed: Array) -> void:
			reconnected_count[0] += 1
			missed_count[0] = missed.size()
	)
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = [
		{"type": "Pong"}, {"type": "PlayerLeft", "data": {"player_id": PLAYER_B}}
	]
	transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(1, reconnected_count[0], "reconnected emitted")
	_assert_equal(2, missed_count[0], "missed_events handed to consumer")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"baseline restores session state"
	)
	_assert_equal(ROOM_ID, client.get_room_id(), "baseline restores room")
	_assert_equal(0, client._auto_reconnect_attempts, "budget untouched pre-retry")
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	transport = client.transport
	_step(client, 1.0)
	_assert_equal(OK, _wait_open(client), "auto dial after baseline")
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V2))
	_assert_equal(expected, client.transport.sent_text[-1], "auto dial uses rotated token")

	transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(0, client._auto_reconnect_attempts, "budget resets after baseline")
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 1.0)
	_assert_equal(OK, _wait_open(client), "post-reset dial")
	_assert_equal(1, client._auto_reconnect_attempts, "budget restarts at 1 after reset")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_manual_reconnect_dial_refreshes_auto_reconnect_context() -> void:
	# Issue #73: a manual dial with a rotated token re-arms auto-reconnect with
	# that token, never the stale retained one.
	var client := SignalFishClientScript.new()
	_error_trackers.append(_track_protocol_errors(client))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.set_auto_reconnect(true)
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	var data := _room_joined_data()
	data["reconnection_token"] = TOKEN_V1
	transport.inject_server_message({"type": "RoomJoined", "data": data})
	transport.inject_close(4999, "dropped")

	# The consumer manually redials with a rotated token; that dial drops too.
	client.transport = SFFakeTransportScript.new()
	_assert_equal(
		OK, client.reconnect(PLAYER_A, ROOM_ID, TOKEN_V2), "manual dial with rotated token"
	)
	_assert_equal(TOKEN_V2, client._context_auth_token, "manual dial captures its credentials")
	_assert_equal(OK, _wait_open(client), "manual dial authenticates")
	var dial: SFFakeTransportScript = client.transport
	dial.inject_close(4999, "dropped")

	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "auto dial after the manual dial dropped")
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V2))
	_assert_equal(expected, client.transport.sent_text[-1], "auto retry uses the rotated token")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_reconnect_reuses_last_dialed_url() -> void:
	var cases := [
		["override wins over config", "ws://override.test/socket", "ws://example.test/socket"],
		["override with empty config", "ws://override.test/socket", ""],
		["no override falls back to config", "", "ws://example.test/socket"],
	]
	for case: Array in cases:
		var client := SignalFishClientScript.new()
		_error_trackers.append(_track_protocol_errors(client))
		var config := _make_config()
		config.endpoint_url = case[2]
		_assert_equal(OK, client.configure(config), "%s: configure" % case[0])
		client.set_auto_reconnect(true)
		client.transport = SFFakeTransportScript.new()
		var override: String = case[1]
		var connect_url: String = override if not override.is_empty() else case[2]
		_assert_equal(OK, client.connect_to_server(connect_url), "%s: connect" % case[0])
		var transport: SFFakeTransportScript = client.transport
		transport.inject_open()
		var data := _room_joined_data()
		data["reconnection_token"] = TOKEN_V1
		transport.inject_server_message({"type": "RoomJoined", "data": data})
		transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "%s: auto dial" % case[0])
		_assert_equal(connect_url, client.transport._connected_url, "%s: rejoin target" % case[0])
		_assert_no_protocol_errors()
		client.free()
	_done()


func _test_auto_reconnect_requires_context_and_not_user_close() -> void:
	var cases := [
		["default off, in-room with token", false, "token"],
		["enabled but never joined a room", true, "none"],
		["enabled, in-room without token", true, "tokenless"],
	]
	for case: Array in cases:
		var auto_reconnect: bool = case[1]
		var baseline_mode: String = case[2]
		var client := _make_client(auto_reconnect, baseline_mode)
		var transport: SFFakeTransportScript = client.transport
		transport.inject_close(-1, "")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CLOSED,
			client.get_connection_state(),
			"%s: no dial" % case[0]
		)
		client.free()

	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(-1, "")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "context: dial happens")
	client.free()

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
	_done()


func _test_spectator_baseline_clears_context() -> void:
	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	(
		transport
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
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"spectator baseline: no reconnect (protocol has none)"
	)
	client.free()
	_done()


func _test_leaving_room_clears_reconnect_context() -> void:
	var client := _make_client(true, "token")
	_assert(not client._context_auth_token.is_empty(), "context captured")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "RoomLeft"})
	_assert(client._context_auth_token.is_empty(), "room_left clears the context")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session stays authenticated after leaving"
	)
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"no dial after leaving"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_clean_close_clears_reconnect_context() -> void:
	var client := _make_client(true, "token")
	_assert_equal(OK, client.close(1000, "bye"), "clean close")
	_assert(client._context_auth_token.is_empty(), "close clears the context")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server(), "dial configured endpoint")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"no stale rejoin after clean close"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_failed_auto_dial_does_not_stall_episode() -> void:
	# A sync-refused auto dial must still reach exhaustion, not stall; refusal error expected.
	var client := _make_client(true, "token", false)
	var errors := _track_protocol_errors(client)
	client._config.reconnect_max_attempts = 1
	client._last_dial_url = ""
	client._config.endpoint_url = ""
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	_step(client, 30.0)
	_assert_equal(1, client._auto_reconnect_attempts, "attempt consumed by refused dial")
	_assert_equal(1, failures.size(), "episode terminates with the exhaustion notice")
	_assert_string_contains(failures[0], "exhausted", "notice reports exhaustion")
	_assert(client._context_auth_token.is_empty(), "exhaustion drops the identity")
	_assert_equal(
		["reconnect requires a configured endpoint_url or a previous connect_to_server url"],
		errors,
		"refused dial announces the missing target"
	)
	client.free()
	_done()


func _test_timer_dial_sync_refusal_arms_next_attempt_once() -> void:
	# A transport-refused scheduled dial re-enters scheduling exactly once — no double-arm.
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 3
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	client.transport.fail_on_connect = true
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"refused dial surfaces FAILED"
	)
	_assert_equal(2, client._auto_reconnect_attempts, "refusal arms exactly one next attempt")
	_assert(client._reconnect_timer_running, "next backoff armed once")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "retry after refused dial")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_late_baseline_while_closing_is_ignored() -> void:
	# While CLOSING the client still polls for the close frame, so late packets can arrive.
	var client := _make_reconnect_client(TOKEN_V1)
	client.set_auto_reconnect(true)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	client._connection_state = SignalFishClientScript.ConnectionState.CLOSING
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = []
	transport.inject_server_message({"type": "Reconnected", "data": data})
	# Issue #73: the manual dial's credentials are the retained identity; a
	# late baseline must not replace them with its own token.
	_assert_equal(TOKEN_V1, client._context_auth_token, "late baseline cannot replace the identity")
	_assert_equal("", client.get_room_id(), "late baseline cannot restore the room")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session state untouched by late baseline"
	)
	_assert_equal(OK, client.close(1000, "bye"), "user close")
	_assert(client._context_auth_token.is_empty(), "the user close clears the identity")
	client.free()
	_done()


func _test_auto_reconnect_backoff_growth_bounds() -> void:
	var client := _make_client(true, "token")
	# Six attempts to also cover the 15s cap row (default budget is five).
	client._config.reconnect_max_attempts = 6
	client._reconnect_rng.seed = 20260919
	for attempt: int in [1, 2, 3, 4, 5, 6]:
		var transport: SFFakeTransportScript = client.transport
		transport.inject_close(4999, "dropped")
		var bounds: Array = DELAY_BOUNDS[attempt]
		var minimum: float = bounds[0]
		var maximum: float = bounds[1]
		if not _assert_between(
			client._reconnect_delay_remaining, minimum, maximum, "attempt %d delay" % attempt
		):
			break
		_assert_equal(attempt, client._auto_reconnect_attempts, "attempt %d counted" % attempt)
		client.transport = SFFakeTransportScript.new()
		_step(client, maximum)
		_assert_equal(OK, _wait_open(client), "attempt %d dials" % attempt)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTED,
			client.get_connection_state(),
			"attempt %d open" % attempt
		)
	client.free()
	_done()


func _test_auto_reconnect_stops_on_terminal_codes() -> void:
	var cases := [
		["RECONNECTION_TOKEN_INVALID", "RECONNECTION_TOKEN_INVALID", true],
		["RECONNECTION_EXPIRED", "RECONNECTION_EXPIRED", true],
		["RECONNECTION_FAILED is retryable", "RECONNECTION_FAILED", false],
	]
	for case: Array in cases:
		var client := _make_client(true, "token")
		var transport: SFFakeTransportScript = client.transport
		transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		transport = client.transport
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "%s: dial" % case[0])
		var disconnects: Array = []
		client.disconnected.connect(
			func(code: int, _reason: String) -> void: disconnects.append(code)
		)
		transport.inject_server_message(
			{"type": "ReconnectionFailed", "data": {"reason": "test", "error_code": case[1]}}
		)
		# A rejected rejoin brings the link down like a close frame would.
		_assert_equal([-1], disconnects, "%s: link torn down" % case[0])
		_assert_equal(
			SignalFishClientScript.ConnectionState.CLOSED,
			client.get_connection_state(),
			"%s: closed after rejection" % case[0]
		)
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		var dialed := (
			client.get_connection_state() == SignalFishClientScript.ConnectionState.CONNECTING
		)
		_assert_equal(not case[2], dialed, "%s: retry decision" % case[0])
		_assert_no_protocol_errors()
		client.free()
	_done()


func _test_auto_reconnect_retries_after_transport_failure() -> void:
	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	transport = client.transport
	_step(client, 30.0)
	transport.inject_failure("connection refused")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"failed dial surfaces FAILED"
	)
	_assert_equal(2, client._auto_reconnect_attempts, "failed dial schedules next attempt")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "retry after failed dial")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_user_close_mid_dial_stops_retrying() -> void:
	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"retry dial in flight"
	)
	client.close()
	# Close while connecting is a failed open; the user's intent must win.
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"failed open surfaces FAILED"
	)
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"user abort: no retry"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_close_cancels_pending_retry_timer() -> void:
	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	_assert(client._reconnect_timer_running, "retry timer armed")
	_assert_equal(OK, client.close(), "clean close while timer pending")
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"cancelled timer never dials"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_handler_redial_failure_burns_one_attempt() -> void:
	# A sync-failing handler redial schedules inside the handler; no second attempt may arm.
	var client := _make_client(true, "token")
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void:
			var dial: SFFakeTransportScript = SFFakeTransportScript.new()
			dial.fail_on_connect = true
			client.transport = dial
			client.connect_to_server("ws://example.test/socket")
	)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	_assert_equal(1, client._auto_reconnect_attempts, "one cascade arms exactly one attempt")
	_assert(client._reconnect_timer_running, "backoff armed once")
	_assert_equal(1, failures.size(), "inner dial failure surfaced once")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_close_from_connection_failed_handler_wins_over_retry() -> void:
	var client := _make_client(true, "token")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	transport = client.transport
	_step(client, 30.0)
	client.connection_failed.connect(func(_error: String) -> void: client.close())
	transport.inject_failure("link died")
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"consumer close from failure handler stops auto-reconnect"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_double_nested_close_cascade_wins_over_retry() -> void:
	# Issue #20: the inner cascade must not consume the late close intent or burn an attempt.
	var client := _make_client(true, "token")
	client.connection_failed.connect(func(_error: String) -> void: client.close())
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void:
			var dial: SFFakeTransportScript = SFFakeTransportScript.new()
			dial.fail_on_connect = true
			client.transport = dial
			client.connect_to_server("ws://example.test/socket")
	)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	_assert_equal(0, client._auto_reconnect_attempts, "no attempt armed by the nested cascade")
	_assert(not client._reconnect_timer_running, "no retry timer armed")
	_assert(client._user_close_requested, "close intent stays settled after the cascade")
	_step(client, 30.0)
	_assert(not client._reconnect_timer_running, "no late retry once the clock runs")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "fresh dial")
	_assert(not client._user_close_requested, "a fresh dial clears the settled intent")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_scheme_refused_reconnect_drops_dial_credentials() -> void:
	# Issue #21: a scheme-refused reconnect never dials; credentials must not stay resident.
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client._last_dial_url = "http://example.test/socket"
	_assert_equal(
		ERR_INVALID_PARAMETER, client.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1), "scheme refusal"
	)
	_assert_equal(1, errors.size(), "the refusal announces itself once")
	_assert_string_contains(errors[0], "invalid WebSocket URL scheme", "refusal reason")
	_assert_equal("", client._reconnect_player_id, "player_id dropped on refusal")
	_assert_equal("", client._reconnect_room_id, "room_id dropped on refusal")
	_assert_equal("", client._reconnect_auth_token, "token dropped on refusal")
	_assert(client._secrets.has(TOKEN_V1), "dropped token stays redacted")
	client.free()
	_done()


func _test_duplicate_authenticated_sends_handshake_once() -> void:
	# Issue #21: duplicate Authenticated is off-contract; a hostile server must not re-handshake.
	var client := _make_reconnect_client(TOKEN_V1)
	var auth_bytes := SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))
	var handshake := SFMessagesScript.encode(
		SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1)
	)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal([auth_bytes, handshake], client.transport.sent_text, "handshake sent once")
	_assert_no_protocol_errors()
	client.free()

	var reconnected_client := _make_reconnect_client(TOKEN_V1)
	var reconnected_transport: SFFakeTransportScript = reconnected_client.transport
	reconnected_transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	var auth_events: Array = []
	reconnected_client.authenticated.connect(
		func(_app: String, _org: String, _limits: SFTypesScript.RateLimitInfo) -> void:
			auth_events.append(1)
	)
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = []
	reconnected_transport.inject_server_message({"type": "Reconnected", "data": data})
	reconnected_transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	_assert_equal([], auth_events, "duplicate after the handshake stays consumer-silent")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		reconnected_client.get_session_state(),
		"session state untouched by the duplicate"
	)
	_assert_no_protocol_errors()
	reconnected_client.free()
	_done()


func _test_duplicate_reconnected_is_fully_silent() -> void:
	# Issue #71 (#24 precedent): duplicate Reconnected is off-contract;
	# consumers replay missed_events, so a second emission would double-apply
	# game events. State re-application is idempotent; the emission is not.
	var client := _make_reconnect_client(TOKEN_V1)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var emissions := [0]
	client.reconnected.connect(
		func(_info: SFTypesScript.RoomJoinedInfo, _missed: Array) -> void: emissions[0] += 1
	)
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = [{"type": "Pong"}]
	transport.inject_server_message({"type": "Reconnected", "data": data})
	transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(1, emissions[0], "reconnected emitted once per dial")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"session state untouched by duplicate"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_unsolicited_reconnected_is_loud() -> void:
	# Issue #108: `Reconnected` on a dial that never sent the directed
	# handshake is hostile input. Unlike the idempotent duplicate (#71) it
	# must surface a `protocol_error` instead of being silently dropped.
	# Local tracker: this test expects an error, so it must not pollute the
	# shared zero-error assertion other tests end with.
	var client := _make_client(false, "none", false)
	var errors := _track_protocol_errors(client)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var emissions := [0]
	client.reconnected.connect(
		func(_info: SFTypesScript.RoomJoinedInfo, _missed: Array) -> void: emissions[0] += 1
	)
	var errors_before := errors.size()
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V1
	data["missed_events"] = []
	transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(0, emissions[0], "no baseline applied")
	_assert_equal(1, errors.size() - errors_before, "unsolicited Reconnected surfaces one error")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session state untouched"
	)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTED,
		client.get_connection_state(),
		"link stays up (protocol_error is local and non-fatal)"
	)
	client.free()
	_done()


func _test_dial_contract_survives_authentication_error() -> void:
	# Issue #82: `AuthenticationError` clears the dial credentials mid-dial;
	# hostile `Authenticated`/`Reconnected` events after it must not leak the
	# consumer-silent dial contract or apply a baseline for a handshake that
	# never went out.
	var client := _make_reconnect_client(TOKEN_V1, false)
	var errors := _track_protocol_errors(client)
	var transport: SFFakeTransportScript = client.transport
	var auth_events: Array = []
	var auth_error_events: Array = []
	var reconnected_events: Array = []
	client.authenticated.connect(
		func(_app: String, _org: String, _limits: SFTypesScript.RateLimitInfo) -> void:
			auth_events.append(1)
	)
	client.authentication_error.connect(
		func(_error: String, _code: SFErrorCodesScript.Code) -> void: auth_error_events.append(1)
	)
	client.reconnected.connect(
		func(_info: SFTypesScript.RoomJoinedInfo, _missed: Array) -> void:
			reconnected_events.append(1)
	)
	transport.inject_server_message(
		{
			"type": "AuthenticationError",
			"data": {"error": "bad token", "error_code": "UNAUTHORIZED"}
		}
	)
	_assert_equal(1, auth_error_events.size(), "authentication_error surfaces once")
	_assert_equal("", client._reconnect_auth_token, "dial credentials consumed by the error")
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var reconnected_data := _room_joined_data({"lobby_state": "lobby"})
	reconnected_data["reconnection_token"] = TOKEN_V2
	reconnected_data["missed_events"] = []
	transport.inject_server_message({"type": "Reconnected", "data": reconnected_data})
	_assert_equal([], auth_events, "post-error Authenticated stays consumer-silent")
	_assert_equal([], reconnected_events, "post-error Reconnected stays consumer-silent")
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		client.get_session_state(),
		"no hostile event restores the session"
	)
	_assert_equal(
		[SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))],
		client.transport.sent_text,
		"no handshake for a dial whose authentication failed"
	)
	# Issue #108: the hostile post-error Reconnected is loud, not silent; the
	# AuthenticationError and hostile Authenticated contribute no errors.
	_assert_equal(1, errors.size(), "exactly the hostile Reconnected is reported")
	client.free()
	_done()


func _test_duplicate_protocol_info_is_fully_silent() -> void:
	# Issue #82 (#24 precedent): duplicate ProtocolInfo is off-contract; it
	# must not re-reconcile the game-data format or re-emit.
	var client := SignalFishClientScript.new()
	_error_trackers.append(_track_protocol_errors(client))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server(), "connect")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var emissions: Array = []
	client.protocol_info.connect(
		func(_info: SFTypesScript.ProtocolInfo) -> void: emissions.append(1)
	)
	transport.inject_server_message({"type": "ProtocolInfo", "data": {}})
	transport.inject_server_message({"type": "ProtocolInfo", "data": {}})
	_assert_equal(1, emissions.size(), "protocol_info emitted once per dial")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_handshake_send_failure_resolves_attempt() -> void:
	# Issue #21: a failed handshake send must resolve negatively, not hang
	# authenticated-but-roomless.
	var client := _make_reconnect_client(TOKEN_V1, false)
	var errors := _track_protocol_errors(client)
	var reconnection_failures: Array = []
	var disconnects: Array = []
	var dial: SFFakeTransportScript = client.transport
	client.reconnection_failed.connect(
		func(reason: String, code: SFErrorCodesScript.Code) -> void:
			reconnection_failures.append([reason, code])
	)
	client.disconnected.connect(func(code: int, _reason: String) -> void: disconnects.append(code))
	# Backpressure the transport only after the Authenticate went out.
	dial.buffered_amount = client._config.max_buffered_bytes + 1
	dial.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(1, reconnection_failures.size(), "handshake failure resolves the attempt")
	var failure_reason: String = reconnection_failures[0][0]
	_assert_string_contains(failure_reason, "handshake", "failure reason")
	_assert_equal(SFErrorCodesScript.Code.NONE, reconnection_failures[0][1], "local failure code")
	_assert_equal([-1], disconnects, "terminal disconnect surfaces")
	_assert_equal("", client._reconnect_auth_token, "dial credentials consumed")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED, client.get_connection_state(), "torn down"
	)
	_assert(dial._closed_emitted, "torn-down socket is closed, not dropped live")
	_assert_equal(1, errors.size(), "exactly the transport diagnostic")
	_assert_string_contains(errors[0], "backpressure", "transport diagnostic")
	client.free()

	var reconnector := _make_client(true, "token", false)
	var retry_errors := _track_protocol_errors(reconnector)
	var transport: SFFakeTransportScript = reconnector.transport
	transport.inject_close(4999, "dropped")
	reconnector.transport = SFFakeTransportScript.new()
	transport = reconnector.transport
	_step(reconnector, 30.0)
	transport.inject_open()
	transport.buffered_amount = reconnector._config.max_buffered_bytes + 1
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(2, reconnector._auto_reconnect_attempts, "failed handshake re-arms the retry")
	_assert(reconnector._reconnect_timer_running, "backoff armed after handshake failure")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED, reconnector.get_connection_state(), "closed"
	)
	_assert_equal(1, retry_errors.size(), "exactly the transport diagnostic")
	reconnector.free()
	_done()


func _test_handshake_send_failure_killing_link_cascades() -> void:
	# Issue #24: link-killing send resolves via the failure cascade; no disconnected(-1) double-fire.
	var client := _make_reconnect_client(TOKEN_V1, false)
	var errors := _track_protocol_errors(client)
	var connection_failures: Array[String] = []
	var reconnection_failures: Array = []
	var disconnects: Array = []
	client.connection_failed.connect(func(error: String) -> void: connection_failures.append(error))
	client.reconnection_failed.connect(
		func(reason: String, code: SFErrorCodesScript.Code) -> void:
			reconnection_failures.append([reason, code])
	)
	client.disconnected.connect(func(code: int, _reason: String) -> void: disconnects.append(code))
	var transport: SFFakeTransportScript = client.transport
	transport.fail_on_send = true
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(1, connection_failures.size(), "dead link surfaces connection_failed once")
	_assert_string_contains(
		connection_failures[0], "send", "transport failure names the failed send"
	)
	_assert_equal(1, reconnection_failures.size(), "attempt still resolves negatively")
	var failure_reason: String = reconnection_failures[0][0]
	_assert_string_contains(failure_reason, "handshake", "failure reason")
	_assert_equal([], disconnects, "no terminal disconnect after a dead link")
	_assert_equal("", client._reconnect_auth_token, "dial credentials consumed")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"session ends FAILED"
	)
	_assert_equal(1, errors.size(), "exactly the send diagnostic")
	_assert_string_contains(errors[0], "send failed", "send diagnostic")
	client.free()
	_done()


func _test_refused_authenticate_resolves_the_dial() -> void:
	# Issue #73: a refused authenticate (e.g. the backpressure cap) must not
	# stall any dial authenticated-with-nothing-in-flight; it resolves exactly
	# once, like a transport failure. Twins: the handshake failure tests above.
	var client := SignalFishClientScript.new()
	var failures: Array[String] = []
	var errors := _track_protocol_errors(client)
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	transport.buffered_amount = client._config.max_buffered_bytes + 1
	client.transport = transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	transport.inject_open()
	_assert_equal(1, failures.size(), "refused authenticate resolves the dial")
	_assert_string_contains(failures[0], "authenticate", "failure names the refused send")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED, client.get_connection_state(), "ends FAILED"
	)
	_assert_equal(null, client.transport, "transport released")
	_assert_equal(1, errors.size(), "exactly the transport diagnostic")
	_assert_string_contains(errors[0], "backpressure", "diagnostic explains the refusal")
	client.free()

	# A link-killing send already cascades through the transport's `failed`;
	# the open handler must not resolve the dial a second time.
	var killed := SignalFishClientScript.new()
	var killed_failures: Array[String] = []
	killed.connection_failed.connect(func(error: String) -> void: killed_failures.append(error))
	_assert_equal(OK, killed.configure(_make_config()), "configure (dead link)")
	var killed_transport: SFFakeTransportScript = SFFakeTransportScript.new()
	killed_transport.fail_on_send = true
	killed.transport = killed_transport
	_assert_equal(OK, killed.connect_to_server("ws://example.test/socket"), "connect (dead link)")
	killed_transport.inject_open()
	_assert_equal(1, killed_failures.size(), "exactly one connection_failed for the dead send")
	_assert_string_contains(killed_failures[0], "send", "failure names the dead send")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED, killed.get_connection_state(), "ends FAILED"
	)
	killed.free()
	_done()


func _test_auto_reconnect_exhaustion_emits_connection_failed() -> void:
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 2
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var transport: SFFakeTransportScript = client.transport
	for attempt: int in [1, 2]:
		transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		transport = client.transport
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "attempt %d dials" % attempt)
	_assert_equal(2, client._auto_reconnect_attempts, "budget consumed")
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(1, failures.size(), "exhaustion emits connection_failed once")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"exhaustion: no further dial"
	)
	_assert_equal(2, client._auto_reconnect_attempts, "attempts stop at budget")
	_assert_no_protocol_errors()
	client.free()
	_done()


## The exhaustion notice is emitted synchronously: a consumer redialing from
## its handler captures a fresh retained identity that the post-emit drop
## must not clobber — and that manual dial's later death must still engage
## auto-reconnect (with a fresh exhaustion notice) instead of silent-dead-
## ending it.


func _test_redial_from_exhaustion_handler_keeps_the_fresh_identity() -> void:
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 1
	var failures: Array = []
	var redial_ok := [false]
	client.connection_failed.connect(
		func(error: String) -> void:
			failures.append(error)
			if error.contains("exhausted") and not redial_ok[0]:
				# Sibling handler-redial tests assign a fake first: the
				# cascade already tore the old transport down, so a redial on
				# the nulled member would construct a real socket.
				client.transport = SFFakeTransportScript.new()
				redial_ok[0] = (
					client.reconnect(PLAYER_A, ROOM_ID, "manual-token-not-secret") == OK
				)
	)
	var transport: SFFakeTransportScript = client.transport
	# Attempt 1: the only budgeted retry (a fresh fake per close: the close
	# signal fires once per fake session).
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	transport = client.transport
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "budgeted attempt dials")
	# Its death pre-baseline hits the exhausted budget and emits the notice;
	# the handler redials synchronously inside it.
	transport.inject_close(4999, "dropped again")
	var redialed: bool = redial_ok[0]
	_assert(redialed, "handler redial from the exhaustion notice succeeds")
	_assert_equal(
		"manual-token-not-secret",
		client._context_auth_token,
		"the redial's identity survives the cascade"
	)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"the manual dial is live after the cascade unwinds"
	)
	# The manual dial dies pre-baseline: scheduling must re-engage with the
	# retained manual identity and emit a second, terminal exhaustion notice.
	# (The redial dialed a fresh fake after the cascade tore the old transport
	# down; its death goes through that live fake.)
	var live: Object = client.transport
	_assert(live is SFFakeTransportScript, "the manual dial runs on a fake transport")
	transport = client.transport
	transport.inject_close(4999, "manual dial died")
	# The refused dial surfaces its own failure notice, and its death re-engages
	# scheduling with the retained manual identity: a fresh terminal exhaustion.
	_assert_equal(3, failures.size(), "manual dial's death re-engages scheduling")
	var refused_notice: String = failures[1]
	_assert_string_contains(
		refused_notice, "failed before open", "refused dial surfaces its own notice"
	)
	var terminal_notice: String = failures[2]
	_assert_string_contains(terminal_notice, "exhausted", "terminal notice reports exhaustion")
	_assert_equal("", client._context_auth_token, "terminal exhaustion still drops the identity")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"terminal: the refused dial's FAILED state stands, no further dial"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_close_from_disconnected_handler_wins_over_retry() -> void:
	var client := _make_client(true, "token")
	client.disconnected.connect(func(_code: int, _reason: String) -> void: client.close())
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"consumer clean close from handler stops auto-reconnect"
	)
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_failure_driven_exhaustion_and_budget_recovery() -> void:
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 2
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	for dial: int in [1, 2]:
		client.transport = SFFakeTransportScript.new()
		transport = client.transport
		_step(client, 30.0)
		transport.inject_failure("connection refused %d" % dial)
	_assert_equal(3, failures.size(), "failure-driven exhaustion emits the final notice")
	_assert_string_contains(failures[2], "exhausted", "final notice reports exhaustion")
	_assert_equal(2, client._auto_reconnect_attempts, "attempts stop at budget")
	_assert_no_protocol_errors()
	client.free()

	client = _make_client(true, "none")
	client._auto_reconnect_attempts = 2
	var data := _room_joined_data()
	data["reconnection_token"] = TOKEN_V1
	transport = client.transport
	transport.inject_server_message({"type": "RoomJoined", "data": data})
	_assert_equal(0, client._auto_reconnect_attempts, "fresh baseline restarts the budget")
	transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "recovery after fresh baseline dials")
	_assert_no_protocol_errors()
	client.free()
	_done()


func _test_reconnect_tokens_are_redacted() -> void:
	var client := _make_client(true, "token")
	_assert(client._secrets.has(TOKEN_V1), "baseline token registered as secret")
	var reconnector := _make_reconnect_client(TOKEN_V2)
	_assert(reconnector._secrets.has(TOKEN_V2), "manual reconnect token registered as secret")
	# Mid-episode reconfigure rebuilds the redaction list; the retained identity must stay on it.
	var transport: SFFakeTransportScript = client.transport
	transport.inject_close(4999, "dropped")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"dropped link ends CLOSED"
	)
	_assert_equal(OK, client.configure(_make_config()), "reconfigure while dropped")
	_assert(client._secrets.has(TOKEN_V1), "retained token stays redacted after configure")
	var line := "dropped while holding %s" % TOKEN_V2
	_assert_string_not_contains(
		SFLogScript.redact(line, reconnector._secrets), TOKEN_V2, "token redacted"
	)
	_assert_no_protocol_errors()
	reconnector.free()
	client.free()
	_done()


func _make_config() -> SignalFishConfigScript:
	var config := SignalFishConfigScript.new()
	config.app_id = "test-app"
	config.endpoint_url = "ws://example.test/socket"
	config.auto_poll = false
	return config


## Builds a configured client; [param baseline_mode] selects the room baseline
## received after connect: "none", "tokenless", or "token" (TOKEN_V1). Pass
## [param track_errors] false to manage protocol-error tracking locally.
func _make_client(
	auto_reconnect: bool, baseline_mode: String, track_errors := true
) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	if track_errors:
		_error_trackers.append(_track_protocol_errors(client))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.set_auto_reconnect(auto_reconnect)
	client.transport = SFFakeTransportScript.new()
	var transport: SFFakeTransportScript = client.transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	transport.inject_open()
	match baseline_mode:
		"tokenless":
			transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
		"token":
			var data := _room_joined_data()
			data["reconnection_token"] = TOKEN_V1
			transport.inject_server_message({"type": "RoomJoined", "data": data})
	return client


func _make_reconnect_client(token: String, track_errors := true) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	if track_errors:
		_error_trackers.append(_track_protocol_errors(client))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.transport = SFFakeTransportScript.new()
	var transport: SFFakeTransportScript = client.transport
	_assert_equal(OK, client.reconnect(PLAYER_A, ROOM_ID, token), "reconnect dial")
	transport.inject_open()
	return client


func _track_protocol_errors(client: SignalFishClientScript) -> Array[String]:
	var errors: Array[String] = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	return errors


func _assert_no_protocol_errors() -> void:
	for tracker: Array in _error_trackers:
		_assert_equal([], tracker, "no spurious protocol_error")


## Advances the injected clock; auto_poll is off in configs built here, so
## `_process` only drives the reconnect timer.
func _step(client: SignalFishClientScript, delta: float) -> void:
	client._process(delta)


func _wait_open(client: SignalFishClientScript) -> Error:
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var sent: Array = client.transport.sent_text
	if sent.size() < 2:
		_failures.append(
			"expected Authenticate + handshake after open, got %d message(s)" % sent.size()
		)
		return FAILED
	if sent[1] == SFMessagesScript.encode(SFMessagesScript.authenticate("test-app")):
		_failures.append("auto dial sent a second Authenticate instead of Reconnect")
		return FAILED
	return OK


func _authenticated_data() -> Dictionary:
	return ClientFixtures.authenticated_data()


func _room_joined_data(overrides: Dictionary = {}) -> Dictionary:
	# This suite joins as a lone authority; the shared fixture ships a
	# spectator, so shape it away here.
	var shaped := {"current_spectators": []}
	shaped.merge(overrides, true)
	return ClientFixtures.room_joined_data(shaped)


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


func _assert_string_not_contains(actual: String, substring: String, label: String) -> bool:
	if actual.find(substring) != -1:
		_failures.append(
			"%s: expected %s not to contain %s" % [label, var_to_str(actual), var_to_str(substring)]
		)
		return false
	return true
