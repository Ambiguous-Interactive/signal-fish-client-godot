class_name SFBinaryCodec
extends RefCounted


static func decode_payload(payload: Variant) -> Dictionary:
	if typeof(payload) == TYPE_PACKED_BYTE_ARRAY:
		return {"ok": true, "bytes": payload, "error": ""}
	if typeof(payload) == TYPE_ARRAY:
		return _decode_byte_array(payload)
	if typeof(payload) == TYPE_STRING:
		return _decode_base64(payload)
	return {
		"ok": false,
		"bytes": PackedByteArray(),
		"error": "payload must be a byte array or base64 string"
	}


static func encode_payload_as_array(bytes: PackedByteArray) -> Array:
	var result: Array = []
	for byte_value: int in bytes:
		result.append(byte_value)
	return result


static func encode_payload_as_base64(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes)


static func _decode_byte_array(values: Array) -> Dictionary:
	var bytes := PackedByteArray()
	for index: int in values.size():
		var value: Variant = values[index]
		var value_type := typeof(value)
		if value_type != TYPE_INT and value_type != TYPE_FLOAT:
			return {
				"ok": false,
				"bytes": PackedByteArray(),
				"error":
				"payload byte array[%d] contains a non-number: %s" % [index, var_to_str(value)]
			}
		var int_value := int(value)
		if float(int_value) != float(value) or int_value < 0 or int_value > 255:
			return {
				"ok": false,
				"bytes": PackedByteArray(),
				"error":
				(
					"payload byte array[%d] contains a value outside 0..255: %s"
					% [index, var_to_str(value)]
				)
			}
		bytes.append(int_value)
	return {"ok": true, "bytes": bytes, "error": ""}


static func _decode_base64(value: String) -> Dictionary:
	if value.is_empty():
		return {"ok": true, "bytes": PackedByteArray(), "error": ""}
	var normalized_result := _normalize_base64(value)
	if not normalized_result["ok"]:
		return {"ok": false, "bytes": PackedByteArray(), "error": normalized_result["error"]}
	var normalized := String(normalized_result["value"])
	var bytes := Marshalls.base64_to_raw(normalized)
	if Marshalls.raw_to_base64(bytes) != normalized:
		return {"ok": false, "bytes": PackedByteArray(), "error": "payload base64 is invalid"}
	return {"ok": true, "bytes": bytes, "error": ""}


static func _normalize_base64(value: String) -> Dictionary:
	var first_padding_index := -1
	var padding_count := 0
	for index: int in value.length():
		var code := value.unicode_at(index)
		if code == 61:
			if first_padding_index == -1:
				first_padding_index = index
			padding_count += 1
			continue
		if first_padding_index != -1:
			return {"ok": false, "value": "", "error": "payload base64 padding is invalid"}
		var is_base64_char := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
			or code == 43
			or code == 47
		)
		if not is_base64_char:
			return {"ok": false, "value": "", "error": "payload base64 contains invalid characters"}
	if padding_count > 2:
		return {"ok": false, "value": "", "error": "payload base64 padding is invalid"}
	if first_padding_index != -1:
		if value.length() % 4 != 0:
			return {"ok": false, "value": "", "error": "payload base64 length is invalid"}
		return {"ok": true, "value": value, "error": ""}
	var remainder := value.length() % 4
	if remainder == 0:
		return {"ok": true, "value": value, "error": ""}
	if remainder == 1:
		return {"ok": false, "value": "", "error": "payload base64 length is invalid"}
	var padding := "==" if remainder == 2 else "="
	return {"ok": true, "value": value + padding, "error": ""}
