class_name SFEnvelope
extends RefCounted

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFJsonGuard = preload("res://addons/signal_fish/protocol/sf_json_guard.gd")

const INVALID_MESSAGE_ERROR_KEY := "_signal_fish_invalid_message_error"
const INVALID_MESSAGE_ORIGINAL_TYPE_KEY := "_signal_fish_original_message_type"
const INVALID_MESSAGE_TYPE := "__InvalidSignalFishMessage"


static func message(type_name: String, data: Variant = null) -> Dictionary:
	var envelope: Dictionary = {}
	envelope["type"] = type_name
	if data != null:
		envelope["data"] = data
	return envelope


static func invalid_message(type_name: String, error: String, data: Variant = null) -> Dictionary:
	var envelope := message(INVALID_MESSAGE_TYPE, data)
	envelope[INVALID_MESSAGE_ERROR_KEY] = error
	envelope[INVALID_MESSAGE_ORIGINAL_TYPE_KEY] = type_name
	return envelope


static func is_invalid_message(envelope: Dictionary) -> bool:
	return envelope.has(INVALID_MESSAGE_ERROR_KEY)


static func invalid_message_error(envelope: Dictionary) -> String:
	return String(envelope.get(INVALID_MESSAGE_ERROR_KEY, ""))


static func encode(envelope: Dictionary, report_error: bool = true) -> String:
	if is_invalid_message(envelope):
		if report_error:
			push_error(
				"cannot encode invalid Signal Fish message: %s" % invalid_message_error(envelope)
			)
		return ""
	var wire := _stringify_value(envelope, 0)
	if wire.is_empty() and report_error:
		push_error(
			"cannot encode Signal Fish message: payload is not losslessly JSON-representable"
		)
	return wire


## Round-trip-exact JSON serialization. `JSON.stringify` emits nested floats
## at reduced precision (its `full_precision` flag only affects top-level
## scalars), silently stringifies engine-only Variants, and renders non-finite
## floats as `nan`/`inf` text no JSON parser accepts. Floats therefore
## serialize through `String.num(value, 17)` — sufficient digits for every
## f64, verified by parse-back (0/50000 random doubles in ±1e15 failed) —
## normalized with a trailing ".0" so an integral float never flips JSON
## number type on the wire; the engine's top-level full-precision writer is
## the fallback candidate. A float neither candidate proves round-trip-exact
## (only very small magnitudes are known to fail the engine's formatters)
## refuses the frame
## instead of corrupting it — the same reject-never-collapse policy as
## hostile integers (issue #73). Depth is bounded like the decoder so a
## hostile structure cannot overflow the script stack. An empty return means
## "refuse": containers always render at least "{}"/"[]".
static func _stringify_value(value: Variant, depth: int) -> String:
	if depth > SFTypeUtils.MAX_MESSAGE_DEPTH:
		return ""
	match typeof(value):
		TYPE_DICTIONARY:
			var fields := PackedStringArray()
			for key: Variant in value:
				if typeof(key) != TYPE_STRING:
					return ""
				var encoded := _stringify_value(value[key], depth + 1)
				if encoded.is_empty():
					return ""
				fields.append(JSON.stringify(key, "", false, true) + ":" + encoded)
			return "{" + ",".join(fields) + "}"
		TYPE_ARRAY:
			var entries := PackedStringArray()
			for entry: Variant in value:
				var encoded := _stringify_value(entry, depth + 1)
				if encoded.is_empty():
					return ""
				entries.append(encoded)
			return "[" + ",".join(entries) + "]"
		TYPE_STRING:
			return JSON.stringify(value, "", false, true)
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return _stringify_float(value)
		TYPE_NIL:
			return "null"
		_:
			return ""


static func _stringify_float(value: float) -> String:
	if not is_finite(value):
		return ""
	for text: String in [String.num(value, 17), JSON.stringify(value, "", false, true)]:
		if text.find(".") == -1 and text.find("e") == -1 and text.find("E") == -1:
			text += ".0"
		var back: Variant = JSON.parse_string(text)
		if typeof(back) == TYPE_FLOAT and back == value:
			return text
	return ""


static func decode_text(text: String) -> Dictionary:
	# Issue #92: the engine parser is last-wins on duplicate keys while
	# upstream rejects such frames, so the strict pre-scan fails closed
	# before a repeated key can silently substitute envelope fields.
	var duplicate_error := SFJsonGuard.duplicate_key_error(text)
	if not duplicate_error.is_empty():
		return {"ok": false, "error": duplicate_error, "envelope": {}}
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		return {
			"ok": false,
			"error":
			(
				"message must be valid JSON at line %d: %s"
				% [json.get_error_line(), json.get_error_message()]
			),
			"envelope": {}
		}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "message must be a JSON object", "envelope": {}}
	return decode_envelope(parsed)


static func decode_envelope(envelope: Dictionary) -> Dictionary:
	if not envelope.has("type"):
		return {"ok": false, "error": "message is missing type", "envelope": envelope}
	if typeof(envelope.get("type")) != TYPE_STRING:
		return {"ok": false, "error": "message type must be a string", "envelope": envelope}
	if String(envelope["type"]).is_empty():
		return {"ok": false, "error": "message type must not be empty", "envelope": envelope}
	if (
		envelope.has("data")
		and envelope["data"] != null
		and typeof(envelope["data"]) != TYPE_DICTIONARY
	):
		return {
			"ok": false,
			"error": "message data must be an object when present",
			"envelope": envelope
		}
	return {"ok": true, "error": "", "envelope": envelope}


static func data_or_empty(envelope: Dictionary) -> Dictionary:
	if envelope.has("data") and typeof(envelope["data"]) == TYPE_DICTIONARY:
		return envelope["data"]
	return {}
