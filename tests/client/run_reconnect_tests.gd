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
## Protocol-error trackers for every client built by `_make_client` /
## `_make_reconnect_client`; reconnection flows must stay error-free, so
## tests end with `_assert_no_protocol_errors()` checking them all.
var _error_trackers: Array = []


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
	_test_reconnect_reuses_last_dialed_url()
	_test_auto_reconnect_requires_context_and_not_user_close()
	_test_spectator_baseline_clears_context()
	_test_leaving_room_clears_reconnect_context()
	_test_clean_close_clears_reconnect_context()
	_test_failed_auto_dial_does_not_stall_episode()
	_test_timer_dial_sync_refusal_arms_next_attempt_once()
	_test_late_baseline_while_closing_is_ignored()
	_test_auto_reconnect_backoff_growth_bounds()
	_test_auto_reconnect_stops_on_terminal_codes()
	_test_auto_reconnect_retries_after_transport_failure()
	_test_user_close_mid_dial_stops_retrying()
	_test_close_cancels_pending_retry_timer()
	_test_close_from_disconnected_handler_wins_over_retry()
	_test_handler_redial_failure_burns_one_attempt()
	_test_close_from_connection_failed_handler_wins_over_retry()
	_test_double_nested_close_cascade_wins_over_retry()
	_test_scheme_refused_reconnect_drops_dial_credentials()
	_test_duplicate_authenticated_sends_handshake_once()
	_test_handshake_send_failure_resolves_attempt()
	_test_handshake_send_failure_killing_link_cascades()
	_test_auto_reconnect_exhaustion_emits_connection_failed()
	_test_failure_driven_exhaustion_and_budget_recovery()
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

	# Happy path: on transport open the first wire bytes are Authenticate
	# (upstream parity: every dial re-authenticates), and the directed
	# Reconnect handshake follows once Authenticated arrives. The
	# `authenticated` signal stays consumer-silent on dials so a
	# join-on-auth handler cannot race the handshake with a fresh JoinRoom.
	var reconnector := _make_reconnect_client(TOKEN_V1)
	var auth_events: Array = []
	reconnector.authenticated.connect(
		func(_app: String, _org: String, _limits) -> void: auth_events.append(1)
	)
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATING,
		reconnector.get_session_state(),
		"reconnect dials into AUTHENTICATING"
	)
	var auth_bytes := SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))
	_assert_equal([auth_bytes], reconnector.transport.sent_text, "first wire bytes authenticate")
	reconnector.transport.inject_server_message(
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


func _test_manual_reconnect_completes_and_refreshes_context() -> void:
	var client := _make_reconnect_client(TOKEN_V1)
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
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
	_assert_equal(0, client._auto_reconnect_attempts, "budget untouched pre-retry")
	# A fresh baseline replaces the retained context; later auto-reconnects
	# must use the rotated token, and the dial credentials are consumed.
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 1.0)
	_assert_equal(OK, _wait_open(client), "auto dial after baseline")
	var expected := SFMessagesScript.encode(SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V2))
	_assert_equal(expected, client.transport.sent_text[-1], "auto dial uses rotated token")

	# The next successful baseline resets the retry budget.
	client.transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert_equal(0, client._auto_reconnect_attempts, "budget resets after baseline")
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 1.0)
	_assert_equal(OK, _wait_open(client), "post-reset dial")
	_assert_equal(1, client._auto_reconnect_attempts, "budget restarts at 1 after reset")
	_assert_no_protocol_errors()
	client.free()


func _test_reconnect_reuses_last_dialed_url() -> void:
	# A reconnect must rejoin the endpoint the session was established with:
	# an explicit connect_to_server override wins over config.endpoint_url.
	# [label, explicit override ("" = none), config endpoint]
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
		var override := case[1] as String
		var connect_url := override if not override.is_empty() else case[2] as String
		_assert_equal(OK, client.connect_to_server(connect_url), "%s: connect" % case[0])
		client.transport.inject_open()
		var data := _room_joined_data()
		data["reconnection_token"] = TOKEN_V1
		client.transport.inject_server_message({"type": "RoomJoined", "data": data})
		client.transport.inject_close(4999, "dropped")
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		_assert_equal(OK, _wait_open(client), "%s: auto dial" % case[0])
		_assert_equal(connect_url, client.transport._connected_url, "%s: rejoin target" % case[0])
		_assert_no_protocol_errors()
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


