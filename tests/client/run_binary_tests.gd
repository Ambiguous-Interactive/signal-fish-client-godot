extends SceneTree

# P2 binary game-data suite (PLAN §4.6).

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_B := ClientFixtures.PLAYER_B

var _failures: Array[String] = []
var _test_done := false
# Completion sentinel: a runtime abort inside _run() would otherwise leave
# the process hanging until CI kills it.
var _run_completed := false


func _done() -> void:
	_test_done = true


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
	var cases: Array[Callable] = [
		_test_send_guards_and_wire_bytes,
		_test_envelope_receive_paths,
		_test_rkyv_pass_through,
		_test_opaque_format_negotiation,
		_test_server_format_downgrade,
	]
	CompletionGuard.self_check(self, _failures)
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)
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
	_assert_string_contains(
		refusal_message, "requires a binary game_data_format", "refusal message"
	)
	json_client.free()

	var config := _make_config()
	config.game_data_format = "message_pack"
	var client := _make_in_room_client_with(config)
	var errors := _track_protocol_errors(client)
	var client_transport: SFFakeTransportScript = client.transport
	var payload := PackedByteArray([0x81, 0xA1, 0x68, 0x2A])
	_assert_equal(OK, client.send_game_data_binary(payload), "binary send under message_pack")
	_assert_equal([payload], client_transport.sent_binary, "binary send bytes hit the wire")
	client_transport.buffered_amount = config.max_buffered_bytes + 1
	_assert_equal(
		ERR_BUSY, client.send_game_data_binary(payload), "binary send honors backpressure"
	)
	_assert_equal(1, client_transport.sent_binary.size(), "backpressure drops binary")
	var backpressure_error: String = errors[0]
	_assert_string_contains(backpressure_error, "backpressure", "binary backpressure message")
	client_transport.buffered_amount = 0
	client.free()
	_done()


func _test_envelope_receive_paths() -> void:
	var config := _make_config()
	config.game_data_format = "message_pack"
	var client := _make_in_room_client_with(config)
	var client_transport: SFFakeTransportScript = client.transport
	var events: Array[Array] = []
	client.game_data_received.connect(
		func(from_player: String, data: Variant) -> void: events.append(["data", from_player, data])
	)
	client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, body: PackedByteArray) -> void:
			events.append(["binary", from_player, encoding, body])
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
	var decode_events: Array[Array] = []
	decode_client.game_data_received.connect(
		func(from_player: String, data: Variant) -> void:
			decode_events.append(["data", from_player, data])
	)
	decode_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, body: PackedByteArray) -> void:
			decode_events.append(["binary", from_player, encoding, body])
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
	_done()


func _test_rkyv_pass_through() -> void:
	# Opaque envelope tokens (rkyv, server issue #627) decode as raw bytes
	# under message_pack negotiation: the token stays a valid v3 envelope
	# encoding, and the payload passes through untouched with the sender
	# identity attached. Data-driven over both opaque tokens.
	for case: Dictionary in [
		{"token": "rkyv", "encoding": SFTypesScript.GameDataEncoding.RKYV},
		{"token": "protobuf", "encoding": SFTypesScript.GameDataEncoding.PROTOBUF},
	]:
		var token: String = case["token"]
		var encoding: int = case["encoding"]
		var config := _make_config()
		config.game_data_format = "message_pack"
		var client := _make_in_room_client_with(config)
		var transport: SFFakeTransportScript = client.transport
		var events: Array[Array] = []
		client.game_data_binary_received.connect(
			func(from_player: String, frame_encoding: int, payload: PackedByteArray) -> void:
				events.append(["binary", from_player, frame_encoding, payload])
		)
		transport.inject_binary(_v3_binary_frame(PLAYER_B, token, PackedByteArray([0xDE, 0xAD])))
		_assert_equal(
			[["binary", PLAYER_B, encoding, PackedByteArray([0xDE, 0xAD])]],
			events,
			"%s envelope token passes through raw" % token
		)
		client.free()

	# Even with opt-in decode on, an opaque token is not MessagePack: the
	# decode branch is message_pack-only and the payload stays raw bytes.
	var decode_config := _make_config()
	decode_config.game_data_format = "message_pack"
	decode_config.decode_msgpack_payloads = true
	var decode_client := _make_in_room_client_with(decode_config)
	var decode_transport: SFFakeTransportScript = decode_client.transport
	var decode_events: Array[Array] = []
	decode_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			decode_events.append(["binary", from_player, encoding, payload])
	)
	decode_transport.inject_binary(
		_v3_binary_frame(PLAYER_B, "rkyv", PackedByteArray([0xDE, 0xAD]))
	)
	_assert_equal(
		[["binary", PLAYER_B, SFTypesScript.GameDataEncoding.RKYV, PackedByteArray([0xDE, 0xAD])]],
		decode_events,
		"rkyv envelope token stays raw with decode on"
	)
	decode_client.free()
	_done()


