extends RefCounted

## Issue #161: seeded, deterministic fuzz campaign over the byte-receiving
## decode surface (Locked Decision 4 keeps CI deterministic, so the corpus is
## fixed-seed, not random per run). Three paranoid properties per decoder:
## any input yields a well-formed fail-closed result (never a script abort,
## never a hang, never a non-finite float), every truncation of a valid frame
## is refused, and legal values survive encode/decode bit-exactly. Explicit
## vectors pin the 8/16/32-bit length-header paths the curated hostile
## matrices never reach. Failures report the input bytes; a re-run replays
## exactly via the file's fixed seeds. The JSON-carried binary-payload codec
## (`SFBinaryCodec.decode_payload`, the `game_data_binary_received` text-form
## surface) gets the same treatment: canonical round-trip on accept, indexed
## diagnostics on refuse, and truncation prefixes that decode to exact byte
## prefixes.

const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFBinaryCodecScript = preload("res://addons/signal_fish/protocol/sf_binary_codec.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const _MSGPACK_CORPUS_SEED := 0x516F1BEF
const _TEXT_CORPUS_SEED := 0x516F1BE0
const _CODEC_CORPUS_SEED := 0x516F1BE1

const _SMALL_CORPUS_LENGTHS := 65
const _SMALL_CORPUS_PER_LENGTH := 30
const _MEDIUM_CORPUS_COUNT := 300
const _MEDIUM_CORPUS_MAX_LENGTH := 256
const _TEXT_NOISE_COUNT := 300
const _ROUND_TRIP_COUNT := 200
const _MAX_GENERATED_DEPTH := 6
const _CODEC_NOISE_COUNT := 300

const _INT_BOUNDARIES := [
	0,
	1,
	-1,
	0x7F,
	0x80,
	0xFF,
	0x100,
	0xFFFF,
	0x10000,
	0xFFFFFFFF,
	0x100000000,
	9223372036854775807,
	-9223372036854775807 - 1,
	-2147483648,
	2147483647
]
## Extreme doubles for the round-trip and truncation vectors, built from bit
## patterns at runtime: GDScript folds subnormal decimal literals (5e-324 ->
## +0.0) at parse time, so no literal can carry the denormal boundary. The
## JSON envelope path additionally refuses subnormals and the min normal
## (the engine formatter renders them "0"), while the MessagePack codec
## round-trips them bit-exactly -- the extremes here are the ones the
## round-trip vectors must survive through both paths.
static var _float_boundary_values: Array[float] = _float_boundaries()

var _failures: Array[String] = []
var _test_done := false


func _done() -> void:
	_test_done = true


static func _float_boundaries() -> Array[float]:
	var values: Array[float] = [0.0, 1.5, -2.25, 1e300, 3.141592653589793]
	values.append(_double_from_bits(-0x8000000000000000))
	values.append(_double_from_bits(0x7FEFFFFFFFFFFFFF))
	return values


static func _double_from_bits(bits: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(8)
	for offset: int in 8:
		bytes[offset] = (bits >> (offset * 8)) & 0xFF
	return bytes.decode_double(0)


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_msgpack_random_bytes_fail_closed,
		_test_msgpack_truncation_sweep_fail_closed,
		_test_msgpack_mutations_stay_typed,
		_test_msgpack_length_header_attacks_fail_closed,
		_test_msgpack_random_values_round_trip,
		_test_binary_codec_base64_fail_closed,
		_test_binary_codec_byte_array_fail_closed,
		_test_binary_codec_decode_echo_bounded,
		_test_binary_codec_truncation_prefixes,
		_test_binary_codec_encode_round_trip,
		_test_envelope_truncation_and_mutations_fail_closed,
		_test_envelope_length_header_attacks_fail_closed,
		_test_text_envelope_truncation_and_noise_fail_closed,
		_test_near_valid_text_frames_fail_closed,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _test_msgpack_random_bytes_fail_closed() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _MSGPACK_CORPUS_SEED
	var decodes := 0
	var ok_count := 0
	for length: int in _SMALL_CORPUS_LENGTHS:
		for _iteration: int in _SMALL_CORPUS_PER_LENGTH:
			decodes += 1
			if _fuzz_msgpack(_random_bytes(rng, length), "random length %d" % length):
				ok_count += 1
	for _iteration: int in _MEDIUM_CORPUS_COUNT:
		var length := rng.randi_range(_SMALL_CORPUS_LENGTHS, _MEDIUM_CORPUS_MAX_LENGTH)
		var input := _random_bytes(rng, length)
		input[0] = _random_marker(rng)
		decodes += 1
		if _fuzz_msgpack(input, "biased length %d" % length):
			ok_count += 1
	# Sanity pins: the corpus must exercise both outcomes, not silently
	# degenerate into all-refused (which would test nothing).
	_assert(decodes >= 2000, "msgpack random corpus ran %d decodes" % decodes)
	_assert(ok_count > 0, "msgpack random corpus had at least one clean decode")
	_assert(ok_count < decodes, "msgpack random corpus had at least one refusal")
	_done()


func _test_msgpack_truncation_sweep_fail_closed() -> void:
	var deep: Variant = 7
	for _depth: int in 10:
		var wrapper: Array = [deep]
		deep = wrapper
	var payloads := [
		["nested map", {"k": [1, -5, 2.5, "s", true, null, PackedByteArray([1, 2, 3])]}],
		["deep arrays", deep],
		["multibyte string", "é漢🦈"],
		["int boundaries", _INT_BOUNDARIES],
		["float boundaries", _float_boundary_values],
	]
	for entry: Array in payloads:
		var encoded: Dictionary = SFMsgpackScript.encode(entry[1])
		var encoded_ok: bool = encoded["ok"]
		if not _assert(encoded_ok, "%s fixture encodes" % entry[0]):
			continue
		var bytes: PackedByteArray = encoded["bytes"]
		for prefix_length: int in bytes.size():
			var result: Dictionary = SFMsgpackScript.decode(bytes.slice(0, prefix_length))
			var refused: bool = not result["ok"]
			_assert(
				refused and not str(result["error"]).is_empty(),
				(
					"%s truncated to %d/%d bytes is refused (error=%s)"
					% [entry[0], prefix_length, bytes.size(), result["error"]]
				)
			)
	_done()


func _test_msgpack_mutations_stay_typed() -> void:
	var encoded: Dictionary = SFMsgpackScript.encode(
		{"k": [1, -5, 2.5, "s", true, null, PackedByteArray([1, 2, 3])]}
	)
	var encoded_ok: bool = encoded["ok"]
	if not _assert(encoded_ok, "mutation fixture encodes"):
		_done()
		return
	var bytes: PackedByteArray = encoded["bytes"]
	var mutations := 0
	for index: int in bytes.size():
		for mode: int in 3:
			var mutated := bytes.duplicate()
			match mode:
				0:
					mutated[index] ^= 0xFF
				1:
					mutated[index] = 0xC7
				2:
					mutated[index] = 0xDF
			mutations += 1
			_fuzz_msgpack(mutated, "mutation index %d mode %d" % [index, mode])
	_assert(mutations == bytes.size() * 3, "mutation sweep ran %d decodes" % mutations)
	_done()


func _test_msgpack_length_header_attacks_fail_closed() -> void:
	var attacks := [
		["str32 declares 4 GiB", _concat(PackedByteArray([0xDB, 0xFF, 0xFF, 0xFF, 0xFF]))],
		["str16 declares 65535", PackedByteArray([0xDA, 0xFF, 0xFF])],
		["str8 declares 255", PackedByteArray([0xD9, 0xFF])],
		["bin32 declares 4 GiB", PackedByteArray([0xC6, 0xFF, 0xFF, 0xFF, 0xFF])],
		["bin16 declares 65535", PackedByteArray([0xC5, 0xFF, 0xFF])],
		["bin8 declares 255", PackedByteArray([0xC4, 0xFF])],
		["array32 declares 4 GiB", PackedByteArray([0xDD, 0xFF, 0xFF, 0xFF, 0xFF])],
		["array16 declares 32 KiB", PackedByteArray([0xDC, 0x80, 0x00])],
		["map32 declares 4 GiB", PackedByteArray([0xDF, 0xFF, 0xFF, 0xFF, 0xFF])],
		["map16 declares 65535", PackedByteArray([0xDE, 0xFF, 0xFF])],
		["float32 truncated", PackedByteArray([0xCA, 0x00, 0x00])],
		["float64 truncated", PackedByteArray([0xCB, 0x00])],
		["uint64 truncated", PackedByteArray([0xCF, 0x00])],
		["int64 truncated", PackedByteArray([0xD3])],
	]
	for attack: Array in attacks:
		var input: PackedByteArray = attack[1]
		var result: Dictionary = SFMsgpackScript.decode(input)
		var refused: bool = not result["ok"]
		_assert(
			refused and not str(result["error"]).is_empty(),
			"msgpack %s is refused (error=%s)" % [attack[0], result["error"]]
		)
	# Positive pins: the same header forms must decode when honest, so the
	# guards reject the length, not the marker width.
	var honest := [
		["str16 honest", _concat(PackedByteArray([0xDA, 0x00, 0x02]), _ascii("ab")), "ab"],
		[
			"bin16 honest",
			_concat(PackedByteArray([0xC5, 0x00, 0x02, 1, 2])),
			PackedByteArray([1, 2]),
		],
		["str32 honest", _concat(PackedByteArray([0xDB, 0, 0, 0, 2]), _ascii("ab")), "ab"],
		[
			"bin32 honest",
			_concat(PackedByteArray([0xC6, 0, 0, 0, 3, 1, 2, 3])),
			PackedByteArray([1, 2, 3]),
		],
		[
			"array32 honest",
			_concat(PackedByteArray([0xDD, 0, 0, 0, 2, 0x01, 0x02])),
			[1, 2],
		],
		[
			"map32 honest",
			_concat(PackedByteArray([0xDF, 0, 0, 0, 1, 0xA1]), _ascii("k"), PackedByteArray([1])),
			{"k": 1},
		],
	]
	for entry: Array in honest:
		var input: PackedByteArray = entry[1]
		var label: String = entry[0]
		var result: Dictionary = SFMsgpackScript.decode(input)
		var decoded_ok: bool = result["ok"]
		if not _assert(decoded_ok, "msgpack %s decodes (error=%s)" % [label, result["error"]]):
			continue
		_assert_round_trip(entry[2], result["value"], label)
	_done()


func _test_msgpack_random_values_round_trip() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _MSGPACK_CORPUS_SEED
	var round_trips := 0
	for _iteration: int in _ROUND_TRIP_COUNT:
		var value: Variant = _random_value(rng, 0)
		var encoded: Dictionary = SFMsgpackScript.encode(value)
		var encoded_ok: bool = encoded["ok"]
		if not _assert(encoded_ok, "generated value encodes"):
			continue
		var encoded_bytes: PackedByteArray = encoded["bytes"]
		var decoded: Dictionary = SFMsgpackScript.decode(encoded_bytes)
		var decoded_ok: bool = decoded["ok"]
		if not _assert(decoded_ok, "generated value decodes (error=%s)" % decoded["error"]):
			continue
		round_trips += 1
		_assert_round_trip(value, decoded["value"], "round trip %d" % round_trips)
	_assert(round_trips == _ROUND_TRIP_COUNT, "round-trip corpus ran %d cases" % round_trips)
	_done()


func _test_binary_codec_base64_fail_closed() -> void:
	# Handpicked canonical and hostile vectors: accepts pin byte-exact decodes
	# plus the canonical re-encode proof; refuses pin the diagnostic class.
	for case: Dictionary in _codec_base64_cases():
		var input: String = case["input"]
		var result: Dictionary = SFBinaryCodecScript.decode_payload(input)
		var ok: bool = result["ok"]
		var expected_accept: bool = case["accept"]
		if not _assert(
			ok == expected_accept, "base64 %s decodes=%s expected=%s" % [input, ok, expected_accept]
		):
			continue
		if expected_accept:
			var bytes: PackedByteArray = result["bytes"]
			var expected_hex: String = case["bytes"]
			_assert(
				bytes.hex_encode() == expected_hex,
				"base64 %s decodes to %s (got %s)" % [input, expected_hex, bytes.hex_encode()]
			)
			_codec_canonical_round_trip(bytes, input, "base64 %s" % input)
		else:
			var error := _codec_refusal(result, "base64 %s" % input)
			var expected_reason: String = case["reason"]
			_assert(
				error.contains(expected_reason),
				"base64 %s diagnostic names %s (%s)" % [input, expected_reason, error]
			)
	# Seeded noise: every input is well-formed, accepts are canonical
	# round-trips, refusals carry diagnostics, and both outcomes occur.
	var rng := RandomNumberGenerator.new()
	rng.seed = _CODEC_CORPUS_SEED
	var alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n @\t-_é@"
	var accepts := 0
	var refuses := 0
	for _iteration: int in _CODEC_NOISE_COUNT:
		var text := ""
		for _piece: int in rng.randi_range(0, 32):
			text += alphabet[rng.randi_range(0, alphabet.length() - 1)]
		var result: Dictionary = SFBinaryCodecScript.decode_payload(text)
		if not _codec_shape(result, "base64 noise [%s]" % text):
			continue
		var ok: bool = result["ok"]
		if not ok:
			refuses += 1
			_codec_refusal(result, "base64 noise [%s]" % text)
			continue
		accepts += 1
		var bytes: PackedByteArray = result["bytes"]
		_codec_canonical_round_trip(bytes, text, "base64 noise [%s]" % text)
	_assert(
		accepts > 0 and refuses > 0,
		"base64 noise corpus exercised both outcomes (%d accepts, %d refuses)" % [accepts, refuses]
	)
	_done()


func _test_binary_codec_byte_array_fail_closed() -> void:
	# Boundary matrix, data-driven: every entry pins decode-or-refuse plus the
	# surviving byte or the diagnostic class.
	for case: Dictionary in _codec_byte_cases():
		var value: Variant = case["value"]
		var result: Dictionary = SFBinaryCodecScript.decode_payload([value])
		var ok: bool = result["ok"]
		var expected_accept: bool = case["accept"]
		var label := "byte case %s" % var_to_str(value)
		if not _assert(
			ok == expected_accept, "%s decodes=%s expected=%s" % [label, ok, expected_accept]
		):
			continue
		if expected_accept:
			var bytes: PackedByteArray = result["bytes"]
			var expected_byte: int = case["byte"]
			_assert_equal(expected_byte, bytes[0] if bytes.size() == 1 else -1, "%s byte" % label)
			continue
		var error := _codec_refusal(result, label)
		_assert(
			error.contains("non-number") or error.contains("outside 0..255"),
			"%s diagnostic names the reason (%s)" % [label, error]
		)
	# Seeded noise: mixed-value arrays are byte-exact or refused with an index.
	var rng := RandomNumberGenerator.new()
	rng.seed = _CODEC_CORPUS_SEED
	var noise_accepts := 0
	var noise_refuses := 0
	for _iteration: int in _CODEC_NOISE_COUNT:
		var values: Array = []
		for _entry: int in rng.randi_range(0, 16):
			match rng.randi_range(0, 6):
				0:
					values.append(rng.randi_range(-300, 300))
				1:
					values.append(rng.randf_range(-300.0, 300.0))
				2:
					values.append(float(rng.randi_range(0, 255)))
				3:
					values.append("x")
				4:
					values.append(null)
				5:
					values.append(rng.randf_range(0.0, 1.0))
				_:
					values.append([rng.randi_range(0, 255)])
		var result: Dictionary = SFBinaryCodecScript.decode_payload(values)
		var label := "array noise %s" % var_to_str(values)
		if not _codec_shape(result, label):
			continue
		var ok: bool = result["ok"]
		if not ok:
			noise_refuses += 1
			var error := _codec_refusal(result, label)
			_assert(
				error.contains("payload byte array["),
				"%s refusal names the element index (%s)" % [label, error]
			)
			continue
		noise_accepts += 1
		var bytes: PackedByteArray = result["bytes"]
		if not _assert(
			bytes.size() == values.size(), "%s keeps its size (%d)" % [label, bytes.size()]
		):
			continue
		for index: int in values.size():
			var raw: float = values[index]
			_assert(
				int(raw) == bytes[index],
				"%s [%d] survives byte-exactly (%d vs %d)" % [label, index, int(raw), bytes[index]]
			)
	_assert(
		noise_accepts > 0 and noise_refuses > 0,
		(
			"array noise corpus exercised both outcomes (%d accepts, %d refuses)"
			% [noise_accepts, noise_refuses]
		)
	)
	_done()


func _test_binary_codec_decode_echo_bounded() -> void:
	# Issue #289: the echoed entry is wire-derived text, so it renders
	# through the #279 diagnostic contract (capped, control-escaped,
	# single-line) while legit values keep a readable reason.
	for case: Dictionary in [
		{"value": "1", "reason": "non-number", "echo": '""1""'},
		{"value": 0.5, "reason": "outside 0..255", "echo": '"0.5"'},
	]:
		var value: Variant = case["value"]
		var reason: String = case["reason"]
		var echo: String = case["echo"]
		var result: Dictionary = SFBinaryCodecScript.decode_payload([value])
		var ok: bool = result["ok"]
		_assert(not ok, "%s stays refused" % reason)
		var error := _codec_refusal(result, reason)
		_assert(error.contains(reason), "%s names the reason (%s)" % [reason, error])
		_assert(error.contains(echo), "%s echoes a readable token (%s)" % [reason, error])
	var hostile := "a\nb".repeat(20000)
	var hostile_result: Dictionary = SFBinaryCodecScript.decode_payload([hostile])
	var hostile_ok: bool = hostile_result["ok"]
	_assert(not hostile_ok, "a hostile string entry stays refused")
	var hostile_error := _codec_refusal(hostile_result, "hostile string entry")
	_assert(
		hostile_error.contains("non-number"),
		"hostile string entry names the reason (%s)" % hostile_error
	)
	_assert(not hostile_error.contains("\n"), "the diagnostic stays one line")
	_assert(hostile_error.contains("a\\x0Ab"), "newlines render as escapes (%s)" % hostile_error)
	_assert(
		hostile_error.length() < 200,
		"the diagnostic stays bounded (%d chars)" % hostile_error.length()
	)
	_done()


func _test_binary_codec_truncation_prefixes() -> void:
	# Base64 prefixes either refuse or decode to the exact byte prefix of the
	# full payload (block code semantics); nothing crashes and every refusal
	# keeps a diagnostic.
	for valid: String in ["yv4=", "eHh5", "YWJjZGVmZ2hpamtsbW5vcA==", "/w==", "AAAA"]:
		var full: Dictionary = SFBinaryCodecScript.decode_payload(valid)
		var full_ok: bool = full["ok"]
		if not _assert(full_ok, "%s baseline decodes" % valid):
			continue
		var full_bytes: PackedByteArray = full["bytes"]
		for cut: int in valid.length() + 1:
			var prefix := valid.substr(0, cut)
			var result: Dictionary = SFBinaryCodecScript.decode_payload(prefix)
			var label := "%s prefix %d" % [valid, cut]
			var ok: bool = result["ok"]
			if not ok:
				_codec_refusal(result, label)
				continue
			var bytes: PackedByteArray = result["bytes"]
			_assert(
				bytes.size() <= full_bytes.size(),
				"%s never grows (%d > %d)" % [label, bytes.size(), full_bytes.size()]
			)
			_assert(
				bytes == full_bytes.slice(0, bytes.size()),
				"%s decodes to the full payload's byte prefix" % label
			)
	# The empty string is the zero-byte payload, not an error.
	var empty: Dictionary = SFBinaryCodecScript.decode_payload("")
	var empty_ok: bool = empty["ok"]
	var empty_bytes: PackedByteArray = empty["bytes"]
	_assert(empty_ok and empty_bytes.is_empty(), "empty payload is zero bytes (ok=%s)" % empty_ok)
	_done()


func _test_binary_codec_encode_round_trip() -> void:
	# Both encode legs survive decode byte-exactly and agree with each other.
	var rng := RandomNumberGenerator.new()
	rng.seed = _CODEC_CORPUS_SEED
	var batches: Array[PackedByteArray] = [
		PackedByteArray([0, 1, 127, 128, 254, 255]),
		PackedByteArray(),
	]
	for _iteration: int in 100:
		batches.append(_random_bytes(rng, rng.randi_range(1, 64)))
	for bytes: PackedByteArray in batches:
		var as_array: Dictionary = SFBinaryCodecScript.decode_payload(
			SFBinaryCodecScript.encode_payload_as_array(bytes)
		)
		if not _codec_shape(as_array, "array leg %s" % bytes.hex_encode()):
			continue
		var array_ok: bool = as_array["ok"]
		_assert(array_ok, "array leg %s decodes" % bytes.hex_encode())
		var from_array: PackedByteArray = as_array["bytes"]
		_assert(from_array == bytes, "array leg %s survives byte-exactly" % bytes.hex_encode())
		if not bytes.is_empty():
			var as_base64: Dictionary = SFBinaryCodecScript.decode_payload(
				SFBinaryCodecScript.encode_payload_as_base64(bytes)
			)
			if not _codec_shape(as_base64, "base64 leg %s" % bytes.hex_encode()):
				continue
			var base64_ok: bool = as_base64["ok"]
			_assert(base64_ok, "base64 leg %s decodes" % bytes.hex_encode())
			var from_base64: PackedByteArray = as_base64["bytes"]
			_assert(
				from_base64 == bytes, "base64 leg %s survives byte-exactly" % bytes.hex_encode()
			)
			_assert(from_base64 == from_array, "both legs agree for %s" % bytes.hex_encode())
	_done()


static func _codec_base64_cases() -> Array[Dictionary]:
	return [
		{"input": "yv4=", "accept": true, "bytes": "cafe"},
		{"input": "yv4", "accept": true, "bytes": "cafe"},
		{"input": "eHh4", "accept": true, "bytes": "787878"},
		{"input": "AA==", "accept": true, "bytes": "00"},
		{"input": "AAA=", "accept": true, "bytes": "0000"},
		{"input": "AAAA", "accept": true, "bytes": "000000"},
		{"input": "/w==", "accept": true, "bytes": "ff"},
		{"input": "////", "accept": true, "bytes": "ffffff"},
		{"input": "ABCD", "accept": true, "bytes": "001083"},
		{"input": "YWJjZA==", "accept": true, "bytes": "61626364"},
		{"input": "YWJjZA", "accept": true, "bytes": "61626364"},
		{"input": "", "accept": true, "bytes": ""},
		{"input": "yv4==", "accept": false, "reason": "length is invalid"},
		{"input": "yv=4", "accept": false, "reason": "padding is invalid"},
		{"input": "AA=A", "accept": false, "reason": "padding is invalid"},
		{"input": "yv4=\t", "accept": false, "reason": "padding is invalid"},
		{"input": "=", "accept": false, "reason": "length is invalid"},
		{"input": "==", "accept": false, "reason": "length is invalid"},
		{"input": "====", "accept": false, "reason": "padding is invalid"},
		{"input": "A", "accept": false, "reason": "length is invalid"},
		{"input": "AAAAA", "accept": false, "reason": "length is invalid"},
		{"input": "AB", "accept": false, "reason": "base64 is invalid"},
		{"input": "ABC", "accept": false, "reason": "base64 is invalid"},
		{"input": "aaa=", "accept": false, "reason": "base64 is invalid"},
		{"input": "00==", "accept": false, "reason": "base64 is invalid"},
		{"input": "eHh=", "accept": false, "reason": "base64 is invalid"},
		{"input": "eHh4\n", "accept": false, "reason": "invalid characters"},
		{"input": " eHh4", "accept": false, "reason": "invalid characters"},
		{"input": "éHh4", "accept": false, "reason": "invalid characters"},
		{"input": "-_-_", "accept": false, "reason": "invalid characters"},
		{"input": "@/@@", "accept": false, "reason": "invalid characters"},
		{"input": "____", "accept": false, "reason": "invalid characters"},
	]


static func _codec_byte_cases() -> Array[Dictionary]:
	# -0.0 is built from bits at runtime: +/-0.0 literal folding is per-script
	# and unreliable (see _float_boundary_values).
	var negative_zero := _double_from_bits(-0x8000000000000000)
	return [
		{"value": 0, "accept": true, "byte": 0x00},
		{"value": 255, "accept": true, "byte": 0xFF},
		{"value": 255.0, "accept": true, "byte": 0xFF},
		{"value": negative_zero, "accept": true, "byte": 0x00},
		{"value": 0.5, "accept": false, "reason": "outside 0..255"},
		{"value": 255.5, "accept": false, "reason": "outside 0..255"},
		{"value": -1, "accept": false, "reason": "outside 0..255"},
		{"value": 256, "accept": false, "reason": "outside 0..255"},
		{"value": 1e308, "accept": false, "reason": "outside 0..255"},
		{"value": -1e308, "accept": false, "reason": "outside 0..255"},
		{"value": NAN, "accept": false, "reason": "outside 0..255"},
		{"value": INF, "accept": false, "reason": "outside 0..255"},
		{"value": -INF, "accept": false, "reason": "outside 0..255"},
		{"value": 9007199254740993, "accept": false, "reason": "outside 0..255"},
		{"value": 9223372036854775807, "accept": false, "reason": "outside 0..255"},
		{"value": -9223372036854775807 - 1, "accept": false, "reason": "outside 0..255"},
		{"value": true, "accept": false, "reason": "non-number"},
		{"value": "1", "accept": false, "reason": "non-number"},
		{"value": null, "accept": false, "reason": "non-number"},
		{"value": [1], "accept": false, "reason": "non-number"},
		{"value": {"a": 1}, "accept": false, "reason": "non-number"},
	]


## The decoder's documented strictness: an accepted payload re-encodes to the
## input padded back to its canonical form (unpadded accepts normalize), and
## only the empty input yields zero bytes. raw_to_base64(PackedByteArray())
## prints a native engine error, so the empty case never re-encodes here.
func _codec_canonical_round_trip(bytes: PackedByteArray, text: String, label: String) -> void:
	if bytes.is_empty():
		_assert(text.is_empty(), "%s: only empty input decodes to zero bytes" % label)
		return
	_assert(
		Marshalls.raw_to_base64(bytes) == _codec_canonical_base64(text),
		(
			"%s re-encodes to the canonical padded form (got %s)"
			% [label, Marshalls.raw_to_base64(bytes)]
		)
	)


static func _codec_canonical_base64(text: String) -> String:
	match text.length() % 4:
		0:
			return text
		2:
			return text + "=="
		3:
			return text + "="
		_:
			return ""


func _codec_shape(result: Dictionary, label: String) -> bool:
	return _assert(
		(
			typeof(result["ok"]) == TYPE_BOOL
			and typeof(result["error"]) == TYPE_STRING
			and typeof(result["bytes"]) == TYPE_PACKED_BYTE_ARRAY
		),
		"%s result keeps {ok, bytes, error}" % label
	)


func _codec_refusal(result: Dictionary, label: String) -> String:
	var error := str(result["error"])
	_assert(not error.is_empty(), "%s refusal carries a diagnostic" % label)
	return error


func _test_envelope_truncation_and_mutations_fail_closed() -> void:
	# Baseline first: the sweeps below are only meaningful against genuinely
	# valid frames.
	var baselines := [["v2 message_pack", _v2_envelope()], ["v3 json", _v3_envelope()]]
	for entry: Array in baselines:
		var bytes: PackedByteArray = entry[1]
		var label: String = entry[0]
		var baseline: Dictionary = SFBinaryFramesScript.decode_envelope(bytes)
		var baseline_ok: bool = baseline["ok"]
		if _assert(baseline_ok, "%s envelope baseline decodes" % label):
			var baseline_version: int = baseline["version"]
			_assert(
				baseline_version == (3 if label.begins_with("v3") else 2),
				"%s envelope baseline version" % label
			)
	for entry: Array in baselines:
		var bytes: PackedByteArray = entry[1]
		var label: String = entry[0]
		for prefix_length: int in bytes.size():
			var result: Dictionary = SFBinaryFramesScript.decode_envelope(
				bytes.slice(0, prefix_length)
			)
			var refused: bool = not result["ok"]
			_assert(
				refused and not str(result["error"]).is_empty(),
				(
					"%s envelope truncated to %d/%d bytes is refused (error=%s)"
					% [label, prefix_length, bytes.size(), result["error"]]
				)
			)
		for index: int in bytes.size():
			for flipped: int in [0xFF, 0x00]:
				var mutated := bytes.duplicate()
				mutated[index] = flipped
				_fuzz_envelope(mutated, "%s envelope byte %d" % [label, index])
	_done()


func _test_envelope_length_header_attacks_fail_closed() -> void:
	var uuid := _uuid_bytes()
	var attacks := [
		[
			"map32 declares 4 GiB entries",
			_concat(PackedByteArray([0xDF, 0xFF, 0xFF, 0xFF, 0xFF]), uuid),
		],
		["map16 truncated header", PackedByteArray([0xDE, 0xFF])],
		[
			"str32 key declares 4 GiB",
			PackedByteArray([0xDB, 0xFF, 0xFF, 0xFF, 0xFF]),
		],
		[
			"from_player bin32 declares 4 GiB",
			_envelope(_bin_field(0xC6, PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF]))),
		],
		[
			"from_player bin32 declares 16 with no data",
			_envelope(_bin_field(0xC6, PackedByteArray([0, 0, 0, 0x10]))),
		],
		[
			"payload bin32 declares 4 GiB",
			_envelope(
				_bin_field(0xC4, PackedByteArray([0x10]), uuid),
				PackedByteArray([0xC6, 0xFF, 0xFF, 0xFF, 0xFF])
			),
		],
		["not a map", uuid],
		["fixmap count with no fields", PackedByteArray([0x83])],
	]
	for attack: Array in attacks:
		var input: PackedByteArray = attack[1]
		var result: Dictionary = SFBinaryFramesScript.decode_envelope(input)
		var refused: bool = not result["ok"]
		_assert(
			refused and not str(result["error"]).is_empty(),
			"envelope %s is refused (error=%s)" % [attack[0], result["error"]]
		)
	# Positive pins: honest 16/32-bit width forms decode (rust parity: any
	# marker width that carries the value is legal).
	var wide := [
		[
			"from_player bin16 form",
			_envelope(_bin_field(0xC5, PackedByteArray([0x00, 0x10]), uuid)),
		],
		[
			"from_player bin32 form",
			_envelope(_bin_field(0xC6, PackedByteArray([0, 0, 0, 0x10]), uuid)),
		],
		[
			"payload bin32 form",
			_envelope(
				_bin_field(0xC4, PackedByteArray([0x10]), uuid),
				PackedByteArray([0xC6, 0, 0, 0, 2, 0xCA, 0xFE])
			),
		],
	]
	for entry: Array in wide:
		var input: PackedByteArray = entry[1]
		var result: Dictionary = SFBinaryFramesScript.decode_envelope(input)
		var decoded_ok: bool = result["ok"]
		_assert(decoded_ok, "envelope %s decodes (error=%s)" % [entry[0], result["error"]])
	_done()


