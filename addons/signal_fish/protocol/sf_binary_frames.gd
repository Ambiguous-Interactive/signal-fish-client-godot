class_name SFBinaryFrames
extends RefCounted

## Strict decoder for the binary game-data envelope frames the server sends
## when a [code]message_pack[/code] format is negotiated (PLAN §4.6, P2).
##
## Wire contract, pinned to upstream:
## - v2 (server `websocket/sending.rs` `LegacyBinaryGameDataFrame` / rust
##   client `protocol/binary.rs` `decode_v2_binary_game_data`, ported from
##   server v0.4.0): a MessagePack map with string keys
##   [code]from_player[/code] (16-byte binary UUID), [code]encoding[/code]
##   (string, [code]"message_pack"[/code] only), [code]payload[/code] (binary).
## - v3 (`V3BinaryGameDataFrame`, v3 WebSocket route only): the same shape plus
##   mandatory non-zero [code]seq[/code] (u64) and [code]epoch[/code] (u32)
##   delivery stamps; [code]encoding[/code] may also be [code]json[/code] or
##   [code]rkyv[/code].
## - Strictness matches the rust client: map keys are strings, fields must
##   appear at most once, unknown fields are rejected, integer stamps may use
##   any marker width that carries the value, and trailing bytes are malformed.
##
## On the v2 route, [code]json[/code]/[code]rkyv[/code] frames are the raw
## payload bytes with no envelope; the client handles that pass-through
## before consulting this decoder.

const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

const _UUID_BYTES := 16


## Decodes one binary game-data envelope. Returns
## [code]{ok: bool, from_player: String, encoding: int, payload: PackedByteArray,
## version: int, error: String}[/code]. [code]from_player[/code] is the
## canonical lowercase UUID string.
static func decode_envelope(bytes: PackedByteArray) -> Dictionary:
	var result := {
		"ok": false,
		"from_player": "",
		"encoding": SFTypesScript.GameDataEncoding.UNKNOWN,
		"payload": PackedByteArray(),
		"version": 0,
		"error": "",
	}
	var peer := StreamPeerBuffer.new()
	peer.data_array = bytes
	peer.big_endian = true
	var count := _read_map_header(peer)
	if count < 0:
		result["error"] = "binary game-data envelope is not a MessagePack map"
		return result
	var fields := {}
	for _index: int in count:
		var key := _read_string_field(peer)
		if key.is_empty():
			result["error"] = "binary game-data envelope key is malformed"
			return result
		if fields.has(key):
			result["error"] = "binary game-data envelope contains duplicate field %s" % key
			return result
		if not key in ["from_player", "encoding", "payload", "seq", "epoch"]:
			result["error"] = "binary game-data envelope contains unknown field %s" % key
			return result
		var read := _read_field(peer, key)
		if not read["ok"]:
			result["error"] = "binary game-data field %s is malformed" % key
			return result
		fields[key] = read["value"]
	if peer.get_available_bytes() != 0:
		result["error"] = "binary game-data envelope contains trailing bytes"
		return result
	return _validate_fields(fields, result)


static func _validate_fields(fields: Dictionary, result: Dictionary) -> Dictionary:
	for required: String in ["from_player", "encoding", "payload"]:
		if not fields.has(required):
			result["error"] = "binary game-data envelope is missing field %s" % required
			return result
	var is_v3 := fields.has("seq") or fields.has("epoch")
	if is_v3 and not (fields.has("seq") and fields.has("epoch")):
		result["error"] = "v3 binary game-data envelope requires both seq and epoch"
		return result
	var encoding := _encoding_token(fields["encoding"], is_v3)
	if encoding == SFTypesScript.GameDataEncoding.UNKNOWN:
		result["error"] = "binary game-data encoding %s is not allowed here" % fields["encoding"]
		return result
	if is_v3:
		# _read_unsigned only accepts unsigned marker forms, so a wrapped
		# negative here means a u64 stamp above i64 max — huge, never zero.
		if fields["seq"] == 0:
			result["error"] = "v3 binary game-data seq must be non-zero"
			return result
		if fields["epoch"] == 0:
			result["error"] = "v3 binary game-data epoch must be non-zero"
			return result
	result["ok"] = true
	result["from_player"] = fields["from_player"]
	result["encoding"] = encoding
	result["payload"] = fields["payload"]
	result["version"] = 3 if is_v3 else 2
	return result


static func _encoding_token(value: Variant, allow_v3_tokens: bool) -> int:
	if typeof(value) != TYPE_STRING:
		return SFTypesScript.GameDataEncoding.UNKNOWN
	match String(value):
		"message_pack":
			return SFTypesScript.GameDataEncoding.MESSAGE_PACK
		"json":
			return (
				SFTypesScript.GameDataEncoding.JSON
				if allow_v3_tokens
				else SFTypesScript.GameDataEncoding.UNKNOWN
			)
		"rkyv":
			return (
				SFTypesScript.GameDataEncoding.RKYV
				if allow_v3_tokens
				else SFTypesScript.GameDataEncoding.UNKNOWN
			)
		_:
			return SFTypesScript.GameDataEncoding.UNKNOWN


