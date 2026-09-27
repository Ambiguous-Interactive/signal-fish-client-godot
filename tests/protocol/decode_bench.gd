extends SceneTree

## Deterministic decode/encode hot-path micro-benchmark (issue #161).
## Opt-in, never part of CI suites: run with
##   godot --headless --path . --script tests/protocol/decode_bench.gd
## Prints best-of-runs microseconds per operation for the campaign candidates.

const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFJsonGuard = preload("res://addons/signal_fish/protocol/sf_json_guard.gd")
const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")

const _RUNS := 7

var _control_text := (
	'{"type":"RoomJoined","data":{"room_id":"20000000-0000-0000-0000-000000000001",'
	+ '"room_code":"ABC123","player_id":"10000000-0000-0000-0000-000000000001",'
	+ '"game_name":"reef-rally","max_players":4,"supports_authority":false,'
	+ '"current_players":[],"is_authority":false,"lobby_state":"waiting",'
	+ '"ready_players":[],"relay_type":"websocket"}}'
)

var _game_text := (
	'{"type":"GameData","data":{"from_player":"10000000-0000-0000-0000-000000000001",'
	+ '"data":{"x":1.5,"y":-2.25,"hp":99,"state":"running","seq":42}}}'
)

## Object-dense shape at the 256 KiB frame cap: ~31200 tiny objects, the
## guard's documented cap-bound case (issue #161 round 3). _init refuses to
## run when the frame drifts over the 262144-byte default cap.
var _object_dense_text := (
	'{"type":"GameData","data":{"from_player":"10000000-0000-0000-0000-000000000001",'
	+ '"data":[%s]}}' % ",".join(_tiny_objects())
)

## Prebuilt-frame cache: construction must not pollute decode timings.
var _frame_cache: Dictionary = {}
var _fresh_frames: Array[PackedByteArray] = []
var _miss_uuids: Array[PackedByteArray] = []
var _msgpack_payload := {"x": 1.5, "hp": 99, "state": "running", "seq": 42}
var _float_envelope_data := {}


func _init() -> void:
	if _object_dense_text.to_utf8_buffer().size() > 262144:
		push_error("object-dense bench frame exceeds the 256 KiB default cap")
		quit(1)
		return
	_bench("binary_v2_decode", 20000, func() -> void: _decode_envelope_or_fail(_v2_cached(64)))
	_bench("binary_v3_decode", 20000, func() -> void: _decode_envelope_or_fail(_v3_cached(512)))
	_bench("binary_v2_fresh_uuid", 400, func() -> void: _decode_fresh_frames())
	_bench("uuid_format_miss", 1000, func() -> void: _uuid_misses())
	_bench("text_control_decode", 20000, func() -> void: SFEventsScript.decode_text(_control_text))
	_bench("text_game_decode", 20000, func() -> void: SFEventsScript.decode_text(_game_text))
	_bench(
		"json_guard_control", 20000, func() -> void: SFJsonGuard.duplicate_key_error(_control_text)
	)
	_bench(
		"json_guard_object_dense",
		2,
		func() -> void: SFJsonGuard.duplicate_key_error(_object_dense_text)
	)
	_bench("utf8_copy_control", 20000, func() -> void: _control_text.to_utf8_buffer())
	# encode_floats measures the memo steady state (issue #161: repeated game
	# floats hit the float wire-text memo); encode_floats_cold is an upper
	# bound of the uncached cost that shape measured before the memo existed
	# (miss path plus memo maintenance).
	_bench("encode_floats", 10000, func() -> void: _encode_floats())
	_bench("encode_floats_cold", 5000, func() -> void: _encode_floats_cold())
	_bench("msgpack_roundtrip", 20000, func() -> void: _msgpack_roundtrip())
	quit(0)


func _bench(label: String, iterations: int, operation: Callable) -> void:
	for _warmup: int in 3:
		_timed(iterations, operation)
	var samples: Array[float] = []
	for _run: int in _RUNS:
		samples.append(_timed(iterations, operation))
	samples.sort()
	var best_us := samples[0]
	print("%s %d %.3f" % [label, iterations, best_us / float(iterations)])


static func _tiny_objects() -> PackedStringArray:
	var objects := PackedStringArray()
	objects.resize(31200)
	for index: int in objects.size():
		objects[index] = '{"a":%d}' % (index & 0x0F)
	return objects


func _timed(iterations: int, operation: Callable) -> int:
	var start := Time.get_ticks_usec()
	for _index: int in iterations:
		operation.call()
	return Time.get_ticks_usec() - start


func _decode_envelope_or_fail(frame: PackedByteArray) -> void:
	var decoded: Dictionary = SFBinaryFramesScript.decode_envelope(frame)
	if not decoded["ok"]:
		push_error("bench frame failed to decode: %s" % decoded["error"])
		quit(1)