func _test_text_envelope_truncation_and_noise_fail_closed() -> void:
	var envelopes := ['{"type":"Pong"}', '{"type":"SpectatorLeft"}']
	for text: String in envelopes:
		for prefix_length: int in text.length():
			var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
				text.substr(0, prefix_length)
			)
			_assert_protocol_error(
				decoded, "%s truncated to %d/%d chars" % [text, prefix_length, text.length()]
			)
	var rng := RandomNumberGenerator.new()
	rng.seed = _TEXT_CORPUS_SEED
	var decodes := 0
	var protocol_errors := 0
	for _iteration: int in _TEXT_NOISE_COUNT:
		var noise := _random_bytes(rng, rng.randi_range(0, 96))
		decodes += 1
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
			noise.get_string_from_utf8()
		)
		var input_label := "text noise %d (input=%s)" % [decodes, noise.hex_encode()]
		if not _assert(decoded != null, "%s decodes to an event" % input_label):
			continue
		if not _assert(
			not String(decoded.signal_name).is_empty(), "%s carries a signal" % input_label
		):
			continue
		if str(decoded.signal_name) != "protocol_error":
			continue
		protocol_errors += 1
		_assert(
			(
				decoded.args.size() > 0
				and typeof(decoded.args[0]) == TYPE_STRING
				and not str(decoded.args[0]).is_empty()
			),
			"%s protocol_error message non-empty" % input_label
		)
	# Outcome pin: every noise input must land on protocol_error. Anything
	# else means hostile bytes decoded as a protocol event (fail-open).
	_assert(
		protocol_errors == _TEXT_NOISE_COUNT,
		"text noise corpus fully refused (%d/%d)" % [protocol_errors, decodes]
	)
	_done()


