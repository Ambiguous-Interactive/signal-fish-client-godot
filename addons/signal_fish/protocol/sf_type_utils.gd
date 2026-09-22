extends RefCounted

## Shared nesting cap for recursive protocol decode/encode: a hostile payload
## cannot overflow the script stack. Single source for the text envelope,
## MessagePack codec, and send-side JSON-shape checks.
const MAX_MESSAGE_DEPTH := 16


static func enum_value(mapping: Dictionary, value: Variant, unknown_value: int) -> int:
	if typeof(value) != TYPE_STRING:
		return unknown_value
	return int(mapping.get(String(value), unknown_value))


static func is_integral_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	# Non-finite magnitudes are not integers, and `floor(INF) == INF` would
	# otherwise pass them to int()-collapsing call sites (issue #81).
	return is_finite(number) and number == floor(number)


static func objects_to_dicts(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		if typeof(value) == TYPE_OBJECT and value.has_method("to_dict"):
			result.append(value.to_dict())
	return result
