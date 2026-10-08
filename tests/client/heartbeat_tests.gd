extends RefCounted

## Issue #91 (PLAN §4.7): the optional heartbeat pings while connected +
## authenticated, and a silent link past `pong_timeout_sec` is a dead link —
## it tears down through the transport-failure path so opt-in auto-reconnect
## engages. Issue #121: the AUTHENTICATING window cannot send protocol Ping,
## but silence there past the pong deadline is the same dead link. All timing
## is injected `_process` delta; no wall-clock sleeps. Receives the client
## runner so config/transport fakes stay in one place.

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
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
		_test_heartbeat_off_by_default,
		_test_interval_pong_cycle_and_dead_link,
		_test_backpressured_beats_retry_quietly,
		_test_backpressured_dead_link_fails_and_reconnects,
		_test_dead_link_arms_auto_reconnect,
		_test_auth_window_silence_is_a_dead_link,
		_test_auth_landing_disarms_the_watchdog,
		_test_closing_silence_is_a_dead_link,
		_test_default_config_bounds_the_silence_windows,
		_test_post_auth_error_silence_is_a_dead_link,
		_test_refocus_delta_drains_buffered_progress_first,
		_test_dial_silence_is_a_dead_link,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _test_heartbeat_off_by_default() -> void:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	var idle := _authenticated_client(config)
	var transport: SFFakeTransportScript = idle.transport
	for _tick: int in 200:
		idle._process(1.0)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "heartbeat off sends no pings")
	idle.free()
	_done()


func _test_interval_pong_cycle_and_dead_link() -> void:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 10.0
	config.pong_timeout_sec = 5.0
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	client._process(9.9)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "pre-interval tick sends nothing")
	client._process(0.1)
	_assert_equal(1, _sent_type_count(transport, "Ping"), "interval elapses exactly one ping")
	client._process(4.9)
	_assert_equal(1, _sent_type_count(transport, "Ping"), "awaiting pong sends no second ping")
	_assert_connected(client, true, "inside the pong window the link stays up")
	transport.inject_server_message({"type": "Pong"})
	client._process(10.0)
	_assert_equal(2, _sent_type_count(transport, "Ping"), "pong re-arms the cycle")
	client._process(4.9)
	_assert_connected(client, true, "a fresh pong window stays up")
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client._process(0.1)
	if _assert_equal(1, failures.size(), "silent link past the pong window fails"):
		var failure: String = failures[0]
		_assert(failure.contains("pong timeout"), "the failure names the pong timeout")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the dead link ends FAILED"
	)
	_assert_equal(null, client.transport, "the dead link is torn down")
	client.free()
	_done()


func _test_backpressured_beats_retry_quietly() -> void:
	# Issue #128: a refused beat still arms the pong deadline, but the beat
	# keeps retrying each interval and the deadline spares a link that
	# drains and answers Pong — backpressure alone is not a dead link.
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 1.0
	config.pong_timeout_sec = 5.0
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	transport.buffered_amount = config.max_buffered_bytes + 1
	var errors: Array[String] = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	client._process(1.0)
	client._process(1.0)
	client._process(1.0)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "backpressured beats send nothing")
	_assert_equal(3, errors.size(), "each refused beat explains itself once")
	_assert_connected(client, true, "backpressure alone does not kill the link")
	# Any inbound Pong proves the link alive and clears the refused-beat
	# deadline: the saturated link stays up past the original expiry
	# (t=6 here) on the fresh window the next refused beat armed.
	transport.inject_server_message({"type": "Pong"})
	client._process(1.0)
	client._process(1.0)
	client._process(1.0)
	client._process(1.0)
	_assert_connected(client, true, "a Pong clears the refused-beat deadline")
	_assert_equal(7, errors.size(), "each refused beat still explains itself once")
	transport.buffered_amount = 0
	client._process(1.0)
	_assert_equal(1, _sent_type_count(transport, "Ping"), "a drained link delivers the beat")
	transport.inject_server_message({"type": "Pong"})
	client._process(1.0)
	_assert_equal(2, _sent_type_count(transport, "Ping"), "pong re-arms the cycle")
	_assert_connected(client, true, "the recovered link keeps beating")
	client.free()
	_done()


