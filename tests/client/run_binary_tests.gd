extends SceneTree

# P2 binary game-data suite (PLAN §4.6).

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")

const PLAYER_B := ClientFixtures.PLAYER_B

var _failures: Array = []
# Completion sentinel: a runtime abort inside _run() would otherwise leave
# the process hanging until CI kills it.
var _run_completed := false


func _init() -> void:
	_run()
	if not _run_completed:
		push_error("binary client tests aborted before completion")
		quit(1)
		return
	if _failures.is_empty():
		print("binary client tests passed")
		quit(0)
	else:
		push_error("binary client tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	_test_send_guards_and_wire_bytes()
	_test_envelope_receive_paths()
	_test_rkyv_pass_through()
	_test_server_format_downgrade()
	_run_completed = true


func _test_send_guards_and_wire_bytes() -> void:
	# json negotiation refuses binary sends locally (upstream drops them
	# server-side); parameters validated first.
	var json_client := _make_in_room_client_with(_make_config())
	var json_errors := _track_protocol_errors(json_client)
	_assert_equal(
		ERR_INVALID_PARAMETER,
		json_client.send_game_data_binary(PackedByteArray()),
		"empty binary send refused"
	)
	_assert_equal(
		ERR_UNAVAILABLE,
		json_client.send_game_data_binary(PackedByteArray([0x01])),
		"binary send refused under json negotiation"
	)
	var refusal_message: String = json_errors[json_errors.size() - 1]
	_assert_string_contains(refusal_message, "message_pack or rkyv", "refusal message")
	json_client.free()

	var config := _make_config()
	config.game_data_format = "message_pack"
	var client := _make_in_room_client_with(config)
	var errors := _track_protocol_errors(client)
	var client_transport: SFFakeTransportScript = client.transport
	var payload := PackedByteArray([0x81, 0xA1, 0x68, 0x2A])
	_assert_equal(OK, client.send_game_data_binary(payload), "binary send under message_pack")
	_assert_equal([payload], client.transport.sent_binary, "binary send bytes hit the wire")
	client.transport.buffered_amount = config.max_buffered_bytes + 1
	_assert_equal(
		ERR_BUSY, client.send_game_data_binary(payload), "binary send honors backpressure"
	)
	_assert_equal(1, client_transport.sent_binary.size(), "backpressure drops binary")
	var backpressure_error: String = errors[0]
	_assert_string_contains(backpressure_error, "backpressure", "binary backpressure message")
	client.transport.buffered_amount = 0
	client.free()


func _test_envelope_receive_paths() -> void:
	var config := _make_config()
	config.game_data_format = "message_pack"
	var client := _make_in_room_client_with(config)
	var client_transport: SFFakeTransportScript = client.transport
	var events: Array = []
	client.game_data_received.connect(
		func(from_player: String, data: Variant) -> void: events.append(["data", from_player, data])
	)
	client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			events.append(["binary", from_player, encoding, payload])
	)
	var errors := _track_protocol_errors(client)
	var payload := PackedByteArray([0x81, 0xA1, 0x68, 0x2A])

	client_transport.inject_binary(_binary_frame(PLAYER_B, "message_pack", payload))
	_assert_equal(
		[["binary", PLAYER_B, SFTypesScript.GameDataEncoding.MESSAGE_PACK, payload]],
		events,
		"envelope surfaces as bytes by default"
	)
	client_transport.inject_binary(
		_binary_frame(PLAYER_B, "message_pack", payload) + PackedByteArray([0x00])
	)
	_assert_equal(1, errors.size(), "hostile envelope emits protocol_error")
	_assert_equal(1, events.size(), "hostile envelope surfaces nothing")
	_assert(client.is_connected_to_server(), true, "hostile envelope keeps the link up")
	client.free()

	var decode_config := _make_config()
	decode_config.game_data_format = "message_pack"
	decode_config.decode_msgpack_payloads = true
	var decode_client := _make_in_room_client_with(decode_config)
	var decode_transport: SFFakeTransportScript = decode_client.transport
	var decode_events: Array = []
	decode_client.game_data_received.connect(
		func(from_player: String, data: Variant) -> void:
			decode_events.append(["data", from_player, data])
	)
	decode_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			decode_events.append(["binary", from_player, encoding, payload])
	)
	var decode_errors := _track_protocol_errors(decode_client)
	decode_transport.inject_binary(_binary_frame(PLAYER_B, "message_pack", payload))
	_assert_equal(
		[["data", PLAYER_B, {"h": 42}]], decode_events, "opt-in decode emits the decoded value"
	)
	decode_transport.inject_binary(
		_binary_frame(PLAYER_B, "message_pack", PackedByteArray([0xC7, 0x01, 0x00, 0x2A]))
	)
	_assert_equal(1, decode_errors.size(), "bad payload emits protocol_error")
	_assert_equal(
		[
			["data", PLAYER_B, {"h": 42}],
			[
				"binary",
				PLAYER_B,
				SFTypesScript.GameDataEncoding.MESSAGE_PACK,
				PackedByteArray([0xC7, 0x01, 0x00, 0x2A])
			],
		],
		decode_events,
		"bad payload falls back to raw bytes"
	)
	decode_client.free()