func _test_opaque_format_negotiation() -> void:
	# Opaque requests (rkyv/protobuf, server issue #627) negotiate like
	# message_pack when the deployment advertises them on v3, and fall back
	# to JSON otherwise. Data-driven over both tokens.
	for token: String in ["rkyv", "protobuf"]:
		# Advertised on v3: the request stands and binary flows both ways.
		var client := _make_in_room_client_with(_opaque_config(token))
		var transport: SFFakeTransportScript = client.transport
		var events: Array[Array] = []
		client.game_data_binary_received.connect(
			func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
				events.append(["binary", from_player, encoding, payload])
		)
		var advertised := _protocol_info()
		advertised["protocol_version"] = 3
		advertised["game_data_formats"] = ["json", "message_pack", token]
		transport.inject_server_message({"type": "ProtocolInfo", "data": advertised})
		_assert_equal(
			OK, client.send_game_data_binary(PackedByteArray([0x01])), "%s send on v3" % token
		)
		transport.inject_binary(_v3_binary_frame(PLAYER_B, token, PackedByteArray([0x02])))
		var expected: Array = [
			[
				"binary",
				PLAYER_B,
				SFTypesScript.game_data_encoding_from_string(token),
				PackedByteArray([0x02])
			],
		]
		_assert_equal(expected, events, "%s envelope delivers on v3" % token)
		client.free()

		# Advertised but negotiated v2: the opaque wire shape has no sender
		# attribution on v2 (issue #627), so the request downgrades to JSON.
		var v2_client := _make_in_room_client_with(_opaque_config(token))
		var v2_transport: SFFakeTransportScript = v2_client.transport
		var v2_events: Array[Array] = []
		v2_client.game_data_binary_received.connect(
			func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
				v2_events.append(["binary", from_player, encoding, payload])
		)
		var v2_info := _protocol_info()
		v2_info["game_data_formats"] = ["json", "message_pack", token]
		v2_transport.inject_server_message({"type": "ProtocolInfo", "data": v2_info})
		_assert_equal(
			ERR_UNAVAILABLE,
			v2_client.send_game_data_binary(PackedByteArray([0x01])),
			"%s request refuses on v2" % token
		)
		# The downgrade is receive-side too: the negotiated format is json, so
		# a v3-shaped frame drops instead of delivering (pins the event-path
		# downgrade, not just the send gate).
		v2_transport.inject_binary(_v3_binary_frame(PLAYER_B, token, PackedByteArray([0x03])))
		_assert_equal(0, v2_events.size(), "%s v2 downgrade drops binary frames" % token)
		v2_client.free()

	# The pinned pre-auth downgrade notice (server issue #742): the server
	# answers an opaque request with Error{UNSUPPORTED_GAME_DATA_FORMAT}
	# BEFORE Authenticated; the notice downgrades the session to JSON and the
	# handshake continues instead of failing a viable session.
	var notice_client := SignalFishClientScript.new()
	_track_protocol_errors(notice_client)
	_assert_equal(OK, notice_client.configure(_opaque_config("rkyv")), "configure for notice")
	notice_client.transport = SFFakeTransportScript.new()
	var notice_transport: SFFakeTransportScript = notice_client.transport
	_assert_equal(OK, notice_client.connect_to_server("ws://example.test/socket"), "dial")
	notice_transport.inject_open()
	(
		notice_transport
		. inject_server_message(
			{
				"type": "Error",
				"data": {"message": "unsupported", "error_code": "UNSUPPORTED_GAME_DATA_FORMAT"},
			}
		)
	)
	notice_transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	# The v3+advertised statement after the notice proves the JSON latch:
	# without the notice handler the rkyv request would stand and the send
	# below would succeed.
	var notice_info := _protocol_info()
	notice_info["protocol_version"] = 3
	notice_info["game_data_formats"] = ["json", "message_pack", "rkyv"]
	notice_transport.inject_server_message({"type": "ProtocolInfo", "data": notice_info})
	notice_transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(
		ERR_UNAVAILABLE,
		notice_client.send_game_data_binary(PackedByteArray([0x01])),
		"pre-auth notice downgrades to json"
	)
	notice_client.free()

	# A fresh dial must not honor the previous dial's negotiation: until the
	# new dial's ProtocolInfo arrives, the opaque version floor is unknown and
	# opaque sends refuse. This pins the per-dial reset in _open_transport;
	# configure()'s matching reset is symmetry hygiene (dial flows always
	# re-reset, so no dial-flow assertion can observe it).
	var redialed := SignalFishClientScript.new()
	_track_protocol_errors(redialed)
	_assert_equal(OK, redialed.configure(_opaque_config("rkyv")), "configure for redial")
	redialed.transport = SFFakeTransportScript.new()
	var redial_transport: SFFakeTransportScript = redialed.transport
	_assert_equal(OK, redialed.connect_to_server("ws://example.test/socket"), "redial")
	redial_transport.inject_open()
	redial_transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var v3_info := _protocol_info()
	v3_info["protocol_version"] = 3
	v3_info["game_data_formats"] = ["json", "message_pack", "rkyv"]
	redial_transport.inject_server_message({"type": "ProtocolInfo", "data": v3_info})
	redial_transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(OK, redialed.send_game_data_binary(PackedByteArray([0x01])), "v3 redial send")
	# Close like the transport-closed cascade does, then dial again on the
	# same client: the fresh dial must not inherit the previous negotiation.
	redialed._connection_state = SignalFishClientScript.ConnectionState.CLOSED
	redialed._reset_session()
	redialed._teardown_transport()
	redialed.transport = SFFakeTransportScript.new()
	redial_transport = redialed.transport
	_assert_equal(OK, redialed.connect_to_server("ws://example.test/socket"), "second dial")
	redial_transport.inject_open()
	redial_transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	redial_transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	var stale_errors := _track_protocol_errors(redialed)
	_assert_equal(
		ERR_UNAVAILABLE,
		redialed.send_game_data_binary(PackedByteArray([0x01])),
		"stale version refuses pre-ProtocolInfo"
	)
	_assert_string_contains(
		stale_errors[stale_errors.size() - 1], "no v3 negotiation seen", "stale version message"
	)
	# Promote dial two to v3, then reconfigure before dial three: dial three
	# exercises the configure()-plus-dial reset path end to end (the per-dial
	# reset alone is what the dial-two refusal above pins).
	redial_transport.inject_server_message({"type": "ProtocolInfo", "data": v3_info})
	_assert_equal(OK, redialed.send_game_data_binary(PackedByteArray([0x01])), "dial two v3 send")
	redialed._connection_state = SignalFishClientScript.ConnectionState.CLOSED
	redialed._reset_session()
	redialed._teardown_transport()
	redialed.transport = SFFakeTransportScript.new()
	redial_transport = redialed.transport
	_assert_equal(OK, redialed.configure(_opaque_config("rkyv")), "reconfigure for third dial")
	_assert_equal(OK, redialed.connect_to_server("ws://example.test/socket"), "third dial")
	redial_transport.inject_open()
	redial_transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	redial_transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(
		ERR_UNAVAILABLE,
		redialed.send_game_data_binary(PackedByteArray([0x01])),
		"reconfigured dial refuses pre-ProtocolInfo"
	)
	redialed.free()
	_done()