func _test_backpressured_dead_link_fails_and_reconnects() -> void:
	# Issue #128: under sustained backpressure a silently dead link used to
	# sit CONNECTED forever because a refused beat never armed a pong
	# deadline; the armed deadline must fail it and engage auto-reconnect.
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 5.0
	config.pong_timeout_sec = 1.0
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_server_message(
		{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
	)
	(
		transport
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data": _runner.call("_room_joined_data", {"reconnection_token": "bp-token"}),
			}
		)
	)
	client.set_auto_reconnect(true)
	transport.buffered_amount = config.max_buffered_bytes + 1
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client._process(5.0)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "the refused beat sends nothing")
	_assert_connected(client, true, "the armed deadline waits out the pong window")
	client._process(1.0)
	if _assert_equal(1, failures.size(), "a backpressured dead link fails"):
		var failure: String = failures[0]
		_assert(failure.contains("pong timeout"), "the failure names the pong timeout")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the backpressured dead link ends FAILED"
	)
	client.transport = SFFakeTransportScript.new()
	client._process(1.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"auto-reconnect redials the backpressured dead link"
	)
	client.free()
	_done()


func _test_dead_link_arms_auto_reconnect() -> void:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 5.0
	config.pong_timeout_sec = 1.0
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	(
		transport
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data": _runner.call("_room_joined_data", {"reconnection_token": "hb-token"}),
			}
		)
	)
	client.set_auto_reconnect(true)
	client._process(5.0)
	_assert_equal(1, _sent_type_count(transport, "Ping"), "beat fires before the drop")
	client._process(1.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"dead link fails with auto-reconnect armed"
	)
	client.transport = SFFakeTransportScript.new()
	client._process(1.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"auto-reconnect redials the dead link"
	)
	client.free()
	_done()


func _test_auth_window_silence_is_a_dead_link() -> void:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 10.0
	config.pong_timeout_sec = 5.0
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client._process(4.9)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "protocol Ping is not sent pre-auth")
	_assert_connected(client, true, "inside the auth window the link stays up")
	client._process(0.1)
	if _assert_equal(1, failures.size(), "silent link through the auth window fails"):
		var failure: String = failures[0]
		_assert(failure.contains("heartbeat auth timeout"), "the failure names the auth timeout")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the stranded auth window ends FAILED"
	)
	_assert_equal(null, client.transport, "the dead link is torn down")
	client.free()
	# The dial and the auth window are separate budgets: a slow dial must not
	# eat the auth window, which measures from the open (issue #341 review).
	client = _runner.call("_connect_new_client", config)
	transport = client.transport
	failures.clear()
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client._process(4.5)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"inside the dial window a slow dial waits"
	)
	transport.inject_open()
	client._process(0.7)
	_assert_connected(
		client, true, "a slow dial does not shorten the auth window that follows it"
	)
	client._process(4.4)
	if _assert_equal(1, failures.size(), "the post-dial auth window still bounds silence"):
		_assert(failures[0].contains("auth timeout"), "the failure names the auth timeout")
	client.free()
	_done()


