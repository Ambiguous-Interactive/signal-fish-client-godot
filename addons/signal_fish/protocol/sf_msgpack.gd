class_name SFMsgpack
extends RefCounted

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")

## Pure-GDScript MessagePack codec (PLAN §4.6, P2 binary game data). Decodes
## the MessagePack binary game-data envelope frames and, when the consumer
## opts in via [member SignalFishConfig.decode_msgpack_payloads], game-data
## payload values. Encoding lets pure-Godot games build
## [code]message_pack[/code] payloads for
## [method SignalFishClient.send_game_data_binary]. No threads, no blocking —
## web-export safe.
##
## Value mapping: nil -> [code]null[/code], bool/int/float/string as-is,
## bin -> [code]PackedByteArray[/code], array -> [code]Array[/code],
## map -> [code]Dictionary[/code]. Extension types are rejected (upstream
## game data is JSON-compatible via serde), and encode map keys must be
## strings because the server decodes payloads as JSON values
## (server `websocket/sending.rs` `decode_binary_to_json`). Godot string
## decoding is UTF-8-lenient: unlike the rust strict decoder, invalid UTF-8
## in a hostile frame surfaces as replacement characters in decoded values
## instead of a decode error — benign for game data, and tokens (envelope
## keys, encoding names) still fail their exact-match checks.

## Mirrors the shared protocol nesting cap (SFTypeUtils.MAX_MESSAGE_DEPTH):
## a hostile payload cannot overflow the script stack during recursive
## decode/encode.
const MAX_DEPTH := SFTypeUtils.MAX_MESSAGE_DEPTH

const _U64_CARRY := 18446744073709551616.0
const _SIGNED_INT_WIDTHS := {0xD0: 1, 0xD1: 2, 0xD2: 4, 0xD3: 8}


## Decodes exactly one MessagePack value; trailing bytes are malformed.
## Returns [code]{ok: bool, value: Variant, error: String}[/code].
static func decode(bytes: PackedByteArray) -> Dictionary:
	var peer := StreamPeerBuffer.new()
	peer.data_array = bytes
	peer.big_endian = true
	var failure: Array[String] = [""]
	var value: Variant = _decode_value(peer, 0, failure)
	if not failure[0].is_empty():
		return {"ok": false, "value": null, "error": failure[0]}
	if peer.get_available_bytes() != 0:
		return {"ok": false, "value": null, "error": "trailing bytes after MessagePack value"}
	return {"ok": true, "value": value, "error": ""}


## Encodes a Godot value as MessagePack. Map keys must be strings; supported
## values are null, bool, int, float, String, PackedByteArray, Array, and
## Dictionary. Returns [code]{ok: bool, bytes: PackedByteArray, error: String}[/code].
static func encode(value: Variant) -> Dictionary:
	var peer := StreamPeerBuffer.new()
	peer.big_endian = true
	var problem := _encode_value(peer, value, 0)
	if not problem.is_empty():
		return {"ok": false, "bytes": PackedByteArray(), "error": problem}
	return {"ok": true, "bytes": peer.data_array, "error": ""}