static func near_valid_text_cases() -> Array[Dictionary]:
	var frames := _valid_text_frames()
	var cases: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = _TEXT_CORPUS_SEED
	for type_name: String in ["RoomJoined", "GameData", "Reconnected"]:
		var frame: String = frames[type_name]
		var structural_offsets := _json_structural_offsets(frame)
		for length: int in frame.length():
			if length % 11 == 0 or length >= frame.length() - 3:
				cases.append(
					{"label": "%s prefix %d" % [type_name, length], "text": frame.substr(0, length)}
				)
		for iteration: int in 48:
			var offset: int = structural_offsets[rng.randi_range(0, structural_offsets.size() - 1)]
			var mutated := frame.substr(0, offset) + "#" + frame.substr(offset + 1)
			cases.append(
				{
					"label":
					(
						"%s seed %d mutation %d at %d"
						% [type_name, _TEXT_CORPUS_SEED, iteration, offset]
					),
					"text": mutated
				}
			)
	var room: String = frames["RoomJoined"]
	cases.append(
		{
			"label": "escaped top-level duplicate",
			"text":
			room.replace('"type":"RoomJoined"', '"type":"RoomJoined","\\u0074ype":"RoomLeft"')
		}
	)
	cases.append(
		{
			"label": "escaped room-id duplicate",
			"text":
			room.replace(
				'"room_id":', '"\\u0072oom_id":"20000000-0000-0000-0000-000000000002","room_id":'
			)
		}
	)
	var game: String = frames["GameData"]
	cases.append(
		{
			"label": "wrong sender type",
			"text":
			game.replace(
				'"from_player":"10000000-0000-0000-0000-000000000002"', '"from_player":123'
			)
		}
	)
	var reconnect_text: String = frames["Reconnected"]
	var reconnected: Dictionary = JSON.parse_string(reconnect_text)
	var reconnect_data: Dictionary = reconnected["data"]
	reconnect_data.erase("missed_events")
	cases.append({"label": "missing replay array", "text": JSON.stringify(reconnected)})
	var invalid_fields := {
		"RoomJoined":
		[
			["room_id", "not-a-uuid"],
			["player_id", 7],
			["current_players", {}],
			["ready_players", "all"],
			["lobby_state", "missing"]
		],
		"GameData":
		[
			["from_player", "not-a-uuid"],
			["from_player", 7],
			["from_player", null],
			["from_player", ""]
		],
		"Reconnected":
		[
			["room_id", "not-a-uuid"],
			["player_id", 7],
			["current_players", {}],
			["missed_events", {}],
			["lobby_state", "missing"]
		]
	}
	for type_name: String in ["RoomJoined", "GameData", "Reconnected"]:
		var original: String = frames[type_name]
		var fields: Array = invalid_fields[type_name]
		for mutation: Array in fields:
			var envelope: Dictionary = JSON.parse_string(original)
			var data: Dictionary = envelope["data"]
			data[mutation[0]] = mutation[1]
			cases.append(
				{
					"label": "%s invalid %s" % [type_name, mutation[0]],
					"text": JSON.stringify(envelope)
				}
			)
	return cases