func _test_leaving_room_clears_reconnect_context() -> void:
	var client := _make_client(true, "token")
	_assert(not client._context_auth_token.is_empty(), "context captured")
	client.transport.inject_server_message({"type": "RoomLeft"})
	_assert(client._context_auth_token.is_empty(), "room_left clears the context")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session stays authenticated after leaving"
	)
	# A later abnormal drop must not dial into the room the consumer left.
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"no dial after leaving"
	)
	_assert_no_protocol_errors()
	client.free()


func _test_clean_close_clears_reconnect_context() -> void:
	# A clean close drops the retained identity so a later dropped session
	# (which never joined a room) cannot rejoin the old room.
	var client := _make_client(true, "token")
	_assert_equal(OK, client.close(1000, "bye"), "clean close")
	_assert(client._context_auth_token.is_empty(), "close clears the context")
	# New session that never joins a room, then drops abnormally.
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server(), "dial configured endpoint")
	client.transport.inject_open()
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"no stale rejoin after clean close"
	)
	_assert_no_protocol_errors()
	client.free()


func _test_failed_auto_dial_does_not_stall_episode() -> void:
	# If a scheduled auto dial is refused synchronously (here: no dial target),
	# the episode must still reach the exhaustion path instead of stalling.
	# Runs without the shared error tracker: the refusal protocol_error is
	# expected and asserted verbatim below.
	var client := _make_client(true, "token", false)
	var errors := _track_protocol_errors(client)
	client._config.reconnect_max_attempts = 1
	client._last_dial_url = ""
	client._config.endpoint_url = ""
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client.transport.inject_close(4999, "dropped")
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


func _test_timer_dial_sync_refusal_arms_next_attempt_once() -> void:
	# A scheduled auto dial refused synchronously by the transport re-enters
	# scheduling exactly once: the `failed` cascade arms the next attempt and
	# the post-refusal re-entry in `_start_auto_reconnect` must not double-arm.
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 3
	client.transport.inject_close(4999, "dropped")
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


func _test_late_baseline_while_closing_is_ignored() -> void:
	# While CLOSING the client keeps polling for the close frame, so late
	# packets can arrive. A late baseline must not resurrect the room state
	# or re-capture the reconnection identity that the user's close cleared.
	var client := _make_reconnect_client(TOKEN_V1)
	client.set_auto_reconnect(true)
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	client._connection_state = SignalFishClientScript.ConnectionState.CLOSING
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = []
	client.transport.inject_server_message({"type": "Reconnected", "data": data})
	_assert(client._context_auth_token.is_empty(), "late baseline cannot restore the identity")
	_assert_equal("", client.get_room_id(), "late baseline cannot restore the room")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session state untouched by late baseline"
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
		var disconnects: Array = []
		client.disconnected.connect(
			func(code: int, _reason: String) -> void: disconnects.append(code)
		)
		client.transport.inject_server_message(
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


func _test_auto_reconnect_retries_after_transport_failure() -> void:
	var client := _make_client(true, "token")
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	client.transport.inject_failure("connection refused")
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


func _test_user_close_mid_dial_stops_retrying() -> void:
	var client := _make_client(true, "token")
	client.transport.inject_close(4999, "dropped")
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


func _test_close_cancels_pending_retry_timer() -> void:
	var client := _make_client(true, "token")
	client.transport.inject_close(4999, "dropped")
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


func _test_handler_redial_failure_burns_one_attempt() -> void:
	# A consumer redial from a `disconnected` handler that fails synchronously
	# schedules inside the handler; the deferred schedule must not arm a
	# second attempt for the same cascade.
	var client := _make_client(true, "token")
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void:
			var dial = SFFakeTransportScript.new()
			dial.fail_on_connect = true
			client.transport = dial
			client.connect_to_server("ws://example.test/socket")
	)
	client.transport.inject_close(4999, "dropped")
	_assert_equal(1, client._auto_reconnect_attempts, "one cascade arms exactly one attempt")
	_assert(client._reconnect_timer_running, "backoff armed once")
	_assert_equal(1, failures.size(), "inner dial failure surfaced once")
	_assert_no_protocol_errors()
	client.free()


func _test_close_from_connection_failed_handler_wins_over_retry() -> void:
	var client := _make_client(true, "token")
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	client.connection_failed.connect(func(_error: String) -> void: client.close())
	client.transport.inject_failure("link died")
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"consumer close from failure handler stops auto-reconnect"
	)
	_assert_no_protocol_errors()
	client.free()


