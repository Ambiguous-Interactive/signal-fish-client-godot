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


## Strict constructor-side bool coercion (issue #95): the engine's bool()
## launders wrong-typed numbers into a different bool (bool(0.5) is true)
## and raises on wrong-typed strings/null, aborting the constructor mid-way
## (issue #81 class). Gate on the engine type and fall back to the absent
## sentinel instead.
static func bool_or_false(value: Variant) -> bool:
	return value if typeof(value) == TYPE_BOOL else false


## Strict i64 representability for constructor-side integer coercion
## (issues #73/#96): a value int() would collapse (integral float at or
## beyond ±2^63, or a non-finite magnitude) must take the field's absent
## sentinel instead of platform-dependent garbage. Unlike the decode path's
## non-negative-only gate (SFTypes._is_i64_integer), sign is preserved so a
## hostile negative stays visible instead of reading as the 0 "absent"
## sentinel.
static func is_i64_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT or not is_integral_number(value):
		return false
	return float(value) > -9223372036854775808.0 and float(value) < 9223372036854775808.0


## Inbound open payloads (`GameData.data`, `Signal.signal`) are handed to
## consumers verbatim: bound their nesting by the shared cap and refuse
## non-finite numbers (the engine's JSON parser maps `1e400` to inf, and the
## MessagePack float markers can carry NaN/±Inf — upstream serde rejects both
## classes outright). Fail closed via `protocol_error`; JSON null stays legal.
## Returns "" when the tree is acceptable (issue #88).
static func passthrough_payload_error(value: Variant, depth := 0) -> String:
	if depth > MAX_MESSAGE_DEPTH:
		return "passthrough payload nesting exceeds depth %d" % MAX_MESSAGE_DEPTH
	var kind := typeof(value)
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


static func objects_to_dicts(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		if typeof(value) == TYPE_OBJECT and value.has_method("to_dict"):
			result.append(value.to_dict())
	return result