## Builds a v2 envelope: string keys from_player/encoding/payload with a
## 16-byte bin UUID, [code]"message_pack"[/code] encoding, and a
## [param payload_size] bin payload.
func _v2_frame(payload_size: int, salt: int) -> PackedByteArray:
	var frame := PackedByteArray()
	frame.append(0x83)
	frame.append(0xAB)
	frame.append_array("from_player".to_utf8_buffer())
	frame.append_array(_bin_field(_uuid_bytes(salt)))
	frame.append(0xA8)
	frame.append_array("encoding".to_utf8_buffer())
	frame.append(0xAC)
	frame.append_array("message_pack".to_utf8_buffer())
	frame.append(0xA7)
	frame.append_array("payload".to_utf8_buffer())
	frame.append_array(_bin_field(_payload_bytes(payload_size)))
	return frame


func _v3_frame(payload_size: int, salt: int) -> PackedByteArray:
	var frame := PackedByteArray()
	frame.append(0x85)
	frame.append(0xAB)
	frame.append_array("from_player".to_utf8_buffer())
	frame.append_array(_bin_field(_uuid_bytes(salt)))
	frame.append(0xA8)
	frame.append_array("encoding".to_utf8_buffer())
	frame.append(0xA4)
	frame.append_array("json".to_utf8_buffer())
	frame.append(0xA7)
	frame.append_array("payload".to_utf8_buffer())
	frame.append_array(_bin_field(_payload_bytes(payload_size)))
	frame.append(0xA3)
	frame.append_array("seq".to_utf8_buffer())
	frame.append(0x01)
	frame.append(0xA5)
	frame.append_array("epoch".to_utf8_buffer())
	frame.append(0x01)
	return frame


func _bin_field(bytes: PackedByteArray) -> PackedByteArray:
	var field := PackedByteArray()
	var size := bytes.size()
	field.append(0xC5 if size > 0xFF else 0xC4)
	if size > 0xFF:
		field.append((size >> 8) & 0xFF)
	field.append(size & 0xFF)
	field.append_array(bytes)
	return field


func _payload_bytes(payload_size: int) -> PackedByteArray:
	var payload := PackedByteArray()
	for index: int in payload_size:
		payload.append(index & 0xFF)
	return payload


func _uuid_bytes(salt: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	for index: int in 16:
		bytes.append((salt * 31 + index * 7) & 0xFF)
	return bytes


func _v2_cached(payload_size: int) -> PackedByteArray:
	var key := "v2_%d" % payload_size
	if not _frame_cache.has(key):
		_frame_cache[key] = _v2_frame(payload_size, 0)
	return _frame_cache[key]


func _v3_cached(payload_size: int) -> PackedByteArray:
	var key := "v3_%d" % payload_size
	if not _frame_cache.has(key):
		_frame_cache[key] = _v3_frame(payload_size, 0)
	return _frame_cache[key]


## Decodes 64 prebuilt frames with a cleared UUID cache, so every decode
## pays one cache miss plus the hex/substr formatting.
func _decode_fresh_frames() -> void:
	SFBinaryFramesScript._uuid_cache.clear()
	if _fresh_frames.is_empty():
		for salt: int in 64:
			_fresh_frames.append(_v2_frame(64, salt + 1))
	for frame: PackedByteArray in _fresh_frames:
		_decode_envelope_or_fail(frame)


func _uuid_misses() -> void:
	SFBinaryFramesScript._uuid_cache.clear()
	if _miss_uuids.is_empty():
		for index: int in 64:
			var bytes := PackedByteArray()
			for offset: int in 16:
				bytes.append((index * 13 + offset * 37 + 1) & 0xFF)
			_miss_uuids.append(bytes)
	for bytes: PackedByteArray in _miss_uuids:
		SFBinaryFramesScript._uuid_string(bytes)


func _float_envelope_cached() -> Dictionary:
	if _float_envelope_data.is_empty():
		var data := {}
		for index: int in 16:
			data["value_%d" % index] = index * 1.5 - 3.25
		var sender := "10000000-0000-0000-0000-000000000001"
		_float_envelope_data = {
			"type": "GameData",
			"data": {"from_player": sender, "data": data},
		}
	return _float_envelope_data


func _encode_floats() -> void:
	var wire := SFEnvelopeScript.encode(_float_envelope_cached())
	if wire.is_empty():
		push_error("bench float envelope refused at encode")
		quit(1)


func _encode_floats_cold() -> void:
	SFEnvelopeScript._float_memo.clear()
	var wire := SFEnvelopeScript.encode(_float_envelope_cached())
	if wire.is_empty():
		push_error("bench float envelope refused at encode")
		quit(1)


func _msgpack_roundtrip() -> void:
	var encoded: Dictionary = SFMsgpackScript.encode(_msgpack_payload)
	if not encoded["ok"]:
		push_error("bench msgpack encode failed")
		quit(1)
	var encoded_bytes: PackedByteArray = encoded["bytes"]
	var decoded: Dictionary = SFMsgpackScript.decode(encoded_bytes)
	if not decoded["ok"]:
		push_error("bench msgpack decode failed")
		quit(1)