func _test_double_nested_close_cascade_wins_over_retry() -> void:
	# Issue #20: a consumer redials from a `disconnected` handler and calls
	# close() from that redial's `connection_failed` handler. The inner
	# cascade must not consume the late close intent: every scheduling point
	# in the termination cascade observes the consumer's close, none arms,
	# and no budgeted attempt is burned.
	var client := _make_client(true, "token")
	client.connection_failed.connect(func(_error: String) -> void: client.close())
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void:
			var dial = SFFakeTransportScript.new()
			dial.fail_on_connect = true
			client.transport = dial
			client.connect_to_server("ws://example.test/socket")
	)
	client.transport.inject_close(4999, "dropped")
	_assert_equal(0, client._auto_reconnect_attempts, "no attempt armed by the nested cascade")
	_assert(not client._reconnect_timer_running, "no retry timer armed")
	_assert(client._user_close_requested, "close intent stays settled after the cascade")
	_step(client, 30.0)
	_assert(not client._reconnect_timer_running, "no late retry once the clock runs")
	# The settled intent clears on the next dial so future cascades arm again.
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "fresh dial")
	_assert(not client._user_close_requested, "a fresh dial clears the settled intent")
	_assert_no_protocol_errors()
	client.free()


func _test_scheme_refused_reconnect_drops_dial_credentials() -> void:
	# Issue #21: a reconnect whose dial target fails scheme validation never
	# starts, so the handshake credentials must not stay resident in memory
	# until the next dial overwrites them.
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


func _test_duplicate_authenticated_sends_handshake_once() -> void:
	# Issue #21: duplicate `Authenticated` server events are outside the wire
	# contract, but a hostile or buggy server must not trigger a second
	# directed handshake; exactly one Reconnect goes out per dial.
	var client := _make_reconnect_client(TOKEN_V1)
	var auth_bytes := SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))
	var handshake := SFMessagesScript.encode(
		SFMessagesScript.reconnect(PLAYER_A, ROOM_ID, TOKEN_V1)
	)
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal([auth_bytes, handshake], client.transport.sent_text, "handshake sent once")
	_assert_no_protocol_errors()
	client.free()

	# After the handshake completed, duplicates must also stay consumer-
	# silent and leave the restored session state untouched.
	var reconnected_client := _make_reconnect_client(TOKEN_V1)
	reconnected_client.transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	var auth_events: Array = []
	reconnected_client.authenticated.connect(
		func(_app: String, _org: String, _limits) -> void: auth_events.append(1)
	)
	var data := _room_joined_data({"lobby_state": "lobby"})
	data["reconnection_token"] = TOKEN_V2
	data["missed_events"] = []
	reconnected_client.transport.inject_server_message({"type": "Reconnected", "data": data})
	reconnected_client.transport.inject_server_message(
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


func _test_handshake_send_failure_resolves_attempt() -> void:
	# Issue #21: if the directed handshake send fails (here: backpressure),
	# the attempt resolves negatively instead of hanging authenticated-but-
	# roomless: reconnection_failed plus the terminal disconnect fire. Runs
	# without the shared error tracker: the backpressure protocol_error is
	# expected and asserted locally.
	var client := _make_reconnect_client(TOKEN_V1, false)
	var errors := _track_protocol_errors(client)
	var reconnection_failures: Array = []
	var disconnects: Array = []
	var dial = client.transport
	client.reconnection_failed.connect(
		func(reason: String, code: SFErrorCodesScript.Code) -> void:
			reconnection_failures.append([reason, code])
	)
	client.disconnected.connect(func(code: int, _reason: String) -> void: disconnects.append(code))
	# Backpressure the transport only after the Authenticate went out.
	client.transport.buffered_amount = client._config.max_buffered_bytes + 1
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(1, reconnection_failures.size(), "handshake failure resolves the attempt")
	_assert_string_contains(reconnection_failures[0][0], "handshake", "failure reason")
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

	# With auto-reconnect, the failed handshake re-dials from the retained
	# baseline instead of stalling the episode.
	var reconnector := _make_client(true, "token", false)
	var retry_errors := _track_protocol_errors(reconnector)
	reconnector.transport.inject_close(4999, "dropped")
	reconnector.transport = SFFakeTransportScript.new()
	_step(reconnector, 30.0)
	reconnector.transport.inject_open()
	reconnector.transport.buffered_amount = reconnector._config.max_buffered_bytes + 1
	reconnector.transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	# Attempt 1 armed by the drop, attempt 2 re-armed by the failed handshake.
	_assert_equal(2, reconnector._auto_reconnect_attempts, "failed handshake re-arms the retry")
	_assert(reconnector._reconnect_timer_running, "backoff armed after handshake failure")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED, reconnector.get_connection_state(), "closed"
	)
	_assert_equal(1, retry_errors.size(), "exactly the transport diagnostic")
	reconnector.free()


