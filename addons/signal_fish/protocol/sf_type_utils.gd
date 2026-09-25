extends RefCounted

## Shared nesting cap for recursive protocol decode/encode: a hostile payload
## cannot overflow the script stack. Single source for the text envelope,
## MessagePack codec, and send-side JSON-shape checks.
const MAX_MESSAGE_DEPTH := 16

const _UUID_HEX_DIGITS := "0123456789abcdef"


## Canonical text-path identifier gate (issue #151): every upstream identifier
## (`PlayerId`, `RoomId`, `SessionGeneration`) is a `uuid::Uuid`, and serde
## serializes that as lowercase hyphenated text - the only spelling a
## conforming server can put on the wire. Upstream's own text-path precedent
## for client-supplied UUID text (`canonical_room_operation_id`, server
## `messages.rs`) rejects everything else, and the binary path formats its
## 16-byte UUIDs to exactly this string, so both paths decode one id to one
## value. Parse-acceptance of braced/urn/uppercase spellings never reaches the
## wire and stays refused.
static func is_canonical_uuid_text(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
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


## Shared keep-only-valid string-array coercion (issue #97): non-string
## entries are dropped instead of coerced — constructors cannot report
## errors, and laundering scalars through str() manufactures values. The
## original entries stay visible through `raw`; to_dict() sites that rebuild
## arrays from typed state must therefore preserve raw entries (or let the
## outbound validation refuse the frame loudly) instead of silently
## shortening them.
static func coerce_string_array(values: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if typeof(value) == TYPE_STRING:
			result.append(String(value))
	return result


static func objects_to_dicts(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		if typeof(value) == TYPE_OBJECT and value.has_method("to_dict"):
			result.append(value.to_dict())
	return result


## Roster round-trips without silent loss (issue #97): dict entries
## canonicalize through the typed objects in raw order, while wrong-typed
## entries pass through verbatim (containers copied, per the no-aliasing
## contract) instead of shortening the roster. Falls back to the typed
## objects alone when [param raw] does not carry [param key] as an array.
static func roster_to_dicts(raw: Dictionary, key: String, objects: Array) -> Array:
	var values: Variant = raw.get(key)
	if typeof(values) != TYPE_ARRAY:
		return objects_to_dicts(objects)
	var result: Array = []
	var next_object := 0
	for value: Variant in values:
		if typeof(value) == TYPE_DICTIONARY and next_object < objects.size():
			var entry: Variant = objects[next_object]
			result.append(entry.call("to_dict"))
			next_object += 1
		elif typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_DICTIONARY:
			result.append(value.duplicate(true))
		else:
			result.append(value)
	return result