## [param failure] is a one-element out-slot: a non-empty string marks the
## decode as failed and every caller stops unwinding. Passing it down keeps
## decode reentrant with zero per-node allocations.
static func _decode_value(peer: StreamPeerBuffer, depth: int, failure: Array[String]) -> Variant:
	if depth > MAX_DEPTH:
		return _fail(failure, "MessagePack nesting exceeds depth %d" % MAX_DEPTH)
	if peer.get_available_bytes() < 1:
		return _fail(failure, "truncated MessagePack value")
	var marker := peer.get_u8()
	if marker <= 0x7F:
		return marker
	if marker >= 0xE0:
		return marker - 0x100
	if marker <= 0x8F:
		return _read_counted_map(peer, marker & 0x0F, depth, failure)
	if marker <= 0x9F:
		return _read_counted_array(peer, marker & 0x0F, depth, failure)
	if marker <= 0xBF:
		return _read_string(peer, marker & 0x1F, failure)
	match marker:
		0xC0:
			return null
		0xC2:
			return false
		0xC3:
			return true
		0xC4, 0xC5, 0xC6:
			return _read_binary(peer, marker - 0xC4, failure)
		0xCA:
			if peer.get_available_bytes() < 4:
				return _fail(failure, "truncated MessagePack float")
			# NaN/±Inf mirror the encode refusal (issue #83): upstream cannot
			# represent them, and game code must never receive them (issue #88).
			var single := peer.get_float()
			if not is_finite(single):
				return _fail(failure, "MessagePack float is non-finite")
			return single
		0xCB:
			if peer.get_available_bytes() < 8:
				return _fail(failure, "truncated MessagePack float")
			var double := peer.get_double()
			if not is_finite(double):
				return _fail(failure, "MessagePack float is non-finite")
			return double
		0xCC:
			return _read_uint(peer, 1, failure)
		0xCD:
			return _read_uint(peer, 2, failure)
		0xCE:
			return _read_uint(peer, 4, failure)
		0xCF:
			return _read_uint(peer, 8, failure)
		0xD0, 0xD1, 0xD2, 0xD3:
			var width: int = _SIGNED_INT_WIDTHS[marker]
			if peer.get_available_bytes() < width:
				return _fail(failure, "truncated MessagePack integer")
			var value := 0
			if width == 1:
				value = peer.get_8()
			elif width == 2:
				value = peer.get_16()
			elif width == 4:
				value = peer.get_32()
			else:
				value = peer.get_64()
			return value
		0xD9:
			return _read_sized_string(peer, 1, failure)
		0xDA:
			return _read_sized_string(peer, 2, failure)
		0xDB:
			return _read_sized_string(peer, 4, failure)
		0xDC:
			return _read_array(peer, 2, depth, failure)
		0xDD:
			return _read_array(peer, 4, depth, failure)
		0xDE:
			return _read_map(peer, 2, depth, failure)
		0xDF:
			return _read_map(peer, 4, depth, failure)
		_:
			return _fail(failure, "unsupported MessagePack marker 0x%02X" % marker)


static func _read_array(
	peer: StreamPeerBuffer, width: int, depth: int, failure: Array[String]
) -> Variant:
	var header := _read_length(peer, width)
	if header < 0:
		return _fail(failure, "truncated MessagePack array header")
	return _read_counted_array(peer, header, depth, failure)


static func _read_counted_array(
	peer: StreamPeerBuffer, count: int, depth: int, failure: Array[String]
) -> Variant:
	var values: Array = []
	for _index: int in count:
		var entry: Variant = _decode_value(peer, depth + 1, failure)
		if not failure[0].is_empty():
			return null
		values.append(entry)
	return values


static func _read_map(
	peer: StreamPeerBuffer, width: int, depth: int, failure: Array[String]
) -> Variant:
	var header := _read_length(peer, width)
	if header < 0:
		return _fail(failure, "truncated MessagePack map header")
	return _read_counted_map(peer, header, depth, failure)


static func _read_counted_map(
	peer: StreamPeerBuffer, count: int, depth: int, failure: Array[String]
) -> Variant:
	var entries: Dictionary = {}
	for _index: int in count:
		var key: Variant = _decode_value(peer, depth + 1, failure)
		if not failure[0].is_empty():
			return null
		if typeof(key) != TYPE_STRING:
			return _fail(failure, "MessagePack map key is not a string")
		var value: Variant = _decode_value(peer, depth + 1, failure)
		if not failure[0].is_empty():
			return null
		entries[key] = value
	return entries


static func _read_sized_string(
	peer: StreamPeerBuffer, width: int, failure: Array[String]
) -> Variant:
	var length := _read_length(peer, width)
	if length < 0:
		return _fail(failure, "truncated MessagePack string header")
	return _read_string(peer, length, failure)


static func _read_string(peer: StreamPeerBuffer, length: int, failure: Array[String]) -> Variant:
	if peer.get_available_bytes() < length:
		return _fail(failure, "truncated MessagePack string")
	return peer.get_string(length)


static func _read_binary(
	peer: StreamPeerBuffer, size_class: int, failure: Array[String]
) -> Variant:
	var length := _read_length(peer, 1 << size_class)
	if length < 0:
		return _fail(failure, "truncated MessagePack binary header")
	if peer.get_available_bytes() < length:
		return _fail(failure, "truncated MessagePack binary")
	return peer.get_data(length)[1]


## Reads a big-endian length of [param width] bytes; -1 means truncated.
static func _read_length(peer: StreamPeerBuffer, width: int) -> int:
	if peer.get_available_bytes() < width:
		return -1
	if width == 1:
		return peer.get_u8()
	if width == 2:
		return peer.get_u16()
	return peer.get_u32()


static func _read_uint(peer: StreamPeerBuffer, width: int, failure: Array[String]) -> Variant:
	if peer.get_available_bytes() < width:
		return _fail(failure, "truncated MessagePack integer")
	var value := 0
	if width == 1:
		value = peer.get_u8()
	elif width == 2:
		value = peer.get_u16()
	elif width == 4:
		value = peer.get_u32()
	else:
		value = peer.get_u64()
	# Godot ints are signed 64-bit: u64 above i64 max wraps negative, so it is
	# surfaced as a float, matching serde's lossy JSON number for such values.
	if value < 0:
		return float(value) + _U64_CARRY
	return value