func _test_closing_silence_is_a_dead_link() -> void:
	# Issue #126: a close handshake on a silently dead link never completes;
	# the CLOSING window must be bounded like the AUTHENTICATING one (#121).
	var config: SignalFishConfigScript = _make_config_with_auth_watchdog()
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	transport.hold_close = true
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var disconnects: Array[String] = []
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void: disconnects.append("disconnected")
	)
	client.close()
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSING,
		client.get_connection_state(),
		"a held close leaves the client CLOSING"
	)
	client._process(4.9)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSING,
		client.get_connection_state(),
		"inside the closing window the client waits"
	)
	client._process(0.2)
	if _assert_equal(1, failures.size(), "a close that never completes fails"):
		var failure: String = failures[0]
		_assert(failure.contains("heartbeat close timeout"), "the failure names the close timeout")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the stranded closing window ends FAILED"
	)
	_assert_equal(null, client.transport, "the dead link is torn down")
	_assert_equal([], disconnects, "a failed close is not reported as a clean disconnect")
	client.free()
	# A completing close still ends cleanly: hold off, close again, tick.
	client = _authenticated_client(config)
	transport = client.transport
	var clean_disconnects: Array[String] = []
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void: clean_disconnects.append("disconnected")
	)
	client.close()
	client._process(0.2)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"a completing close still ends CLOSED"
	)
	_assert_equal(1, clean_disconnects.size(), "a completing close reports the disconnect")
	client.free()
	_done()


func _test_auth_landing_disarms_the_watchdog() -> void:
	var config: SignalFishConfigScript = _make_config_with_auth_watchdog()
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	client._process(4.9)
	transport.inject_server_message(
		{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
	)
	client._process(0.2)
	_assert_connected(client, true, "auth landing inside the window saves the link")
	client._process(4.9)
	_assert_equal(1, _sent_type_count(transport, "Ping"), "the ping cycle arms once authenticated")
	client.free()
	# A reconnection identity exists (in-room session); kill the live link so
	# auto-reconnect dials a fresh link whose AUTHENTICATING window the
	# watchdog now covers.
	client = _make_auth_watchdog_reconnect_client(config)
	client._process(10.0)
	client._process(5.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the first dead link arms the retry"
	)
	client.transport = SFFakeTransportScript.new()
	client._process(1.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"the retry redials"
	)
	transport = client.transport
	transport.inject_open()
	_assert_connected(client, true, "the reconnect dial opens into its auth window")
	client._process(4.9)
	_assert_connected(client, true, "the watchdog spares a live reconnect dial")
	client._process(0.2)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"an auth-window death on the reconnect dial re-arms the retry"
	)
	client.transport = SFFakeTransportScript.new()
	# 1.25 s: the attempt-2 backoff upper bound (0.5 * 2 * 1.25 jitter cap).
	client._process(1.25)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"auto-reconnect redials the stranded reconnect dial"
	)
	client.free()
	_done()


## An authenticated in-room session (reconnection identity captured).
func _test_default_config_bounds_the_silence_windows() -> void:
	# Issues #121/#126 with the heartbeat off: both silence deadlines send
	# nothing, so they must not depend on the opt-in ping cadence. A link
	# that accepts and then silences must fail past the pong deadline and
	# let auto-reconnect engage instead of wedging every recovery entry.
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.pong_timeout_sec = 5.0

	# AUTHENTICATING window: an open link that never delivers Authenticated.
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	var failures: Array[String] = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	client._process(4.9)
	_assert_connected(client, true, "inside the default-config auth window the link waits")
	client._process(0.2)
	if _assert_equal(1, failures.size(), "default-config auth silence fails the link"):
		_assert(
			failures[0].contains("heartbeat auth timeout"), "the failure names the auth timeout"
		)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the stranded default-config auth window ends FAILED"
	)
	client.free()

	# CLOSING window: a close handshake the peer never completes. The user's
	# close must win: the deadline fails the link without redialing.
	client = _authenticated_client(config)
	transport = client.transport
	transport.hold_close = true
	client.set_auto_reconnect(true)
	failures = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var disconnects: Array[String] = []
	client.disconnected.connect(
		func(_code: int, _reason: String) -> void: disconnects.append("disconnected")
	)
	client.close()
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSING,
		client.get_connection_state(),
		"a held default-config close leaves the client CLOSING"
	)
	client._process(4.9)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSING,
		client.get_connection_state(),
		"inside the default-config closing window the client waits"
	)
	client._process(0.2)
	if _assert_equal(1, failures.size(), "a default-config close that never completes fails"):
		_assert(
			failures[0].contains("heartbeat close timeout"), "the failure names the close timeout"
		)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the stranded default-config closing window ends FAILED"
	)
	_assert_equal([], disconnects, "a failed close is not reported as a clean disconnect")
	client._process(30.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"a user close never redials after the close deadline"
	)
	client.free()

	# Auto-reconnect payoff: a reconnect dial that opens and then silences in
	# AUTHENTICATING re-arms the retry budget instead of stalling the episode.
	client = _make_auth_watchdog_reconnect_client(config)
	var live_transport: SFFakeTransportScript = client.transport
	live_transport.inject_failure("dead link")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"the dead link arms the retry"
	)
	client.transport = SFFakeTransportScript.new()
	client._process(1.0)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"the retry redials"
	)
	transport = client.transport
	transport.inject_open()
	client._process(4.9)
	_assert_connected(client, true, "the default-config watchdog spares a live reconnect dial")
	client._process(0.2)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"an auth-window death on a default-config reconnect dial re-arms the retry"
	)
	client.transport = SFFakeTransportScript.new()
	client._process(1.25)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		client.get_connection_state(),
		"auto-reconnect redials the stranded default-config dial"
	)
	client.free()
	_done()


