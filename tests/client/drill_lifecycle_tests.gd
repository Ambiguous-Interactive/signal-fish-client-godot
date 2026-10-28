extends RefCounted

const ObserverScript = preload("res://tests/smoke/webrtc_lifecycle_observer.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array[String] = []
var _test_done := false


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [_test_replacement_and_boundaries, _test_bounded_history]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)


func _test_replacement_and_boundaries() -> void:
	var observer := ObserverScript.new()
	var context := {"tick_us": 100, "phase": 1, "seat": 0}
	var states: Array[Dictionary] = [
		{
			"connection_instance": 10,
			"generation": "first",
			"channels": [{"instance": 11, "state": 1}]
		}
	]
	var added := observer.observe(states, context)
	_assert_equal(1, added.size(), "new physical connection is observed")
	_assert_equal([], observer.observe(states, context), "unchanged state does not fill history")
	states[0]["channels"][0]["state"] = 2
	var changed := observer.observe(states, context)
	_assert_equal("changed", changed[0]["kind"], "channel state transition is retained")
	observer.boundary("before-close", {"peers": states}, context)
	context["tick_us"] = 200
	states[0]["connection_instance"] = 20
	states[0]["generation"] = "second"
	var replaced := observer.observe(states, context)
	_assert_equal(2, replaced.size(), "same logical peer retains both physical identities")
	_assert_equal("added", replaced[0]["kind"], "replacement identity is added")
	_assert_equal("removed", replaced[1]["kind"], "old identity removal is explicit")
	_assert_equal(
		10, replaced[1]["last_observed_peer"]["connection_instance"], "removed identity survives"
	)
	var evidence := observer.evidence()
	var events: Array = evidence["events"]
	_assert_equal(1, events[0]["peer"]["channels"][0]["state"], "old state is copied")
	_assert_equal(100, events[0]["tick_us"], "old clock sample is copied")
	_assert_equal(
		10, events[2]["details"]["peers"][0]["connection_instance"], "close boundary is copied"
	)
	events.clear()
	var retained: Array = observer.evidence()["events"]
	_assert_equal(5, retained.size(), "evidence callers cannot erase history")
	_done()


func _test_bounded_history() -> void:
	var observer := ObserverScript.new()
	var state: Array[Dictionary] = [{"connection_instance": 10, "state": 0}]
	for index: int in ObserverScript.LIMIT + 3:
		state[0]["state"] = index
		observer.observe(state, {"tick_us": index})
	var evidence := observer.evidence()
	var events: Array = evidence["events"]
	_assert_equal(ObserverScript.LIMIT, events.size(), "history has a fixed bound")
	_assert_equal(3, evidence["dropped"], "overflow remains visible")
	_assert_equal(ObserverScript.LIMIT + 3, evidence["observed"], "overflow counts all transitions")
	_assert_equal(
		[], observer.observe(state, {"tick_us": 1000}), "overflow still updates current state"
	)
	_assert_equal(3, observer.evidence()["dropped"], "unchanged overflow does not inflate loss")
	_done()
