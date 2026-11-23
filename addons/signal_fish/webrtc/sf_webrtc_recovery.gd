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