static func _json_structural_offsets(frame: String) -> Array[int]:
	var offsets: Array[int] = []
	var in_string := false
	var escaped := false
	for index: int in frame.length():
		var character := frame[index]
		if escaped:
			escaped = false
		elif in_string and character == "\\":
			escaped = true
		elif character == '"':
			in_string = not in_string
		elif not in_string and character in ["{", "}", "[", "]", ":", ","]:
			offsets.append(index)
	return offsets


static func _valid_text_frames() -> Dictionary:
	var frames := {}
	var source := FileAccess.get_file_as_string("res://tests/fixtures/v2_server_messages.jsonl")
	for line: String in source.split("\n", false):
		if not line.begins_with("{"):
			continue
		var envelope: Dictionary = JSON.parse_string(line)
		if envelope["type"] in ["RoomJoined", "GameData", "Reconnected"]:
			frames[envelope["type"]] = line
	return frames


func _test_near_valid_text_frames_fail_closed() -> void:
	var frames := _valid_text_frames()
	for type_name: String in ["RoomJoined", "GameData", "Reconnected"]:
		var frame: String = frames[type_name]
		_assert(
			SFEventsScript.decode_text(frame).signal_name != &"protocol_error",
			"%s fixture is valid" % type_name
		)
		for length: int in frame.length():
			_assert_protocol_error(
				SFEventsScript.decode_text(frame.substr(0, length)),
				(
					"%s prefix %d input=%s"
					% [type_name, length, frame.substr(0, length).to_utf8_buffer().hex_encode()]
				)
			)
	var cases := near_valid_text_cases()
	_assert(cases.size() > 100, "near-valid corpus has broad coverage")
	for case: Dictionary in cases:
		var case_text: String = case["text"]
		_assert_protocol_error(
			SFEventsScript.decode_text(case_text),
			"%s input=%s" % [case["label"], case_text.to_utf8_buffer().hex_encode()]
		)
	var reconnect_text: String = frames["Reconnected"]
	var reconnected: Dictionary = JSON.parse_string(reconnect_text)
	var reconnect_data: Dictionary = reconnected["data"]
	var replay: Array = reconnect_data["missed_events"]
	replay.append({"type": "Reconnected", "data": reconnect_data.duplicate(true)})
	var nested: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(JSON.stringify(reconnected))
	_assert_equal("reconnected", String(nested.signal_name), "nested replay keeps baseline")
	var nested_events: Array = nested.args[1]
	var nested_tail: SFTypesScript.DecodedEvent = nested_events[-1]
	_assert_equal("protocol_error", String(nested_tail.signal_name), "nested replay is rejected")
	for count: int in [SFEventsScript.MAX_MISSED_EVENTS, SFEventsScript.MAX_MISSED_EVENTS + 1]:
		reconnect_data["missed_events"] = []
		var capped_replay: Array = reconnect_data["missed_events"]
		for index: int in count:
			capped_replay.append({"type": "Pong"})
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
			JSON.stringify(reconnected)
		)
		_assert_equal("reconnected", String(decoded.signal_name), "replay cap %d baseline" % count)
		var events: Array = decoded.args[1]
		_assert_equal(count, events.size(), "replay cap %d entries" % count)
		var tail: SFTypesScript.DecodedEvent = events[-1]
		_assert_equal(
			"protocol_error" if count > SFEventsScript.MAX_MISSED_EVENTS else "pong",
			String(tail.signal_name),
			"replay cap %d tail" % count
		)
	_done()


