class_name SFEnvelope
extends RefCounted


static func message(type_name: String, data: Variant = null) -> Dictionary:
	var envelope: Dictionary = {}
	envelope["type"] = type_name
	if data != null:
		envelope["data"] = data
	return envelope


static func encode(envelope: Dictionary) -> String:
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