func _test_post_auth_error_silence_is_a_dead_link() -> void:
	# Issue #346: a mid-session AuthenticationError leaves the client
	# CONNECTED + UNAUTHENTICATED, where the ping cycle is disarmed and every
	# recovery entry refuses. The honest server closes the link right after
	# the error; a relay that holds the socket open must not wedge the
	# client forever, so the same pong deadline the AUTHENTICATING window
	# uses fails the link and arms auto-reconnect.
	for heartbeat_interval_sec: float in [0.0, 10.0]:
		var config: SignalFishConfigScript = _runner.call("_make_config")
		config.heartbeat_interval_sec = heartbeat_interval_sec
		config.pong_timeout_sec = 5.0
		var client := _authenticated_client(config)
		var transport: SFFakeTransportScript = client.transport
		(
			transport
			. inject_server_message(
				{
					"type": "RoomJoined",
					"data": _runner.call("_room_joined_data", {"reconnection_token": "ae-token"}),
				}
			)
		)
		client.set_auto_reconnect(true)
		# Accrue ping-cycle time before the error: the deadline must measure
		# from the error, so this residual must not fire it early (issue
		# #346). The heartbeat-off leg accrues nothing and is the control.
		client._process(4.9)
		transport.inject_server_message(
			{
				"type": "AuthenticationError",
				"data": {"error": "session revoked", "error_code": "UNAUTHORIZED"}
			}
		)
		_assert_equal(
			SignalFishClientScript.SessionState.UNAUTHENTICATED,
			client.get_session_state(),
			"the error lands the session in UNAUTHENTICATED"
		)
		var failures: Array[String] = []
		client.connection_failed.connect(func(error: String) -> void: failures.append(error))
		client._process(4.9)
		_assert_connected(client, true, "inside the post-error window the link waits")
		client._process(0.2)
		if _assert_equal(1, failures.size(), "post-error silence fails the link"):
			_assert(
				failures[0].contains("heartbeat auth timeout"),
				"the failure names the auth silence deadline"
			)
		_assert_equal(
			SignalFishClientScript.ConnectionState.FAILED,
			client.get_connection_state(),
			"the held-open post-error link ends FAILED"
		)
		_assert_equal(null, client.transport, "the dead link is torn down")
		client.transport = SFFakeTransportScript.new()
		client._process(1.0)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTING,
			client.get_connection_state(),
			"auto-reconnect redials the held-open link"
		)
		client.free()
	_done()