func _test_rkyv_pass_through() -> void:
	# rkyv surfaces raw pass-through frames with no sender identity: upstream
	# sends no envelope for rkyv.
	var rkyv_config := _make_config()
	rkyv_config.game_data_format = "rkyv"
	var rkyv_client := _make_in_room_client_with(rkyv_config)
	var rkyv_transport: SFFakeTransportScript = rkyv_client.transport
	var rkyv_events: Array = []
	rkyv_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			rkyv_events.append(["binary", from_player, encoding, payload])
	)
	rkyv_transport.inject_binary(PackedByteArray([0xDE, 0xAD]))
	_assert_equal(
		[["binary", "", SFTypesScript.GameDataEncoding.RKYV, PackedByteArray([0xDE, 0xAD])]],
		rkyv_events,
		"rkyv frame passes through raw"
	)
	rkyv_client.free()


func _test_server_format_downgrade() -> void:
	# A downgrade (format absent from ProtocolInfo, or UnsupportedGameDataFormat
	# error) pins negotiation to json, matching what the server would do anyway.
	var downgrade_config := _make_config()
	downgrade_config.game_data_format = "message_pack"
	var downgrade_client := _make_in_room_client_with(downgrade_config)
	var downgrade_transport: SFFakeTransportScript = downgrade_client.transport
	var downgrade_events: Array = []
	downgrade_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			downgrade_events.append(["binary", from_player, encoding, payload])
	)
	var downgrade_server_errors: Array = []
	downgrade_client.server_error.connect(
		func(message: String, error_code: int) -> void:
			downgrade_server_errors.append([message, error_code])
	)
	var unsupported_info := _protocol_info()
	unsupported_info["game_data_formats"] = ["json"]
	downgrade_transport.inject_server_message({"type": "ProtocolInfo", "data": unsupported_info})
	_assert_equal(
		ERR_UNAVAILABLE,
		downgrade_client.send_game_data_binary(PackedByteArray([0x01])),
		"downgraded format refuses binary sends"
	)
	downgrade_transport.inject_binary(
		_binary_frame(PLAYER_B, "message_pack", PackedByteArray([0x01]))
	)
	_assert_equal(0, downgrade_events.size(), "downgraded format drops binary frames")
	(
		downgrade_transport
		. inject_server_message(
			{
				"type": "Error",
				"data": {"message": "unsupported", "error_code": "UNSUPPORTED_GAME_DATA_FORMAT"},
			}
		)
	)
	_assert_equal(
		[["unsupported", SFErrorCodesScript.Code.UNSUPPORTED_GAME_DATA_FORMAT]],
		downgrade_server_errors,
		"unsupported-format error surfaces"
	)
	downgrade_client.free()

	var error_downgraded := _make_in_room_client_with(downgrade_config)
	var error_downgraded_transport: SFFakeTransportScript = error_downgraded.transport
	(
		error_downgraded_transport
		. inject_server_message(
			{
				"type": "Error",
				"data": {"message": "unsupported", "error_code": "UNSUPPORTED_GAME_DATA_FORMAT"},
			}
		)
	)
	_assert_equal(
		ERR_UNAVAILABLE,
		error_downgraded.send_game_data_binary(PackedByteArray([0x01])),
		"error-event downgrade refuses binary sends"
	)
	error_downgraded.free()

	var redialed := SignalFishClientScript.new()
	_track_protocol_errors(redialed)
	_assert_equal(OK, redialed.configure(downgrade_config), "reconfigure for redial")
	redialed.transport = SFFakeTransportScript.new()
	var redialed_transport: SFFakeTransportScript = redialed.transport
	_assert_equal(OK, redialed.connect_to_server("ws://example.test/socket"), "redial")
	redialed_transport.inject_open()
	redialed_transport.inject_server_message(
		{"type": "Authenticated", "data": _authenticated_data()}
	)
	redialed_transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(
		OK, redialed.send_game_data_binary(PackedByteArray([0x01])), "downgrade resets on dial"
	)
	redialed.free()

	# Late binary frames while CLOSING are ignored like text events: only the
	# close frame is polled in that window.
	var closing := _make_in_room_client_with(downgrade_config)
	var closing_transport: SFFakeTransportScript = closing.transport
	var closing_events: Array = []
	closing.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			closing_events.append(["binary", from_player, encoding, payload])
	)
	var closing_errors := _track_protocol_errors(closing)
	closing._connection_state = SignalFishClientScript.ConnectionState.CLOSING
	closing_transport.inject_binary(
		_binary_frame(PLAYER_B, "message_pack", PackedByteArray([0x01]))
	)
	_assert_equal(0, closing_events.size(), "late binary frame surfaces nothing")
	_assert_equal(0, closing_errors.size(), "late binary frame emits no error")
	closing.free()


