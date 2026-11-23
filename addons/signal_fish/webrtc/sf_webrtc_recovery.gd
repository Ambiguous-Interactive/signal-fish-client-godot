extends RefCounted

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const TAG := "MeshRecovery"
const MAX_ATTEMPTS := 3
const MAX_EARLY_CANDIDATES := 16

var peer: String
var local_player: String
var room: String
var generation: String
var local_epoch: int
var remote_epoch: int
var initiate: bool
var retired := false
var was_ready := false
var attempt := 0
var request_count := 0
var due := -1
var expires := -1
var last_offer_attempt := 0
var offer_probe: Offer
var installing_offer: Offer
var _early_ice: Dictionary = {}


func retire() -> void:
	retired = true
	installing_offer = null
	_early_ice.clear()
	replace_offer_probe()


func replace_offer_probe(next: Offer = null) -> void:
	var previous := offer_probe
	offer_probe = next
	if previous != null:
		discard_ice(previous.attempt)
		previous.close()


func offer_for_ice(attempt_number: int) -> Offer:
	if installing_offer != null and installing_offer.attempt == attempt_number:
		return installing_offer
	if offer_probe != null and offer_probe.attempt == attempt_number:
		return offer_probe
	return null


func buffer_ice(attempt_number: int, candidate: String) -> void:
	if attempt_number < 1 or attempt_number > MAX_ATTEMPTS:
		return
	var candidates := queued_ice(attempt_number)
	if candidates.size() < MAX_EARLY_CANDIDATES:
		candidates.append(candidate)


func queued_ice(attempt_number: int) -> Array[String]:
	if not _early_ice.has(attempt_number):
		var candidates: Array[String] = []
		_early_ice[attempt_number] = candidates
	return _early_ice[attempt_number]


func discard_ice(attempt_number: int) -> void:
	_early_ice.erase(attempt_number)


func envelope(kind: String, body := "") -> Dictionary:
	return {
		TAG:
		{
			"v": 1,
			"room": room,
			"from_epoch": local_epoch,
			"to_epoch": remote_epoch,
			"attempt": attempt,
			"kind": kind,
			"body": body,
		}
	}


func accepts(message: Dictionary) -> bool:
	if message.size() != 7 or not _integer_equals(message.get("v"), 1):
		return false
	if message.get("room") != room or not _integer_equals(message.get("from_epoch"), remote_epoch):
		return false
	if not _integer_equals(message.get("to_epoch"), local_epoch):
		return false
	var value: Variant = message.get("attempt")
	return (
		SFTypeUtils.is_integral_number(value)
		and value >= 0
		and value <= MAX_ATTEMPTS
		and message.get("kind") is String
		and message.get("body") is String
	)


static func _integer_equals(value: Variant, expected: int) -> bool:
	return SFTypeUtils.is_integral_number(value) and value == expected


static func has_data_offer_shape(sdp: String) -> bool:
	return (
		(sdp.begins_with("v=0\r\n") or sdp.begins_with("v=0\n"))
		and sdp.contains("\no=")
		and sdp.contains("\nt=")
		and sdp.contains("\nm=application ")
	)


class Offer:
	extends RefCounted

	var attempt: int
	var sdp: String
	var expires: int
	var connection: Object
	var can_poll := false
	var accepted := false

	func listen() -> void:
		var session_created: Signal = connection.get("session_description_created")
		session_created.connect(_on_description_created)

	func _on_description_created(type: String, answer: String) -> void:
		if connection == null or type != "answer":
			return
		for line: String in answer.split("\n"):
			if line.begins_with("m=application ") and line.get_slice(" ", 1).to_int() > 0:
				accepted = true
				return

	func close() -> void:
		can_poll = false
		var closing := connection
		connection = null
		if closing == null:
			return
		var session_created: Signal = closing.get("session_description_created")
		if session_created.is_connected(_on_description_created):
			session_created.disconnect(_on_description_created)
		closing.call("close")