## Decodes one hostile input and asserts the fail-closed contract: a
## well-formed result, non-empty error on refusal, and a legal value tree on
## success. Returns the ok flag so callers can pin outcome coverage.
func _fuzz_msgpack(input: PackedByteArray, label: String) -> bool:
	var result: Dictionary = SFMsgpackScript.decode(input)
	if not _assert_decode_well_formed(result, input, label):
		return false
	if result["ok"]:
		return _assert_legal_msgpack_value(
			result["value"], "%s (input=%s)" % [label, input.hex_encode()]
		)
	_assert(
		typeof(result["error"]) == TYPE_STRING and not str(result["error"]).is_empty(),
		"%s refusal carries a diagnostic (input=%s)" % [label, input.hex_encode()]
	)
	return false


func _fuzz_envelope(input: PackedByteArray, label: String) -> bool:
	var result: Dictionary = SFBinaryFramesScript.decode_envelope(input)
	var shape := _assert(
		(
			typeof(result["ok"]) == TYPE_BOOL
			and typeof(result["error"]) == TYPE_STRING
			and typeof(result["from_player"]) == TYPE_STRING
			and typeof(result["payload"]) == TYPE_PACKED_BYTE_ARRAY
			and typeof(result["encoding"]) == TYPE_INT
			and typeof(result["version"]) == TYPE_INT
		),
		"%s result keeps its documented shape" % label
	)
	if not shape:
		return false
	if not result["ok"]:
		return _assert(
			not str(result["error"]).is_empty(),
			"%s refusal carries a diagnostic (input=%s)" % [label, input.hex_encode()]
		)
	# A mutation that survives decode must still produce contract-shaped
	# fields: canonical UUID sender, a known encoding, a coherent version.
	var from_player: String = result["from_player"]
	var sender := _assert(
		(
			from_player.length() == 36
			and from_player[8] == "-"
			and from_player[13] == "-"
			and from_player[18] == "-"
			and from_player[23] == "-"
		),
		"%s decoded sender is canonical UUID text (%s)" % [label, from_player]
	)
	var known_encoding: int = result["encoding"]
	var encoding := _assert(
		known_encoding != SFTypesScript.GameDataEncoding.UNKNOWN,
		"%s decoded encoding is known (%d)" % [label, known_encoding]
	)
	var stamp_version: int = result["version"]
	var version := _assert(
		stamp_version == 2 or stamp_version == 3,
		"%s decoded version is 2 or 3 (%s)" % [label, stamp_version]
	)
	return sender and encoding and version


