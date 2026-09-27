extends RefCounted

## Issue #161: seeded, deterministic fuzz campaign over the byte-receiving
## decode surface (Locked Decision 4 keeps CI deterministic, so the corpus is
## fixed-seed, not random per run). Three paranoid properties per decoder:
## any input yields a well-formed fail-closed result (never a script abort,
## never a hang, never a non-finite float), every truncation of a valid frame
## is refused, and legal values survive encode/decode bit-exactly. Explicit
## vectors pin the 8/16/32-bit length-header paths the curated hostile
## matrices never reach. Failures report the input bytes; a re-run replays
## exactly via the file's fixed seeds.

const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const _MSGPACK_CORPUS_SEED := 0x516F1BEF
const _TEXT_CORPUS_SEED := 0x516F1BE0

const _SMALL_CORPUS_LENGTHS := 65
const _SMALL_CORPUS_PER_LENGTH := 30
const _MEDIUM_CORPUS_COUNT := 300
const _MEDIUM_CORPUS_MAX_LENGTH := 256
const _TEXT_NOISE_COUNT := 300
const _ROUND_TRIP_COUNT := 200
const _MAX_GENERATED_DEPTH := 6

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
## patterns at runtime: GDScript folds subnormal literals (5e-324 -> 0.0) in
## const context, and the engine formatter cannot render subnormals or the
## min normal at all (String.num gives "0"), so those floats refuse at encode
## by design — the boundaries here are the extremes that must survive.
static var _float_boundary_values: Array[float] = _float_boundaries()

var _failures: Array = []
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


static func run() -> Array:
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
		_test_envelope_truncation_and_mutations_fail_closed,
		_test_envelope_length_header_attacks_fail_closed,
		_test_text_envelope_truncation_and_noise_fail_closed,
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
