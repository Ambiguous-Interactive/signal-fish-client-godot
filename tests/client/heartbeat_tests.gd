extends RefCounted

## Issue #91 (PLAN §4.7): the optional heartbeat pings while connected +
## authenticated, and a silent link past `pong_timeout_sec` is a dead link —
## it tears down through the transport-failure path so opt-in auto-reconnect
## engages. Issue #121: the AUTHENTICATING window cannot send protocol Ping,
## but silence there past the pong deadline is the same dead link. All timing
## is injected `_process` delta; no wall-clock sleeps. Receives the client
## runner so config/transport fakes stay in one place.

const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
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
		_test_heartbeat_off_by_default,
		_test_interval_pong_cycle_and_dead_link,
		_test_backpressured_beats_retry_quietly,
		_test_dead_link_arms_auto_reconnect,
		_test_auth_window_silence_is_a_dead_link,
		_test_auth_landing_disarms_the_watchdog,
		_test_closing_silence_is_a_dead_link,
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
	var failures: Array = []
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
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.heartbeat_interval_sec = 5.0
	config.pong_timeout_sec = 1.0
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	transport.buffered_amount = config.max_buffered_bytes + 1
	var errors: Array = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	client._process(5.0)
	client._process(5.0)
	_assert_equal(0, _sent_type_count(transport, "Ping"), "backpressured beats send nothing")
	_assert_equal(2, errors.size(), "each refused beat explains itself once")
	_assert_connected(client, true, "backpressure alone does not kill the link")
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
	var failures: Array = []
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
	_done()


func _test_closing_silence_is_a_dead_link() -> void:
	# Issue #126: a close handshake on a silently dead link never completes;
	# the CLOSING window must be bounded like the AUTHENTICATING one (#121).
	var config: SignalFishConfigScript = _make_config_with_auth_watchdog()
	var client := _authenticated_client(config)
	var transport: SFFakeTransportScript = client.transport
	transport.hold_close = true
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	var disconnects: Array = []
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
	var clean_disconnects: Array = []
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