func _make_config() -> SignalFishConfigScript:
	var config := SignalFishConfigScript.new()
	config.app_id = "test-app"
	config.sdk_version = "0.1.0"
	config.platform = "linux"
	config.game_data_format = "json"
	return config


func _make_in_room_client_with(config: SignalFishConfigScript) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	_assert_equal(OK, client.configure(config), "configure")
	client.transport = SFFakeTransportScript.new()
	var transport: SFFakeTransportScript = client.transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	transport.inject_open()
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	return client


func _authenticated_data() -> Dictionary:
	return ClientFixtures.authenticated_data()


func _room_joined_data() -> Dictionary:
	# This suite joins a fresh room before any peers or spectators arrive.
	var overrides := {
		"current_players": [],
		"is_authority": false,
		"current_spectators": [],
	}
	return ClientFixtures.room_joined_data(overrides)


func _protocol_info() -> Dictionary:
	return ClientFixtures.protocol_info()


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	var errors: Array = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	return errors


## Builds the canonical v2 binary game-data envelope (msgpack map with the
## 16-byte binary UUID, encoding token, and binary payload).
func _binary_frame(
	from_player: String, encoding: String, payload: PackedByteArray
) -> PackedByteArray:
	var encoded := SFMsgpackScript.encode(
		{"from_player": _uuid_bytes(from_player), "encoding": encoding, "payload": payload}
	)
	return encoded["bytes"]


func _uuid_bytes(uuid: String) -> PackedByteArray:
	var hex := uuid.replace("-", "")
	var bytes := PackedByteArray()
	bytes.resize(16)
	for index: int in 16:
		bytes[index] = ("0x" + hex.substr(index * 2, 2)).hex_to_int()
	return bytes


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


func _assert_string_contains(actual: String, expected_substring: String, label: String) -> bool:
	if actual.find(expected_substring) == -1:
		_failures.append(
			(
				"%s: expected %s to contain %s"
				% [label, var_to_str(actual), var_to_str(expected_substring)]
			)
		)
		return false
	return true
