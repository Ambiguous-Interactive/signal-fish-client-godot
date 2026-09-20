extends RefCounted

## Data-driven tests for the P2 binary game-data surface: the pure-GDScript
## MessagePack codec (sf_msgpack.gd) and the strict binary game-data envelope
## decoder (sf_binary_frames.gd). Byte vectors are hand-pinned to the upstream
## contract (server `websocket/sending.rs`, rust client `protocol/binary.rs`);
## variant envelopes are assembled by local byte helpers.

const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_B_BYTES: Array = [0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]

var _failures: Array = []


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_msgpack_decode_vectors()
	_test_msgpack_hostile_vectors()
	_test_msgpack_encode_widths()
	_test_msgpack_round_trip_matrix()
	_test_v2_envelope_canonical_bytes()
	_test_envelope_variant_matrix()
	_test_envelope_hostile_matrix()
	_test_v3_envelope_matrix()


func _test_msgpack_decode_vectors() -> void:
	var vectors := [
		{"label": "nil", "bytes": [0xC0], "want": null},
		{"label": "false", "bytes": [0xC2], "want": false},
		{"label": "true", "bytes": [0xC3], "want": true},
		{"label": "fixint zero", "bytes": [0x00], "want": 0},
		{"label": "fixint max", "bytes": [0x7F], "want": 127},
		{"label": "negative fixint", "bytes": [0xFF], "want": -1},
		{"label": "negative fixint min", "bytes": [0xE0], "want": -32},
		{"label": "uint8", "bytes": [0xCC, 0xFF], "want": 255},
		{"label": "uint16", "bytes": [0xCD, 0x01, 0x00], "want": 256},
		{"label": "uint32", "bytes": [0xCE, 0xFF, 0xFF, 0xFF, 0xFF], "want": 4294967295},
		{"label": "int8", "bytes": [0xD0, 0x80], "want": -128},
		{"label": "int16", "bytes": [0xD1, 0x80, 0x00], "want": -32768},
		{"label": "int32", "bytes": [0xD2, 0x80, 0x00, 0x00, 0x00], "want": -2147483648},
		{"label": "float32", "bytes": [0xCA, 0x3F, 0x00, 0x00, 0x00], "want": 0.5},
		{"label": "fixstr", "bytes": [0xA5] + _string_codepoints("hello"), "want": "hello"},
		{
			"label": "str8",
			"bytes": [0xD9, 0x28] + _string_codepoints("x".repeat(40)),
			"want": "x".repeat(40),
		},
		{
			"label": "bin8",
			"bytes": [0xC4, 0x03, 0xDE, 0xAD, 0xBE],
			"want": PackedByteArray([0xDE, 0xAD, 0xBE]),
		},
		{"label": "fixarray", "bytes": [0x93, 0x01, 0x02, 0x03], "want": [1, 2, 3]},
		{"label": "array16", "bytes": [0xDC, 0x00, 0x02, 0x01, 0xA0], "want": [1, ""]},
		{
			"label": "fixmap",
			"bytes": [0x82, 0xA1, 0x6B, 0x01, 0xA1, 0x6A, 0x02],
			"want": {"k": 1, "j": 2},
		},
		{
			"label": "uint64 max surfaces as float",
			"bytes": [0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
			"want": 1.8446744073709552e19,
		},
		{
			"label": "float64",
			"bytes": [0xCB, 0x3F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			"want": 1.5,
		},
	]
	for vector: Dictionary in vectors:
		var result := SFMsgpackScript.decode(_packed(vector["bytes"]))
		if not _assert(result["ok"], true, "decode %s succeeds" % vector["label"]):
			continue
		_assert_equal(vector["want"], result["value"], "decode %s value" % vector["label"])


func _test_msgpack_hostile_vectors() -> void:
	var vectors := [
		{"label": "empty input", "bytes": []},
		{"label": "truncated uint16", "bytes": [0xCD, 0x01]},
		{"label": "truncated string", "bytes": [0xA5, 0x61]},
		{"label": "truncated binary", "bytes": [0xC4, 0x03, 0x01]},
		{"label": "truncated array", "bytes": [0x93, 0x01]},
		{"label": "trailing bytes", "bytes": [0x01, 0x02]},
		{"label": "ext marker", "bytes": [0xC7, 0x01, 0x00, 0x2A]},
		{"label": "fixext1", "bytes": [0xD4, 0x00, 0x2A]},
	]
	for vector: Dictionary in vectors:
		var result := SFMsgpackScript.decode(_packed(vector["bytes"]))
		_assert(result["ok"], false, "decode %s is rejected" % vector["label"])
	# Deep nesting beyond the depth cap must fail, not overflow the stack.
	var deep: Array = []
	for _index: int in SFMsgpackScript.MAX_DEPTH + 1:
		deep = [deep]
	var deep_encode := SFMsgpackScript.encode(deep)
	_assert(deep_encode["ok"], false, "deep encode is rejected")
	var deep_decode := SFMsgpackScript.decode(
		deep_encode["bytes"] if deep_encode["ok"] else PackedByteArray()
	)
	_assert(deep_decode["ok"], false, "deep decode is rejected")


func _test_msgpack_encode_widths() -> void:
	var vectors := [
		{"value": 0, "bytes": [0x00]},
		{"value": 127, "bytes": [0x7F]},
		{"value": 128, "bytes": [0xCC, 0x80]},
		{"value": 255, "bytes": [0xCC, 0xFF]},
		{"value": 256, "bytes": [0xCD, 0x01, 0x00]},
		{"value": 65536, "bytes": [0xCE, 0x00, 0x01, 0x00, 0x00]},
		{"value": -1, "bytes": [0xFF]},
		{"value": -32, "bytes": [0xE0]},
		{"value": -33, "bytes": [0xD0, 0xDF]},
		{"value": -128, "bytes": [0xD0, 0x80]},
		{"value": -129, "bytes": [0xD1, 0xFF, 0x7F]},
		{"value": -32768, "bytes": [0xD1, 0x80, 0x00]},
		{"value": -32769, "bytes": [0xD2, 0xFF, 0xFF, 0x7F, 0xFF]},
		{"value": true, "bytes": [0xC3]},
		{"value": null, "bytes": [0xC0]},
	]
	for vector: Dictionary in vectors:
		var result := SFMsgpackScript.encode(vector["value"])
		if not _assert(result["ok"], true, "encode %s succeeds" % vector["value"]):
			continue
		_assert_equal(
			_packed(vector["bytes"]), result["bytes"], "encode %s bytes" % vector["value"]
		)
	var string_result := SFMsgpackScript.encode("y".repeat(300))
	if _assert(string_result["ok"], true, "encode 300-char string succeeds"):
		_assert_equal(0xDA, string_result["bytes"][0], "300-char string uses str16")
	var int_key_result := SFMsgpackScript.encode({1: "x"})
	_assert(int_key_result["ok"], false, "int map keys are rejected")
	var object_result := SFMsgpackScript.encode(RefCounted.new())
	_assert(object_result["ok"], false, "objects are rejected")


func _test_msgpack_round_trip_matrix() -> void:
	var values: Array = [
		null,
		false,
		true,
		0,
		127,
		-32,
		128,
		255,
		256,
		65536,
		-33,
		-128,
		-129,
		-32768,
		-32769,
		-2147483648,
		1.5,
		"hello",
		"x".repeat(40),
		"y".repeat(300),
		_packed([0xDE, 0xAD]),
		PackedByteArray(),
		[1, "two", 3.0, null],
		{"alpha": 1, "beta": [true, null], "gamma": {"delta": "value"}},
	]
	for value: Variant in values:
		var encoded := SFMsgpackScript.encode(value)
		if not _assert(encoded["ok"], true, "round-trip encode %s" % var_to_str(value)):
			continue
		var decoded := SFMsgpackScript.decode(encoded["bytes"])
		if not _assert(decoded["ok"], true, "round-trip decode %s" % var_to_str(value)):
			continue
		_assert_equal(value, decoded["value"], "round-trip value %s" % var_to_str(value))


func _test_v2_envelope_canonical_bytes() -> void:
	# Hand-pinned canonical v2 envelope (rmp_serde `to_vec_named` shape).
	var canonical: Array = (
		[0x83]
		+ [0xAB]
		+ _string_codepoints("from_player")
		+ [0xC4, 0x10]
		+ PLAYER_B_BYTES
		+ [0xA8]
		+ _string_codepoints("encoding")
		+ [0xAC]
		+ _string_codepoints("message_pack")
		+ [0xA7]
		+ _string_codepoints("payload")
		+ [0xC4, 0x02, 0xDE, 0xAD]
	)
	var result := SFBinaryFramesScript.decode_envelope(_packed(canonical))
	if not _assert(result["ok"], true, "canonical v2 envelope decodes"):
		return
	_assert_equal(PLAYER_B, result["from_player"], "canonical v2 from_player")
	_assert_equal(
		SFTypesScript.GameDataEncoding.MESSAGE_PACK, result["encoding"], "canonical v2 encoding"
	)
	_assert_equal(_packed([0xDE, 0xAD]), result["payload"], "canonical v2 payload")
	_assert_equal(2, result["version"], "canonical v2 version")


func _test_envelope_variant_matrix() -> void:
	var v2_fields := _v2_fields()
	var cases := [
		{"label": "fixmap header", "bytes": _envelope(v2_fields)},
		{"label": "map16 header", "bytes": _envelope(v2_fields, [0xDE, 0x00, 0x03])},
		{
			"label": "field order shuffled",
			"bytes": _envelope([v2_fields[2], v2_fields[1], v2_fields[0]]),
		},
		{
			"label": "empty payload",
			"bytes": _envelope([v2_fields[0], v2_fields[1], _payload_field([])]),
		},
	]
	for case: Dictionary in cases:
		var result := SFBinaryFramesScript.decode_envelope(case["bytes"])
		if not _assert(result["ok"], true, "%s decodes" % case["label"]):
			continue
		_assert_equal(PLAYER_B, result["from_player"], "%s from_player" % case["label"])
		_assert_equal(
			SFTypesScript.GameDataEncoding.MESSAGE_PACK,
			result["encoding"],
			"%s encoding" % case["label"]
		)
		_assert_equal(2, result["version"], "%s version" % case["label"])


func _test_envelope_hostile_matrix() -> void:
	var short_uuid: Array = PLAYER_B_BYTES.slice(0, 15)
	var oversized_uuid: Array = PLAYER_B_BYTES + [0x01]
	var v2_fields := _v2_fields()
	var cases := [
		{"label": "not a map", "bytes": _packed([0x01])},
		{"label": "empty input", "bytes": PackedByteArray()},
		{"label": "truncated header", "bytes": _packed([0x83, 0xAB])},
		{
			"label": "duplicate key",
			"bytes": _envelope(v2_fields, [0x84]) + _payload_field([0x02]),
		},
		{
			"label": "unknown field",
			"bytes": _envelope(v2_fields + [_field("extra", _bin_value([0x01]))]),
		},
		{"label": "trailing byte", "bytes": _envelope(v2_fields) + PackedByteArray([0x00])},
		{
			"label": "missing payload",
			"bytes": _envelope([_uuid_field(), _encoding_field("message_pack")]),
		},
		{
			"label": "short uuid",
			"bytes":
			_envelope(
				[
					_field("from_player", _bin_value(short_uuid)),
					_encoding_field("message_pack"),
					_payload_field([])
				]
			),
		},
		{
			"label": "oversized uuid",
			"bytes":
			_envelope(
				[
					_field("from_player", _bin_value(oversized_uuid)),
					_encoding_field("message_pack"),
					_payload_field([])
				]
			),
		},
		{
			"label": "uuid as string",
			"bytes":
			_envelope(
				[
					_field("from_player", _string_value("player-b-as-string")),
					_encoding_field("message_pack"),
					_payload_field([])
				]
			),
		},
		{
			"label": "payload as string",
			"bytes":
			_envelope(
				[
					_uuid_field(),
					_encoding_field("message_pack"),
					_field("payload", _string_value("zz"))
				]
			),
		},
		{
			"label": "v2 json encoding",
			"bytes": _envelope([_uuid_field(), _encoding_field("json"), _payload_field([])]),
		},
		{
			"label": "v2 rkyv encoding",
			"bytes": _envelope([_uuid_field(), _encoding_field("rkyv"), _payload_field([])]),
		},
		{
			"label": "unknown encoding",
			"bytes": _envelope([_uuid_field(), _encoding_field("proto"), _payload_field([])]),
		},
		{
			"label": "v3 seq only",
			"bytes": _envelope(v2_fields + [_field("seq", _raw([0x03]))], [0x84]),
		},
		{
			"label": "v3 epoch only",
			"bytes": _envelope(v2_fields + [_field("epoch", _raw([0xCE, 0, 0, 0, 0x2A]))], [0x84]),
		},
		{
			"label": "v3 zero seq",
			"bytes":
			_envelope(
				(
					v2_fields
					+ [_field("seq", _raw([0x00])), _field("epoch", _raw([0xCE, 0, 0, 0, 0x2A]))]
				),
				[0x85]
			),
		},
		{
			"label": "v3 zero epoch",
			"bytes":
			_envelope(
				(
					v2_fields
					+ [_field("seq", _raw([0x2A])), _field("epoch", _raw([0xCE, 0, 0, 0, 0]))]
				),
				[0x85]
			),
		},
		{
			"label": "v3 negative seq",
			"bytes":
			_envelope(
				(
					v2_fields
					+ [_field("seq", _raw([0xFF])), _field("epoch", _raw([0xCE, 0, 0, 0, 0x2A]))]
				),
				[0x85]
			),
		},
		{
			"label": "v3 seq as string",
			"bytes":
			_envelope(
				v2_fields + [_field("seq", _raw([0xA1, 0x39])), _field("epoch", _raw([0x2A]))],
				[0x85]
			),
		},
	]
	for case: Dictionary in cases:
		var result := SFBinaryFramesScript.decode_envelope(case["bytes"])
		_assert(result["ok"], false, "%s is rejected" % case["label"])
		_assert(
			not (result["error"] as String).is_empty(), true, "%s explains itself" % case["label"]
		)


func _test_v3_envelope_matrix() -> void:
	var payload := _payload_field([0x0B, 0x0C])
	var epoch := _raw([0xCE, 0x00, 0x00, 0x00, 0x2A])
	var cases := [
		{
			"label": "u64 seq",
			"encoding": "message_pack",
			"seq": _raw([0xCF, 0x01, 0, 0, 0, 0, 0, 0, 0]),
		},
		{"label": "fixint seq", "encoding": "json", "seq": _raw([0x05])},
		{"label": "uint8 seq", "encoding": "rkyv", "seq": _raw([0xCC, 0x09])},
		{"label": "uint32 seq", "encoding": "message_pack", "seq": _raw([0xCE, 0, 0, 0x10, 0x00])},
	]
	for case: Dictionary in cases:
		var bytes := _envelope(
			[
				_uuid_field(),
				_encoding_field(case["encoding"]),
				payload,
				_field("seq", case["seq"]),
				_field("epoch", epoch),
			],
			[0x85]
		)
		var result := SFBinaryFramesScript.decode_envelope(bytes)
		if not _assert(result["ok"], true, "v3 %s decodes" % case["label"]):
			continue
		_assert_equal(3, result["version"], "v3 %s version" % case["label"])
		_assert_equal(
			PackedByteArray([0x0B, 0x0C]), result["payload"], "v3 %s payload" % case["label"]
		)
		_assert_equal(
			SFTypesScript.game_data_encoding_from_string(case["encoding"]),
			result["encoding"],
			"v3 %s encoding" % case["label"]
		)


## Concatenates ordered field byte arrays, prefixing a fixmap header sized to
## the field count (unless an explicit header override is provided).
func _envelope(fields: Array, header_override: Array = []) -> PackedByteArray:
	var bytes := PackedByteArray()
	if header_override.is_empty():
		bytes.append(0x80 | fields.size())
	else:
		bytes.append_array(_packed(header_override))
	for field: PackedByteArray in fields:
		bytes.append_array(field)
	return bytes


## Canonical v2 field triple: from_player, encoding, payload.
func _v2_fields() -> Array:
	return [_uuid_field(), _encoding_field("message_pack"), _payload_field([0x01])]


func _uuid_field() -> PackedByteArray:
	return _field("from_player", _bin_value(PLAYER_B_BYTES))


func _encoding_field(token: String) -> PackedByteArray:
	return _field("encoding", _string_value(token))


func _payload_field(codepoints: Array) -> PackedByteArray:
	return _field("payload", _bin_value(codepoints))


## Prefixes a fixstr key onto raw value bytes.
func _field(key: String, value_bytes: PackedByteArray) -> PackedByteArray:
	var bytes := _string_value(key)
	bytes.append_array(value_bytes)
	return bytes


func _bin_value(codepoints: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.append(0xC4)
	bytes.append(codepoints.size())
	bytes.append_array(_packed(codepoints))
	return bytes


func _string_value(value: String) -> PackedByteArray:
	var encoded := value.to_utf8_buffer()
	var bytes := PackedByteArray()
	bytes.append(0xA0 | encoded.size())
	bytes.append_array(encoded)
	return bytes


func _raw(codepoints: Array) -> PackedByteArray:
	return _packed(codepoints)


func _packed(codepoints: Array) -> PackedByteArray:
	var packed := PackedByteArray()
	packed.resize(codepoints.size())
	for index: int in codepoints.size():
		packed[index] = codepoints[index]
	return packed


func _string_codepoints(value: String) -> Array:
	var array: Array = []
	for byte: int in value.to_utf8_buffer():
		array.append(byte)
	return array


func _assert(condition: bool, expected: bool, label: String) -> bool:
	if condition != expected:
		_failures.append("%s: expected %s, got %s" % [label, expected, condition])
		return false
	return true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
		var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
		_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
		return false
	return true