func _opaque_config(token: String) -> SignalFishConfigScript:
	var config := _make_config()
	config.game_data_format = token
	return config


func _test_server_format_downgrade() -> void:
	# A downgrade (format absent from ProtocolInfo, or UnsupportedGameDataFormat
	# error) pins negotiation to json, matching what the server would do anyway.
	var downgrade_config := _make_config()
	downgrade_config.game_data_format = "message_pack"
	var downgrade_client := _make_in_room_client_with(downgrade_config)
	var downgrade_transport: SFFakeTransportScript = downgrade_client.transport
	var downgrade_events: Array[Array] = []
	downgrade_client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			downgrade_events.append(["binary", from_player, encoding, payload])
	)
	var downgrade_server_errors: Array[Array] = []
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
	var closing_events: Array[Array] = []
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
	_done()


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


func _track_protocol_errors(client: SignalFishClientScript) -> Array[String]:
	var errors: Array[String] = []
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


## Builds the v3 binary game-data envelope: adds the mandatory non-zero
## seq/epoch stamps and unlocks the json/rkyv/protobuf encoding tokens.
func _v3_binary_frame(
	from_player: String, encoding: String, payload: PackedByteArray
) -> PackedByteArray:
	var encoded := (
		SFMsgpackScript
		. encode(
			{
				"from_player": _uuid_bytes(from_player),
				"encoding": encoding,
				"payload": payload,
				"seq": 1,
				"epoch": 1,
			}
		)
	)
	return encoded["bytes"]


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