func _assert_decode_well_formed(result: Dictionary, input: PackedByteArray, label: String) -> bool:
	return _assert(
		(
			typeof(result["ok"]) == TYPE_BOOL
			and typeof(result["error"]) == TYPE_STRING
			and result.has("value")
		),
		"%s result keeps {ok, value, error} (input=%s)" % [label, input.hex_encode()]
	)


func _assert_legal_msgpack_value(value: Variant, label: String) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_PACKED_BYTE_ARRAY:
			return true
		TYPE_FLOAT:
			var as_float: float = value
			return _assert(is_finite(as_float), "%s float is finite (%s)" % [label, as_float])
		TYPE_ARRAY:
			for entry: Variant in value:
				if not _assert_legal_msgpack_value(entry, label):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not _assert(typeof(key) == TYPE_STRING, "%s map key is a string" % label):
					return false
				if not _assert_legal_msgpack_value(value[key], label):
					return false
			return true
		_:
			return _assert(
				false, "%s decoded a legal type, got %s" % [label, type_string(typeof(value))]
			)


## Strong round-trip equality: types must match exactly (a 1 vs 1.0 drift is
## a wire bug even though GDScript equality calls them equal).
func _assert_round_trip(expected: Variant, actual: Variant, label: String) -> bool:
	if typeof(expected) != typeof(actual):
		return _assert(
			false,
			(
				"%s keeps its type: expected %s, got %s"
				% [label, type_string(typeof(expected)), type_string(typeof(actual))]
			)
		)
	match typeof(expected):
		TYPE_ARRAY:
			return _assert_round_trip_array(expected, actual, label)
		TYPE_DICTIONARY:
			return _assert_round_trip_map(expected, actual, label)
		_:
			var equal: bool = expected == actual
			return _assert(equal, "%s value survives" % label)


