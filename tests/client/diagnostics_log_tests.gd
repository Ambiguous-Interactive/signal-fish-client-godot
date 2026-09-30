extends RefCounted

## Transport log diagnostics tests (issue #282). Relay-controlled close
## reasons and transport failure text must render bounded and single-line
## while the signals keep the raw values; receives the client runner
## instance so connect/auth fakes stay defined in one place.

const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
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
		_test_transport_log_lines_render_bounded,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	return _runner.call("_assert_equal", expected, actual, label)


## Issue #282: relay-controlled close reasons and transport failure text
## used to reach the transport log lines raw. Each now renders capped and
## escaped (one bounded line), while the signals keep the raw wire values.
func _test_transport_log_lines_render_bounded() -> void:
	var hostile := "ok\nEVIL" + "z".repeat(30)
	var hostile_rendered := '"ok\\x0AEVIL' + "z".repeat(25) + '"'
	var rows: Array[Array] = [
		# [close code, reason, expected rendered token]
		[4400, hostile, hostile_rendered],
		[1000, "bye", '"bye"'],
		[1000, "", '""'],
		[1000, "a".repeat(32), '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'],
		[1000, "x\u0085y", '"x\\x85y"'],
	]
	var original_level: int = SFLogScript.min_level
	SFLogScript.min_level = SFLogScript.Level.INFO
	for row: Array in rows:
		var lines: Array[String] = []
		SFLogScript.sink = func(line: String) -> void: lines.append(line)
		var client: SignalFishClientScript = _runner.call("_make_in_room_client")
		var fake: SFFakeTransportScript = client.transport
		var closes: Array[Array] = []
		client.disconnected.connect(
			func(code: int, reason: String) -> void: closes.append([code, reason])
		)
		var close_code: int = row[0]
		var close_reason: String = row[1]
		fake.inject_close(close_code, close_reason)
		_assert_equal(
			["[signal_fish] transport closed (code %d): %s" % [close_code, row[2]]],
			lines,
			"close log renders bounded (%d)" % close_code
		)
		_assert_equal([[close_code, close_reason]], closes, "close signal keeps the raw reason")
		client.free()

	# The failure line keeps the code-owned prefix readable; only the
	# wire-derived tail is capped. A ": " inside the relay's tail must
	# not move the split, and separator-free text is code-owned, so it
	# stays whole.
	var fail_rows: Array[Array] = [
		[
			"WebSocket connection failed before open: " + hostile,
			(
				"[signal_fish] transport failed: WebSocket connection failed before open: %s"
				% hostile_rendered
			),
		],
		[
			"WebSocket connection failed before open: evil: " + "z".repeat(40),
			(
				'[signal_fish] transport failed: WebSocket connection failed before open: "evil: '
				+ "z".repeat(26)
				+ '"'
			),
		],
		[
			"invalid WebSocket URL scheme; expected ws:// or wss://",
			"[signal_fish] transport failed: invalid WebSocket URL scheme; expected ws:// or wss://",
		],
	]
	for fail_row: Array in fail_rows:
		var failed_lines: Array[String] = []
		SFLogScript.sink = func(line: String) -> void: failed_lines.append(line)
		var fail_client: SignalFishClientScript = _runner.call("_make_in_room_client")
		var fail_fake: SFFakeTransportScript = fail_client.transport
		var failures: Array[String] = []
		fail_client.connection_failed.connect(func(error: String) -> void: failures.append(error))
		var fail_error: String = fail_row[0]
		fail_fake.inject_failure(fail_error)
		_assert_equal([fail_row[1]], failed_lines, "failure log bounds the tail")
		_assert_equal([fail_error], failures, "failure signal keeps the raw text")
		fail_client.free()

	# A secret the relay echoes back is redacted before the render, so no
	# raw token characters reach the log even inside the cap window.
	var secret_lines: Array[String] = []
	SFLogScript.sink = func(line: String) -> void: secret_lines.append(line)
	var secret_client: SignalFishClientScript = _runner.call("_make_in_room_client")
	secret_client._remember_secret("s3cret-token")
	var secret_fake: SFFakeTransportScript = secret_client.transport
	secret_fake.inject_close(4400, "s3cret-token\nEVIL" + "z".repeat(30))
	_assert_equal(
		[
			(
				"[signal_fish] transport closed (code 4400): "
				+ '"[REDACTED]\\x0AEVIL'
				+ "z".repeat(17)
				+ '"'
			)
		],
		secret_lines,
		"close log redacts secrets before bounding"
	)
	secret_client.free()

	SFLogScript.sink = Callable()
	SFLogScript.min_level = original_level
	_done()