static func _encode_value(peer: StreamPeerBuffer, value: Variant, depth: int) -> String:
	if depth > MAX_DEPTH:
		return "MessagePack nesting exceeds depth %d" % MAX_DEPTH
	match typeof(value):
		TYPE_NIL:
			peer.put_u8(0xC0)
		TYPE_BOOL:
			peer.put_u8(0xC3 if value else 0xC2)
		TYPE_INT:
			_encode_integer(peer, value)
		TYPE_FLOAT:
			# Upstream game data is JSON-compatible: the server-side JSON
			# decode collapses non-finite doubles, so refuse them instead of
			# putting altered values on the wire (issue #83, #76 precedent).
			if not is_finite(value):
				return "non-finite float is not JSON-representable"
			peer.put_u8(0xCB)
			peer.put_double(value)
		TYPE_STRING:
			_encode_string(peer, value)
		TYPE_PACKED_BYTE_ARRAY:
			_put_length(peer, -1, 0xC4, 0xC5, value.size(), -1)
			peer.put_data(value)
		TYPE_ARRAY:
			_put_count_length(peer, 0x90, 0xDC, value.size())
			for entry: Variant in value:
				var problem := _encode_value(peer, entry, depth + 1)
				if not problem.is_empty():
					return problem
		TYPE_DICTIONARY:
			_put_count_length(peer, 0x80, 0xDE, value.size())
			for key: Variant in value:
				if typeof(key) != TYPE_STRING:
					return "MessagePack map keys must be strings"
				_encode_string(peer, key)
				var problem := _encode_value(peer, value[key], depth + 1)
				if not problem.is_empty():
					return problem
		_:
			return "unsupported value type for MessagePack encode"
	return ""


static func _encode_integer(peer: StreamPeerBuffer, value: int) -> void:
	if value >= 0:
		if value <= 0x7F:
			peer.put_u8(value)
		elif value <= 0xFF:
			peer.put_u8(0xCC)
			peer.put_u8(value)
		elif value <= 0xFFFF:
			peer.put_u8(0xCD)
			peer.put_u16(value)
		elif value <= 0xFFFFFFFF:
			peer.put_u8(0xCE)
			peer.put_u32(value)
		else:
			peer.put_u8(0xCF)
			peer.put_u64(value)
	elif value >= -32:
		peer.put_u8(value & 0xFF)
	elif value >= -128:
		peer.put_u8(0xD0)
		peer.put_8(value)
	elif value >= -32768:
		peer.put_u8(0xD1)
		peer.put_16(value)
	elif value >= -2147483648:
		peer.put_u8(0xD2)
		peer.put_32(value)
	else:
		peer.put_u8(0xD3)
		peer.put_64(value)


static func _encode_string(peer: StreamPeerBuffer, value: String) -> void:
	var encoded := value.to_utf8_buffer()
	_put_length(peer, 0xA0, 0xD9, 0xDA, encoded.size(), 0x1F)
	peer.put_data(encoded)


## Emits a str/bin-family length header: [param fix_base] (or -1 when no fix
## form exists) with [param fix_max], then the 8/16/32-bit markers as needed.
static func _put_length(
	peer: StreamPeerBuffer,
	fix_base: int,
	u8_marker: int,
	u16_marker: int,
	length: int,
	fix_max: int
) -> void:
	if fix_base >= 0 and length <= fix_max:
		peer.put_u8(fix_base | length)
	elif u8_marker >= 0 and length <= 0xFF:
		peer.put_u8(u8_marker)
		peer.put_u8(length)
	elif length <= 0xFFFF:
		peer.put_u8(u16_marker)
		peer.put_u16(length)
	else:
		peer.put_u8(u16_marker + 1)
		peer.put_u32(length)


## Emits an array/map-family length header (fix form, then 16/32-bit — these
## families have no 8-bit marker).
static func _put_count_length(
	peer: StreamPeerBuffer, fix_base: int, u16_marker: int, length: int
) -> void:
	if length <= 0x0F:
		peer.put_u8(fix_base | length)
	elif length <= 0xFFFF:
		peer.put_u8(u16_marker)
		peer.put_u16(length)
	else:
		peer.put_u8(u16_marker + 1)
		peer.put_u32(length)


static func _fail(failure: Array[String], message: String) -> Variant:
	failure[0] = message
	return null