## Reads one envelope field value. Only the flat shapes the contract allows:
## [code]from_player[/code]/[code]payload[/code] are binary (16 bytes for the
## UUID), [code]encoding[/code] is a string, and [code]seq[/code]/[code]epoch
## [/code] accept any unsigned integer marker width (rust parity).
static func _read_field(peer: StreamPeerBuffer, key: String) -> Dictionary:
	if peer.get_available_bytes() < 1:
		return {"ok": false, "value": null}
	var marker := peer.get_u8()
	match key:
		"from_player", "payload":
			var length := _binary_length(peer, marker)
			if length < 0 or peer.get_available_bytes() < length:
				return {"ok": false, "value": null}
			if key == "from_player":
				if length != _UUID_BYTES:
					return {"ok": false, "value": null}
				return {"ok": true, "value": _uuid_string(peer.get_data(length)[1])}
			return {"ok": true, "value": peer.get_data(length)[1]}
		"encoding":
			var token := _read_string_after_marker(peer, marker)
			if token.is_empty():
				return {"ok": false, "value": null}
			return {"ok": true, "value": token}
		_:
			var value := _read_unsigned(peer, marker)
			if value == null:
				return {"ok": false, "value": null}
			return {"ok": true, "value": value}


## Returns the unsigned integer value, or [code]null[/code] when the marker is
## not an unsigned integer form (negative/stamped integers are rejected).
## u64 values above i64 max wrap negative in Godot; callers treat any non-zero
## value (including wrapped ones) as a valid huge stamp.
static func _read_unsigned(peer: StreamPeerBuffer, marker: int) -> Variant:
	if marker <= 0x7F:
		return marker
	if marker < 0xCC or marker > 0xCF:
		return null
	var width := 1 << (marker - 0xCC)
	if peer.get_available_bytes() < width:
		return null
	if width == 1:
		return peer.get_u8()
	if width == 2:
		return peer.get_u16()
	if width == 4:
		return peer.get_u32()
	return peer.get_u64()


## Reads one string field (any fixstr/str8/str16/str32 form, rust parity);
## [param length] -1 reads the marker first. Empty results are ambiguous with
## truncation, which is safe: the contract requires non-empty strings.
static func _read_string_after_marker(peer: StreamPeerBuffer, marker: int) -> String:
	var length := -1
	if marker >= 0xA0 and marker <= 0xBF:
		length = marker & 0x1F
	elif marker == 0xD9 or marker == 0xDA or marker == 0xDB:
		var width := 1 if marker == 0xD9 else (2 if marker == 0xDA else 4)
		if peer.get_available_bytes() < width:
			return ""
		length = peer.get_u8() if width == 1 else (peer.get_u16() if width == 2 else peer.get_u32())
	if length < 0 or peer.get_available_bytes() < length:
		return ""
	return peer.get_string(length)


static func _read_string_field(peer: StreamPeerBuffer) -> String:
	if peer.get_available_bytes() < 1:
		return ""
	return _read_string_after_marker(peer, peer.get_u8())


## Returns the byte length after a bin marker, or -1 when malformed.
static func _binary_length(peer: StreamPeerBuffer, marker: int) -> int:
	var width := 0
	if marker == 0xC4:
		width = 1
	elif marker == 0xC5:
		width = 2
	elif marker == 0xC6:
		width = 4
	else:
		return -1
	if peer.get_available_bytes() < width:
		return -1
	if width == 1:
		return peer.get_u8()
	if width == 2:
		return peer.get_u16()
	return peer.get_u32()


## Returns the map entry count, or -1 when the frame is not a readable map.
static func _read_map_header(peer: StreamPeerBuffer) -> int:
	if peer.get_available_bytes() < 1:
		return -1
	var marker := peer.get_u8()
	if marker >= 0x80 and marker <= 0x8F:
		return marker & 0x0F
	var width := 0
	if marker == 0xDE:
		width = 2
	elif marker == 0xDF:
		width = 4
	else:
		return -1
	if peer.get_available_bytes() < width:
		return -1
	return peer.get_u16() if width == 2 else peer.get_u32()


## Formats 16 UUID bytes as the canonical lowercase 8-4-4-4-12 string.
static func _uuid_string(bytes: PackedByteArray) -> String:
	var hex := bytes.hex_encode()
	return (
		"%s-%s-%s-%s-%s"
		% [
			hex.substr(0, 8),
			hex.substr(8, 4),
			hex.substr(12, 4),
			hex.substr(16, 4),
			hex.substr(20, 12)
		]
	)