func _test_refocus_delta_drains_buffered_progress_first() -> void:
	# Issue #341: a hidden browser tab suspends rAF, so the first frame after
	# refocus carries the whole hidden duration as one delta. Frames the peer
	# already delivered sit buffered in the socket; they must drain before the
	# watchdog judges liveness, or a tab hidden inside AUTHENTICATING or
	# CLOSING fails a session whose completion already arrived.
	for close_case: bool in [false, true]:
		var config: SignalFishConfigScript = _runner.call("_make_config")
		config.pong_timeout_sec = 5.0
		var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
		var stale: SFFakeTransportScript = client.transport
		stale.inject_failure("swap in the queued transport")
		var transport: QueuedTransport = QueuedTransport.new()
		client.transport = transport
		if not _assert_equal(
			OK, client.connect_to_server("ws://example.test/socket"), "queued transport dials"
		):
			client.free()
			continue
		transport.inject_open()
		transport.queued_messages.append(
			{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
		)
		var failures: Array[String] = []
		client.connection_failed.connect(func(error: String) -> void: failures.append(error))
		var disconnects: Array[String] = []
		client.disconnected.connect(
			func(_code: int, _reason: String) -> void: disconnects.append("d")
		)
		if close_case:
			client._process(0.1)
			transport.hold_close = true
			client.close()
			_assert_equal(
				SignalFishClientScript.ConnectionState.CLOSING,
				client.get_connection_state(),
				"a held close leaves the refocus client CLOSING"
			)
			transport.queued_close_code = 1000
			transport.queued_close_reason = ""
		client._process(60.0)
		_assert(failures.is_empty(), "the buffered progress spares the refocus delta")
		if close_case:
			_assert_equal(
				SignalFishClientScript.ConnectionState.CLOSED,
				client.get_connection_state(),
				"the buffered close completes on the refocus frame"
			)
			_assert_equal(1, disconnects.size(), "the buffered close still reports the disconnect")
		else:
			_assert_connected(client, true, "the buffered auth lands on the refocus frame")
		client.free()
	_done()


func _test_dial_silence_is_a_dead_link() -> void:
	# Issue #341: the CONNECTING dial was the last unbounded watchdog window.
	# A dial that never completes (black-holed SYN, accept without upgrade)
	# left the client CONNECTING forever with every recovery entry refusing;
	# past the pong deadline it must fail through the standard transport path
	# so auto-reconnect counts the attempt and redials.
	for heartbeat_interval_sec: float in [0.0, 10.0]:
		var config: SignalFishConfigScript = _runner.call("_make_config")
		config.heartbeat_interval_sec = heartbeat_interval_sec
		config.pong_timeout_sec = 5.0

		# A dial that never opens.
		var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
		var failures: Array[String] = []
		client.connection_failed.connect(func(error: String) -> void: failures.append(error))
		client._process(4.9)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTING,
			client.get_connection_state(),
			"inside the dial window the client waits"
		)
		client._process(0.2)
		if _assert_equal(1, failures.size(), "a dial that never completes fails"):
			_assert(
				failures[0].contains("heartbeat dial timeout"), "the failure names the dial timeout"
			)
		_assert_equal(
			SignalFishClientScript.ConnectionState.FAILED,
			client.get_connection_state(),
			"the stranded dial ends FAILED"
		)
		_assert_equal(null, client.transport, "the timed-out dial is torn down")
		client.free()

		# Auto-reconnect payoff: the redial after a hidden-tab-sized countdown
		# frame starts its own window, and a timed-out retry dial re-arms the
		# budget instead of stalling the episode.
		client = _make_auth_watchdog_reconnect_client(config)
		client.connection_failed.connect(func(error: String) -> void: failures.append(error))
		var live: SFFakeTransportScript = client.transport
		live.inject_failure("dead link")
		failures.clear()
		client.transport = SFFakeTransportScript.new()
		client._process(60.0)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTING,
			client.get_connection_state(),
			"the refocus frame redials and the fresh dial survives it"
		)
		client._process(4.9)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTING,
			client.get_connection_state(),
			"the fresh dial's window measures from the dial"
		)
		client._process(0.2)
		if _assert_equal(1, failures.size(), "the stranded retry dial fails"):
			_assert(
				failures[0].contains("heartbeat dial timeout"),
				"the retry failure names the dial timeout"
			)
		client.transport = SFFakeTransportScript.new()
		client._process(1.25)
		_assert_equal(
			SignalFishClientScript.ConnectionState.CONNECTING,
			client.get_connection_state(),
			"a timed-out dial counts as an attempt and re-arms the retry"
		)
		client.free()

		# A user close during the dial still wins: the CLOSING deadline fails
		# the held close without redialing.
		client = _runner.call("_connect_new_client", config)
		var dial_transport: SFFakeTransportScript = client.transport
		dial_transport.hold_close = true
		client.close()
		client._process(30.0)
		_assert_equal(
			SignalFishClientScript.ConnectionState.FAILED,
			client.get_connection_state(),
			"a user close during the dial ends the session"
		)
		_assert_equal(null, client.transport, "the closed dial is torn down")
		client.free()

	# A synchronous redial starts its own watchdog window: no deadline from
	# the dead link survives into the fresh dial.
	var fresh_config: SignalFishConfigScript = _runner.call("_make_config")
	fresh_config.pong_timeout_sec = 5.0
	var redial_client: SignalFishClientScript = _runner.call("_connect_new_client", fresh_config)
	var dead: SFFakeTransportScript = redial_client.transport
	dead.inject_open()
	redial_client._process(4.9)
	dead.inject_failure("dead link")
	redial_client.transport = SFFakeTransportScript.new()
	redial_client.connect_to_server("ws://example.test/socket")
	redial_client._process(0.2)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		redial_client.get_connection_state(),
		"a redial does not inherit the dead link's clock"
	)
	redial_client._process(4.7)
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTING,
		redial_client.get_connection_state(),
		"the redial's window measures from the dial"
	)
	redial_client._process(0.2)
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		redial_client.get_connection_state(),
		"and the redial still dies past its own window"
	)
	redial_client.free()
	_done()


