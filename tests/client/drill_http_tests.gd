extends RefCounted

const HttpScript = preload("res://tests/smoke/webrtc_http_request.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array[String] = []
var _test_done := false


class FakeRequest:
	extends HttpScript
	var posts: Array[Dictionary] = []
	var cancelled := false

	func request(
		url: String, _headers := PackedStringArray(), _method := HTTPClient.METHOD_GET, body := ""
	) -> int:
		var message: Dictionary = JSON.parse_string(body)
		posts.append({"to": int(url.get_file()), "message": message})
		_busy = true
		_active = {"method": HTTPClient.METHOD_POST, "markers": [message["marker"]]}
		return OK

	func cancel_request() -> void:
		cancelled = true
		super.cancel_request()

	func complete(code := 200) -> void:
		_on_native_completed(
			HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(), PackedByteArray()
		)


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [_test_independent_destinations]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)


func _test_independent_destinations() -> void:
	var script: Script = load("res://tests/smoke/webrtc_interop_drill.gd")
	var drill: Object = script.call("new")
	var first := FakeRequest.new()
	var second := FakeRequest.new()
	var inbox := FakeRequest.new()
	drill.set("_inbox", inbox)
	drill.set("_outbox", first)
	drill.set("_outboxes", {1: first, 2: second})
	drill.set("_next_poll", 9223372036854775807)
	drill.set("_next_progress", 9223372036854775807)
	first.request_completed.connect(Callable(drill, "_on_outbox").bind(1))
	var pending: Array[Dictionary] = [
		{"to": 1, "marker": "credit-a-8"},
		{"to": 1, "marker": "credit-a-16"},
		{"to": 2, "marker": "credit-b-8"},
	]
	drill.set("_pending", pending)
	drill.call("_process", 0.0)
	drill.call("_process", 0.0)
	_assert_equal(1, second.posts.size(), "held destination does not block another destination")
	_assert_equal(1, first.posts.size(), "held destination keeps its next message queued")
	if not second.posts.is_empty():
		_assert_equal(
			"credit-b-8", second.posts[0]["message"]["marker"], "other credit is dispatched"
		)

	second.request_completed.connect(Callable(drill, "_on_outbox").bind(2))
	if not second.posts.is_empty():
		second.complete()
		_assert_equal(true, drill.get("_sending"), "other destination remains in flight")
		var held: Dictionary = drill.call("_outbox_evidence")
		var active: Dictionary = held["active"]
		_assert_equal(["credit-a-8"], active["markers"], "oldest active request remains visible")
	first.complete()
	drill.call("_process", 0.0)
	_assert_equal(2, first.posts.size(), "next message starts after destination completion")
	if first.posts.size() == 2:
		_assert_equal(
			"credit-a-16", first.posts[1]["message"]["marker"], "destination FIFO is preserved"
		)
	var evidence: Dictionary = drill.call("_outbox_evidence")
	_assert_equal(2, evidence["completed"], "completed requests aggregate across destinations")
	_assert_equal(
		2, evidence["marker_count"], "completed marker histories retain both destinations"
	)
	drill.set("_failed", true)
	drill.call("_cancel_outboxes")
	first.request_completed.emit(
		HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray()
	)
	_assert_equal(2, drill.get("_signal_sent"), "late completion after failure is ignored")
	_assert_equal(true, first.cancelled, "cleanup cancels first destination")
	_assert_equal(true, second.cancelled, "cleanup cancels second destination")
	drill.free()
	first.free()
	second.free()
	inbox.free()
	_done()
