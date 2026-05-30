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
	if value.length() % 4 != 0:
		return {
			"ok": false, "bytes": PackedByteArray(), "error": "payload base64 length is invalid"
		}
	for index: int in value.length():
		var code := value.unicode_at(index)
		var is_base64_char := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
			or code == 43
			or code == 47
			or code == 61
		)
		if not is_base64_char:
			return {
				"ok": false,
				"bytes": PackedByteArray(),
				"error": "payload base64 contains invalid characters"
			}
	var bytes := Marshalls.base64_to_raw(value)
	if Marshalls.raw_to_base64(bytes) != value:
		return {"ok": false, "bytes": PackedByteArray(), "error": "payload base64 is not canonical"}
	return {"ok": true, "bytes": bytes, "error": ""}
