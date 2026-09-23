extends RefCounted

## Issue #104: a runtime error aborts only the running test function — the
## suite keeps going and reports green while every assertion after the abort
## point never ran. Test functions end with the owner's `_done()`; drive()
## flags any case that never reaches it, and check_registration() flags any
## `_test_` method missing from the case list.


static func drive(owner: Object, cases: Array, failures: Array) -> void:
	for case: Callable in cases:
		owner.set("_test_done", false)
		case.call()
		if owner.get("_test_done") != true:
			failures.append("%s aborted before completion" % case.get_method())


static func check_registration(owner: Object, cases: Array, failures: Array) -> void:
	var driven := {}
	for case: Callable in cases:
		driven[String(case.get_method())] = true
	for method: Dictionary in owner.get_method_list():
		var name: String = method["name"]
		if name.begins_with("_test_") and not driven.has(name):
			failures.append("%s is not in the case list" % name)


## Pins the guard itself: an incomplete case must be flagged, a completing
## case must not. Snapshot-restore keeps the host suite green.
static func self_check(owner: Object, failures: Array) -> void:
	var base := failures.size()
	drive(owner, [func() -> void: pass], failures)
	var flagged := failures.size() > base
	failures.resize(base)
	drive(owner, [func() -> void: owner.call("_done")], failures)
	if not flagged or failures.size() != base:
		failures.append("completion guard self-check failed")
