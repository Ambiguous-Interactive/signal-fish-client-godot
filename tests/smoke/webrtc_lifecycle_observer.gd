extends RefCounted

const LIMIT := 256

var _states: Dictionary = {}
var _events: Array[Dictionary] = []
var _dropped := 0
var _sequence := 0


func observe(states: Array[Dictionary], context: Dictionary) -> Array[Dictionary]:
	var emitted: Array[Dictionary] = []
	var current: Dictionary = {}
	for state: Dictionary in states:
		var identity: int = state["connection_instance"]
		current[identity] = state.duplicate(true)
		if not _states.has(identity) or _states[identity] != state:
			var kind := "added" if not _states.has(identity) else "changed"
			var event := _append(kind, {"peer": state}, context)
			if not event.is_empty():
				emitted.append(event)
	for identity: int in _states:
		if not current.has(identity):
			var event := _append("removed", {"last_observed_peer": _states[identity]}, context)
			if not event.is_empty():
				emitted.append(event)
	_states = current
	return emitted


func boundary(action: String, details: Dictionary, context: Dictionary) -> Dictionary:
	return _append("boundary", {"action": action, "details": details}, context)


func evidence() -> Dictionary:
	return {"events": _events.duplicate(true), "dropped": _dropped, "observed": _sequence}


func _append(kind: String, details: Dictionary, context: Dictionary) -> Dictionary:
	_sequence += 1
	if _events.size() >= LIMIT:
		_dropped += 1
		return {}
	var event := context.duplicate(true)
	event.merge(details.duplicate(true))
	event["kind"] = kind
	event["sequence"] = _sequence
	_events.append(event.duplicate(true))
	return event
