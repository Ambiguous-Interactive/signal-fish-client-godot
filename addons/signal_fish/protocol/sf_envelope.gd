class_name SFEnvelope
extends RefCounted

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
	return JSON.stringify(envelope, "", false)


static func decode_text(text: String) -> Dictionary:
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