func _test_handshake_send_failure_killing_link_cascades() -> void:
	# Issue #24: a handshake send that kills the link resolves through the
	# transport-failure cascade (`failed` -> connection_failed) instead of the
	# client teardown shape: the send error surfaces, the attempt still
	# resolves negatively, and no `disconnected(-1)` double-fires after the
	# link is already dead. The fake's fail_on_send knob mirrors the real
	# transport's synchronous send-failure cascade, so this shape is now
	# fake-testable.
	var client := _make_reconnect_client(TOKEN_V1, false)
	var errors := _track_protocol_errors(client)
	var connection_failures: Array = []
	var reconnection_failures: Array = []
	var disconnects: Array = []
	client.connection_failed.connect(func(error: String) -> void: connection_failures.append(error))
	client.reconnection_failed.connect(
		func(reason: String, code: SFErrorCodesScript.Code) -> void:
			reconnection_failures.append([reason, code])
	)
	client.disconnected.connect(func(code: int, _reason: String) -> void: disconnects.append(code))
	client.transport.fail_on_send = true
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(1, connection_failures.size(), "dead link surfaces connection_failed once")
	_assert_string_contains(
		connection_failures[0], "send", "transport failure names the failed send"
	)
	_assert_equal(1, reconnection_failures.size(), "attempt still resolves negatively")
	_assert_string_contains(reconnection_failures[0][0], "handshake", "failure reason")
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
	_assert_no_protocol_errors()
	client.free()


func _test_close_from_disconnected_handler_wins_over_retry() -> void:
	var client := _make_client(true, "token")
	client.disconnected.connect(func(_code: int, _reason: String) -> void: client.close())
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"consumer clean close from handler stops auto-reconnect"
	)
	_assert_no_protocol_errors()
	client.free()


func _test_failure_driven_exhaustion_and_budget_recovery() -> void:
	var client := _make_client(true, "token")
	client._config.reconnect_max_attempts = 2
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	# Episode: abnormal drop -> arm(1) -> dial fails -> arm(2) -> dial fails
	# -> exhausted.
	client.transport.inject_close(4999, "dropped")
	for dial: int in [1, 2]:
		client.transport = SFFakeTransportScript.new()
		_step(client, 30.0)
		client.transport.inject_failure("connection refused %d" % dial)
	# Two dial failures plus the exhaustion notice.
	_assert_equal(3, failures.size(), "failure-driven exhaustion emits the final notice")
	_assert_string_contains(failures[2], "exhausted", "final notice reports exhaustion")
	_assert_equal(2, client._auto_reconnect_attempts, "attempts stop at budget")
	_assert_no_protocol_errors()
	client.free()

	# Recovery: a fresh authoritative baseline restarts the spent budget.
	client = _make_client(true, "none")
	client._auto_reconnect_attempts = 2
	var data := _room_joined_data()
	data["reconnection_token"] = TOKEN_V1
	client.transport.inject_server_message({"type": "RoomJoined", "data": data})
	_assert_equal(0, client._auto_reconnect_attempts, "fresh baseline restarts the budget")
	client.transport.inject_close(4999, "dropped")
	client.transport = SFFakeTransportScript.new()
	_step(client, 30.0)
	_assert_equal(OK, _wait_open(client), "recovery after fresh baseline dials")
	_assert_no_protocol_errors()
	client.free()


func _test_reconnect_tokens_are_redacted() -> void:
	var client := _make_client(true, "token")
	_assert(client._secrets.has(TOKEN_V1), "baseline token registered as secret")
	var reconnector := _make_reconnect_client(TOKEN_V2)
	_assert(reconnector._secrets.has(TOKEN_V2), "manual reconnect token registered as secret")
	# Mid-episode reconfigure rebuilds the redaction list; the retained
	# identity must stay on it. Dropping abnormally leaves the context intact.
	client.transport.inject_close(4999, "dropped")
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


# -- helpers -----------------------------------------------------------------


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


func _make_reconnect_client(token: String, track_errors := true) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	if track_errors:
		_error_trackers.append(_track_protocol_errors(client))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.reconnect(PLAYER_A, ROOM_ID, token), "reconnect dial")
	client.transport.inject_open()
	return client


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	var errors: Array = []
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
	# The dial is synchronous on the fake transport: open it, complete the
	# authentication round, and confirm a second wire message follows
	# Authenticate (the exact reconnect bytes are pinned by the callers).
	client.transport.inject_open()
	client.transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
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
	return {
		"app_name": "Reef Rally",
		"organization": "",
		"rate_limits": {"per_minute": 60, "per_hour": 1000, "per_day": 10000},
	}


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