func _assert_round_trip_array(expected: Variant, actual: Variant, label: String) -> bool:
	var expected_array: Array = expected
	var actual_array: Array = actual
	if not _assert(expected_array.size() == actual_array.size(), "%s array size survives" % label):
		return false
	for index: int in expected_array.size():
		if not _assert_round_trip(
			expected_array[index], actual_array[index], "%s [%d]" % [label, index]
		):
			return false
	return true


func _assert_round_trip_map(expected: Variant, actual: Variant, label: String) -> bool:
	var expected_map: Dictionary = expected
	var actual_map: Dictionary = actual
	if not _assert(expected_map.size() == actual_map.size(), "%s map size survives" % label):
		return false
	for key: Variant in expected_map:
		if not _assert(actual_map.has(key), "%s map key %s survives" % [label, key]):
			return false
		if not _assert_round_trip(expected_map[key], actual_map[key], "%s %s" % [label, key]):
			return false
	return true


func _random_value(rng: RandomNumberGenerator, depth: int) -> Variant:
	var kind := rng.randi_range(0, 11)
	if depth >= _MAX_GENERATED_DEPTH:
		kind = rng.randi_range(0, 9)
	var value: Variant = null
	match kind:
		0:
			value = null
		1:
			value = rng.randi_range(0, 1) == 1
		2:
			value = _INT_BOUNDARIES[rng.randi_range(0, _INT_BOUNDARIES.size() - 1)]
		3:
			value = rng.randi_range(-1000, 1000)
		4:
			value = _float_boundary_values[rng.randi_range(0, _float_boundary_values.size() - 1)]
		5:
			value = rng.randf_range(-1e9, 1e9)
		6, 7:
			value = _random_string(rng)
		8, 9:
			var bytes := PackedByteArray()
			for _byte: int in rng.randi_range(0, 16):
				bytes.append(rng.randi_range(0, 255))
			value = bytes
		10:
			var entries: Array = []
			for _entry: int in rng.randi_range(0, 4):
				entries.append(_random_value(rng, depth + 1))
			value = entries
		_:
			var map := {}
			for _entry: int in rng.randi_range(0, 4):
				map[_random_string(rng)] = _random_value(rng, depth + 1)
			value = map
	return value


