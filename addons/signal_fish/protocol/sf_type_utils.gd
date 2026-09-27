extends RefCounted

## Bounds recursive decoding and encoding of untrusted payloads.
const MAX_MESSAGE_DEPTH := 16

const _UUID_HEX_DIGITS := "0123456789abcdef"


## Matches upstream uuid::Uuid's lowercase hyphenated wire form (issue #151).
static func is_canonical_uuid_text(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
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
	if not value is String:
		return unknown_value
	var key: String = value
	var mapped_value: int = mapping.get(key, unknown_value)
	return mapped_value


static func is_integral_number(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = value
	return is_finite(number) and number == floor(number)


static func bool_or_false(value: Variant) -> bool:
	return value if typeof(value) == TYPE_BOOL else false


static func string_or_empty(value: Variant) -> String:
	if not value is String:
		return ""
	var text: String = value
	return text


static func int_or_zero(value: Variant) -> int:
	if value is int:
		var number: int = value
		return number
	if value is float and is_i64_integer(value):
		var number: float = value
		return int(number)
	return 0


## Rejects floats that int() would collapse beyond the signed i64 range.
static func is_i64_integer(value: Variant) -> bool:
	if value is int:
		return true
	if not value is float or not is_integral_number(value):
		return false
	var number: float = value
	return number > -9223372036854775808.0 and number < 9223372036854775808.0


## Rejects non-finite payload numbers to match upstream serde (issue #88).
static func passthrough_payload_error(value: Variant, depth := 0) -> String:
	if depth > MAX_MESSAGE_DEPTH:
		return "passthrough payload nesting exceeds depth %d" % MAX_MESSAGE_DEPTH
	if value is float:
		var number: float = value
		if not is_finite(number):
			return "passthrough payload contains a non-finite number"
	if value is Array:
		for item: Variant in value:
			var item_error := passthrough_payload_error(item, depth + 1)
			if not item_error.is_empty():
				return item_error
	elif value is Dictionary:
		for key: Variant in value:
			var value_error := passthrough_payload_error(value[key], depth + 1)
			if not value_error.is_empty():
				return value_error
	return ""


static func coerce_string_array(values: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if not values is Array:
		return result
	for value: Variant in values:
		if value is String:
			var text: String = value
			result.append(text)
	return result


static func objects_to_dicts(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		if value is Object:
			var object: Object = value
			if object.has_method("to_dict"):
				result.append(object.call("to_dict"))
	return result


## Preserves wrong-typed raw roster entries so round trips do not lose data.
static func roster_to_dicts(raw: Dictionary, key: String, objects: Array) -> Array:
	var values: Variant = raw.get(key)
	if not values is Array:
		return objects_to_dicts(objects)
	var result: Array = []
	var next_object := 0
	for value: Variant in values:
		if value is Dictionary and next_object < objects.size():
			var entry: Variant = objects[next_object]
			if entry is Object:
				var object: Object = entry
				result.append(object.call("to_dict"))
			else:
				var dictionary: Dictionary = value
				result.append(dictionary.duplicate(true))
			next_object += 1
		elif value is Array:
			var array: Array = value
			result.append(array.duplicate(true))
		elif value is Dictionary:
			var dictionary: Dictionary = value
			result.append(dictionary.duplicate(true))
		else:
			result.append(value)
	return result
