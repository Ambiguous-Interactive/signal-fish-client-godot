class_name SFEnvelope
extends RefCounted

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFJsonGuardScript = preload("res://addons/signal_fish/protocol/sf_json_guard.gd")

const INVALID_MESSAGE_ERROR_KEY := "_signal_fish_invalid_message_error"
const INVALID_MESSAGE_ORIGINAL_TYPE_KEY := "_signal_fish_original_message_type"
const INVALID_MESSAGE_TYPE := "__InvalidSignalFishMessage"

# Bound memo growth under hostile input; zero bypasses the cache because float
# keys cannot distinguish -0.0 from 0.0 (issue #161).
const _FLOAT_MEMO_LIMIT := 256
static var _float_memo: Dictionary = {}


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
	var error_text: String = envelope.get(INVALID_MESSAGE_ERROR_KEY, "")
	return error_text


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
			var number: float = value
			return _stringify_float(number)
		TYPE_NIL:
			return "null"
		_:
			return ""


static func _stringify_float(value: float) -> String:
	if not is_finite(value):
		return ""
	var is_zero := value == 0.0
	if not is_zero and _float_memo.has(value):
		var cached: String = _float_memo[value]
		return cached
	# Godot's full_precision only covers top-level floats. Prove each nested
	# value survives JSON parsing before it reaches the wire (issue #73).
	var text := _normalized_float(String.num(value, 17))
	if not _round_trips(text, value):
		text = _normalized_float(JSON.stringify(value, "", false, true))
		if not _round_trips(text, value):
			return ""
	if not is_zero:
		if _float_memo.size() >= _FLOAT_MEMO_LIMIT:
			_float_memo.clear()
		_float_memo[value] = text
	return text


static func _round_trips(text: String, value: float) -> bool:
	var back: Variant = JSON.parse_string(text)
	return typeof(back) == TYPE_FLOAT and back == value


static func _normalized_float(text: String) -> String:
	if text.find(".") == -1 and text.find("e") == -1 and text.find("E") == -1:
		return text + ".0"
	return text


static func decode_text(text: String) -> Dictionary:
	# Issue #92: the engine parser is last-wins on duplicate keys while
	# upstream rejects such frames, so the strict pre-scan fails closed
	# before a repeated key can silently substitute envelope fields.
	var duplicate_error := SFJsonGuardScript.duplicate_key_error(text)
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
	var parsed_envelope: Dictionary = parsed
	return decode_envelope(parsed_envelope)


static func decode_envelope(envelope: Dictionary) -> Dictionary:
	if not envelope.has("type"):
		return {"ok": false, "error": "message is missing type", "envelope": envelope}
	if typeof(envelope.get("type")) != TYPE_STRING:
		return {"ok": false, "error": "message type must be a string", "envelope": envelope}
	var type_name: String = envelope["type"]
	if type_name.is_empty():
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