class QueuedTransport:
	extends "res://tests/transport/sf_fake_transport.gd"

	## Buffers progress until the next poll(): a real transport's delivered
	## frames wait in the engine buffer, so one frame can carry both a
	## refocus-sized delta and the peer's answer (issue #341).
	var queued_messages: Array[Dictionary] = []
	var queued_close_code := -1
	var queued_close_reason := ""

	func poll() -> void:
		for message: Dictionary in queued_messages:
			inject_server_message(message)
		queued_messages.clear()
		if queued_close_code >= 0:
			inject_close(queued_close_code, queued_close_reason)
			queued_close_code = -1
			queued_close_reason = ""


func _make_auth_watchdog_reconnect_client(config: SignalFishConfigScript) -> SignalFishClientScript:
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_server_message(
		{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
	)
	(
		transport
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data": _runner.call("_room_joined_data", {"reconnection_token": "hb-token"}),
			}
		)
	)
	client.set_auto_reconnect(true)
	return client


func _make_config_with_auth_watchdog() -> SignalFishConfigScript:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 10.0
	config.pong_timeout_sec = 5.0
	return config


func _authenticated_client(config: SignalFishConfigScript) -> SignalFishClientScript:
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	transport.inject_server_message(
		{"type": "Authenticated", "data": _runner.call("_authenticated_data")}
	)
	return client


func _assert_connected(client: SignalFishClientScript, expected: bool, label: String) -> void:
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTED,
		client.get_connection_state(),
		label if expected else "%s (unexpected state)" % label
	)


func _sent_type_count(transport: SFFakeTransportScript, type_name: String) -> int:
	var count := 0
	for text: String in transport.sent_text:
		var envelope: Variant = JSON.parse_string(text)
		if envelope is Dictionary:
			var parsed: Dictionary = envelope
			if parsed.get("type", "") == type_name:
				count += 1
	return count


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