func _random_string(rng: RandomNumberGenerator) -> String:
	var pieces := ["a", "Z", "9", "_", "é", "漢", "🦈", ""]
	var value := ""
	for _piece: int in rng.randi_range(0, 8):
		value += pieces[rng.randi_range(0, pieces.size() - 1)]
	return value


func _random_bytes(rng: RandomNumberGenerator, length: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(length)
	for index: int in length:
		bytes[index] = rng.randi_range(0, 255)
	return bytes


func _random_marker(rng: RandomNumberGenerator) -> int:
	var markers := [
		0x80,
		0x8F,
		0x90,
		0x9F,
		0xA0,
		0xBF,
		0xC0,
		0xC2,
		0xC3,
		0xC4,
		0xC5,
		0xC6,
		0xCA,
		0xCB,
		0xCC,
		0xCD,
		0xCE,
		0xCF,
		0xD0,
		0xD3,
		0xD9,
		0xDA,
		0xDB,
		0xDC,
		0xDD,
		0xDE,
		0xDF,
	]
	return markers[rng.randi_range(0, markers.size() - 1)]


func _ascii(text: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	for character: String in text:
		bytes.append(character.unicode_at(0))
	return bytes


func _uuid_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	for index: int in 16:
		bytes.append(0x10 + index)
	return bytes


## Assembles a 3-field envelope (from_player, encoding=message_pack, payload)
## around the given binary field bytes so attacks and width pins can swap one
## field without rewriting the rest. An omitted or empty [param payload]
## selects the default bin8 payload.
func _envelope(
	from_player: PackedByteArray, payload: PackedByteArray = PackedByteArray()
) -> PackedByteArray:
	var bytes := PackedByteArray([0x83])
	_append_fixstr(bytes, "from_player")
	bytes.append_array(from_player)
	_append_fixstr(bytes, "encoding")
	_append_fixstr(bytes, "message_pack")
	_append_fixstr(bytes, "payload")
	if payload.is_empty():
		bytes.append_array(_bin_field(0xC4, PackedByteArray([0x02]), PackedByteArray([0xCA, 0xFE])))
	else:
		bytes.append_array(payload)
	return bytes


## One binary field: marker, big-endian length, then [param content].
func _bin_field(
	marker: int, length_bytes: PackedByteArray, content: PackedByteArray = PackedByteArray()
) -> PackedByteArray:
	var bytes := PackedByteArray([marker])
	bytes.append_array(length_bytes)
	bytes.append_array(content)
	return bytes


func _v2_envelope() -> PackedByteArray:
	return _envelope(
		_bin_field(0xC4, PackedByteArray([0x10]), _uuid_bytes()),
		PackedByteArray([0xC4, 0x02, 0xCA, 0xFE])
	)


func _v3_envelope() -> PackedByteArray:
	var bytes := PackedByteArray([0x85])
	_append_fixstr(bytes, "from_player")
	bytes.append_array(_bin_field(0xC4, PackedByteArray([0x10]), _uuid_bytes()))
	_append_fixstr(bytes, "encoding")
	_append_fixstr(bytes, "json")
	_append_fixstr(bytes, "payload")
	bytes.append_array(PackedByteArray([0xC4, 0x02, 0x7B, 0x7D]))
	_append_fixstr(bytes, "seq")
	bytes.append(1)
	_append_fixstr(bytes, "epoch")
	bytes.append(1)
	return bytes


func _append_fixstr(bytes: PackedByteArray, text: String) -> void:
	bytes.append(0xA0 | text.length())
	bytes.append_array(text.to_utf8_buffer())


func _concat(
	first: PackedByteArray,
	second: PackedByteArray = PackedByteArray(),
	third: PackedByteArray = PackedByteArray()
) -> PackedByteArray:
	var bytes := first.duplicate()
	bytes.append_array(second)
	bytes.append_array(third)
	return bytes


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append(label)
		return false
	return true


func _assert_protocol_error(decoded: SFTypesScript.DecodedEvent, label: String) -> bool:
	if decoded == null:
		return _assert(false, "%s: expected protocol_error, got <null>" % label)
	if not _assert_equal("protocol_error", String(decoded.signal_name), label):
		return false
	return _assert(
		(
			decoded.args.size() == 1
			and typeof(decoded.args[0]) == TYPE_STRING
			and not str(decoded.args[0]).is_empty()
		),
		"%s protocol_error message must be non-empty" % label
	)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])
		return false
	return true
