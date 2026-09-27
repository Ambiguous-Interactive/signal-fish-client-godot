extends RefCounted

## Bounds recursive decoding and encoding of untrusted payloads.
const MAX_MESSAGE_DEPTH := 16

const _UUID_HEX_DIGITS := "0123456789abcdef"


## Matches upstream uuid::Uuid's lowercase hyphenated wire form (issue #151).
static func is_canonical_uuid_text(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	@warning_ignore("unsafe_cast")
	var text := value as String
	if text.length() != 36:
		return false
	for index in range(36):
		var character := text[index]
		if index == 8 or index == 13 or index == 18 or index == 23:
			if character != "-":
				return false
		elif _UUID_HEX_DIGITS.find(character) == -1:
			return false
	return true


static func enum_value(mapping: Dictionary, value: Variant, unknown_value: int) -> int:
	if typeof(value) != TYPE_STRING:
		return unknown_value
	@warning_ignore("unsafe_call_argument")
	return int(mapping.get(String(value), unknown_value))


static func is_integral_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	@warning_ignore("unsafe_call_argument")
	var number := float(value)
	return is_finite(number) and number == floor(number)


static func bool_or_false(value: Variant) -> bool:
	return value if typeof(value) == TYPE_BOOL else false


## Rejects floats that int() would collapse beyond the signed i64 range.
static func is_i64_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT or not is_integral_number(value):
		return false
	@warning_ignore("unsafe_call_argument")
	return float(value) > -9223372036854775808.0 and float(value) < 9223372036854775808.0


## Rejects non-finite payload numbers to match upstream serde (issue #88).
static func passthrough_payload_error(value: Variant, depth := 0) -> String:
	if depth > MAX_MESSAGE_DEPTH:
		return "passthrough payload nesting exceeds depth %d" % MAX_MESSAGE_DEPTH
	var kind := typeof(value)
	@warning_ignore("unsafe_call_argument")
	if kind == TYPE_FLOAT and not is_finite(value):
		return "passthrough payload contains a non-finite number"
	if kind == TYPE_ARRAY:
		for item: Variant in value:
			var item_error := passthrough_payload_error(item, depth + 1)
			if not item_error.is_empty():
				return item_error
	elif kind == TYPE_DICTIONARY:
		for key: Variant in value:
			var value_error := passthrough_payload_error(value[key], depth + 1)
			if not value_error.is_empty():
				return value_error
	return ""


static func coerce_string_array(values: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if typeof(value) == TYPE_STRING:
			@warning_ignore("unsafe_call_argument")
			result.append(String(value))
	return result


static func objects_to_dicts(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		@warning_ignore("unsafe_method_access")
		if typeof(value) == TYPE_OBJECT and value.has_method("to_dict"):
			@warning_ignore("unsafe_method_access")
			result.append(value.to_dict())
	return result


## Preserves wrong-typed raw roster entries so round trips do not lose data.
static func roster_to_dicts(raw: Dictionary, key: String, objects: Array) -> Array:
	var values: Variant = raw.get(key)
	if typeof(values) != TYPE_ARRAY:
		return objects_to_dicts(objects)
	var result: Array = []
	var next_object := 0
	for value: Variant in values:
		if typeof(value) == TYPE_DICTIONARY and next_object < objects.size():
			var entry: Variant = objects[next_object]
			@warning_ignore("unsafe_method_access")
			result.append(entry.call("to_dict"))
			next_object += 1
		elif typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_DICTIONARY:
			@warning_ignore("unsafe_method_access")
			result.append(value.duplicate(true))
		else:
			result.append(value)
	return result
