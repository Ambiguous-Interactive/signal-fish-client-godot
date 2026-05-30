extends RefCounted

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

var _failures: Array = []


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_client_message_validation()
	_test_connection_info_to_dict_resend_canonicalization()
	_test_inbound_strict_null_validation()
	_test_binary_codec_hardening()
	_test_forward_compatible_inbound_strings()
	_test_non_empty_wire_strings()
	_test_reconnected_missed_events_nonfatal()


func _test_client_message_validation() -> void:
	var join_integral_float := SFMessagesScript.join_room(
		"reef-rally", "Alice", null, 4.0, false, SFTypesScript.RelayTransport.WEBSOCKET
	)
	_assert_valid_message(join_integral_float, "join_room integral float")
	_assert_equal(4, join_integral_float["data"]["max_players"], "join_room max_players int")
	_assert_equal(false, join_integral_float["data"]["supports_authority"], "join_room bool")
	_assert_equal("websocket", join_integral_float["data"]["relay_transport"], "join_room enum int")

	var valid_messages := [
		{
			"label": "authenticate enum int",
			"envelope":
			SFMessagesScript.authenticate(
				"mb_app_fixture", null, null, SFTypesScript.GameDataEncoding.MESSAGE_PACK
			)
		},
		{
			"label": "provide direct connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 7777}
			)
		},
		{
			"label": "provide relay connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t"
				}
			)
		},
		{
			"label": "provide webrtc connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "webrtc", "sdp": "offer", "ice_candidates": ["candidate:1"]}
			)
		},
		{
			"label": "provide custom connection",
			"envelope":
			SFMessagesScript.provide_connection_info({"type": "custom", "data": {"x": 1}})
		},
		{
			"label": "provide custom null payload",
			"envelope": SFMessagesScript.provide_connection_info({"type": "custom", "data": null})
		},
	]
	for test_case: Dictionary in valid_messages:
		_assert_valid_message(test_case["envelope"], test_case["label"])

	var invalid_messages := [
		{
			"label": "join_room fractional max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 4.5),
			"error": "max_players"
		},
		{
			"label": "join_room zero max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 0),
			"error": "max_players"
		},
		{
			"label": "join_room high max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 256),
			"error": "max_players"
		},
		{
			"label": "join_room string bool",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, "false"),
			"error": "supports_authority"
		},
		{
			"label": "join_room relay typo",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, null, "TCP"),
			"error": "relay_transport"
		},
		{
			"label": "join_room empty relay",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, null, ""),
			"error": "relay_transport"
		},
		{
			"label": "authenticate format typo",
			"envelope": SFMessagesScript.authenticate("mb_app_fixture", null, null, "message-pack"),
			"error": "game_data_format"
		},
		{
			"label": "authenticate empty format",
			"envelope": SFMessagesScript.authenticate("mb_app_fixture", null, null, ""),
			"error": "game_data_format"
		},
		{
			"label": "provide direct missing host",
			"envelope": SFMessagesScript.provide_connection_info({"type": "direct", "port": 7777}),
			"error": "host"
		},
		{
			"label": "provide direct null host",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": null, "port": 7777}
			),
			"error": "host"
		},
		{
			"label": "provide direct high port",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 65536}
			),
			"error": "port"
		},
		{
			"label": "provide direct float port",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 7777.0}
			),
			"error": "port"
		},
		{
			"label": "provide relay transport typo",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"transport": "TCP"
				}
			),
			"error": "transport"
		},
		{
			"label": "provide relay null transport",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"transport": null
				}
			),
			"error": "transport"
		},
		{
			"label": "provide relay null required field",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": null,
					"token": "t"
				}
			),
			"error": "allocation_id"
		},
		{
			"label": "provide relay float client id",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"client_id": 1.0
				}
			),
			"error": "client_id"
		},
		{
			"label": "provide unknown type",
			"envelope": SFMessagesScript.provide_connection_info({"type": "future"}),
			"error": "type"
		},
		{
			"label": "provide webrtc missing ice",
			"envelope":
			SFMessagesScript.provide_connection_info({"type": "webrtc", "sdp": "offer"}),
			"error": "ice_candidates"
		},
		{
			"label": "provide webrtc null ice",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "webrtc", "sdp": "offer", "ice_candidates": null}
			),
			"error": "ice_candidates"
		},
		{
			"label": "provide custom missing data",
			"envelope": SFMessagesScript.provide_connection_info({"type": "custom"}),
			"error": "data"
		},
	]
	for test_case: Dictionary in invalid_messages:
		_assert_invalid_message(test_case["envelope"], test_case["error"], test_case["label"])
	_assert_equal(
		"", SFEnvelopeScript.encode(invalid_messages[0]["envelope"]), "invalid encode guard"
	)


func _test_connection_info_to_dict_resend_canonicalization() -> void:
	var direct_info := SFTypesScript.ConnectionInfo.new(
		{"type": "direct", "host": "127.0.0.1", "port": 7777.0}
	)
	var direct_dict := direct_info.to_dict()
	_assert_equal(TYPE_INT, typeof(direct_dict["port"]), "direct to_dict port type")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(direct_dict), "resend direct to_dict"
	)

	var direct_extra_fields_info := SFTypesScript.ConnectionInfo.new(
		{
			"type": "direct",
			"host": "127.0.0.1",
			"port": 7777.0,
			"token": "wrong-variant",
			"transport": "tcp"
		}
	)
	var direct_extra_fields_dict := direct_extra_fields_info.to_dict()
	_assert(not direct_extra_fields_dict.has("transport"), "direct transport metadata omitted")
	_assert(not direct_extra_fields_dict.has("token"), "direct cross-variant token omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(direct_extra_fields_dict),
		"resend direct extra fields to_dict"
	)

	var relay_raw := _relay_connection_info({"port": 9000.0, "transport": null, "client_id": null})
	var relay_info := SFTypesScript.ConnectionInfo.new(relay_raw)
	var relay_dict := relay_info.to_dict()
	_assert_equal(-1, relay_info.client_id, "relay null client_id stays absent")
	_assert_equal(TYPE_INT, typeof(relay_dict["port"]), "relay to_dict port type")
	_assert_equal("auto", relay_dict["transport"], "relay null transport to auto")
	_assert(not relay_dict.has("client_id"), "relay null client_id omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(relay_dict), "resend relay to_dict"
	)

	var future_transport_info := SFTypesScript.ConnectionInfo.new(
		_relay_connection_info({"transport": "future_transport"})
	)
	var future_transport_dict := future_transport_info.to_dict()
	_assert(not future_transport_dict.has("transport"), "future relay transport omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(future_transport_dict),
		"resend future relay transport to_dict"
	)

	var webrtc_info := SFTypesScript.ConnectionInfo.new(
		{"type": "webrtc", "sdp": null, "ice_candidates": ["candidate:1"]}
	)
	var webrtc_dict := webrtc_info.to_dict()
	_assert(not webrtc_dict.has("sdp"), "webrtc null sdp omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(webrtc_dict), "resend webrtc to_dict"
	)

	var player_info := SFTypesScript.PlayerInfo.new(
		_with_overrides(_minimal_player_data(), {"connection_info": relay_raw})
	)
	var player_dict := player_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(player_dict["connection_info"]["port"]),
		"player to_dict connection port type"
	)
	_assert_equal(
		"auto", player_dict["connection_info"]["transport"], "player to_dict connection transport"
	)

	var peer_info := SFTypesScript.PeerConnectionInfo.new(
		_peer_connection({"connection_info": relay_raw})
	)
	var peer_dict := peer_info.to_dict()
	_assert_equal(
		TYPE_INT, typeof(peer_dict["connection_info"]["port"]), "peer to_dict connection port type"
	)
	_assert_equal(
		"auto", peer_dict["connection_info"]["transport"], "peer to_dict connection transport"
	)

	var nested_player := _minimal_player_data()
	nested_player["connection_info"] = relay_raw
	var room_info := SFTypesScript.RoomJoinedInfo.new(
		_with_overrides(_minimal_room_joined_data(), {"current_players": [nested_player]})
	)
	var room_dict := room_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(room_dict["current_players"][0]["connection_info"]["port"]),
		"room to_dict connection port type"
	)

	var spectator_joined_info := SFTypesScript.SpectatorJoinedInfo.new(
		_with_overrides(_minimal_spectator_joined_data(), {"current_players": [nested_player]})
	)
	var spectator_joined_dict := spectator_joined_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(spectator_joined_dict["current_players"][0]["connection_info"]["port"]),
		"spectator joined to_dict connection port type"
	)


func _test_inbound_strict_null_validation() -> void:
	var custom_null_player := _minimal_player_data()
	custom_null_player["connection_info"] = {"type": "custom", "data": null}
	var invalid_envelopes := [
		{
			"label": "ProtocolInfo null allowed symbols",
			"envelope":
			{
				"type": "ProtocolInfo",
				"data":
				{
					"player_name_rules":
					{
						"max_length": 32,
						"min_length": 1,
						"allow_unicode_alphanumeric": true,
						"allow_spaces": true,
						"allow_leading_trailing_whitespace": false,
						"allowed_symbols": null
					}
				}
			}
		},
	]
	for test_case: Dictionary in invalid_envelopes:
		_assert_protocol_error_envelope(test_case["envelope"], test_case["label"])

	var pong_null_data := SFEventsScript.decode_envelope({"type": "Pong", "data": null})
	_assert_equal("pong", String(pong_null_data.signal_name), "pong null data")

	var player_custom_null := SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": custom_null_player}}
	)
	_assert_equal("player_joined", String(player_custom_null.signal_name), "custom null player")
	_assert_equal(null, player_custom_null.args[0].connection_info.data, "custom null player data")

	var peer_custom_null := SFEventsScript.decode_envelope(
		_game_starting_envelope(
			[_peer_connection({"connection_info": {"type": "custom", "data": null}})]
		)
	)
	_assert_equal("game_starting", String(peer_custom_null.signal_name), "custom null peer")
	_assert_equal(null, peer_custom_null.args[0][0].connection_info.data, "custom null peer data")

	var null_connection_player := _minimal_player_data()
	null_connection_player["connection_info"] = null
	var player_null_connection := SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": null_connection_player}}
	)
	_assert_equal(
		"player_joined", String(player_null_connection.signal_name), "player null connection"
	)
	_assert_equal(null, player_null_connection.args[0].connection_info, "null player connection")


func _test_binary_codec_hardening() -> void:
	var unpadded := SFEventsScript.decode_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": "yv4"}
		}
	)
	_assert_equal(
		"game_data_binary_received", String(unpadded.signal_name), "unpadded base64 binary event"
	)
	_assert_equal(PackedByteArray([202, 254]), unpadded.args[2], "unpadded base64 payload")

	var future_encoding := SFEventsScript.decode_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "future_pack", "payload": "yv4"}
		}
	)
	_assert_equal(
		"game_data_binary_received",
		String(future_encoding.signal_name),
		"unknown binary encoding is forward-compatible"
	)
	_assert_equal(
		SFTypesScript.GameDataEncoding.UNKNOWN,
		future_encoding.args[1],
		"unknown binary encoding value"
	)
	_assert_equal(PackedByteArray([202, 254]), future_encoding.args[2], "future encoding payload")

	var invalid_padding := _assert_protocol_error_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": "yv=4"}
		},
		"invalid base64 padding"
	)
	_assert_protocol_error_contains(invalid_padding, "base64", "invalid base64 diagnostics")


func _test_forward_compatible_inbound_strings() -> void:
	var future_protocol_info := SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"game_data_formats": ["json", "future_pack"]}}
	)
	_assert_equal(
		"protocol_info",
		String(future_protocol_info.signal_name),
		"future protocol game data format"
	)
	_assert_equal(
		[SFTypesScript.GameDataEncoding.JSON, SFTypesScript.GameDataEncoding.UNKNOWN],
		future_protocol_info.args[0].game_data_formats,
		"future protocol game data format value"
	)

	var relay_future_transport_data := _relay_connection_info({"transport": "future_transport"})
	var relay_future_transport := SFEventsScript.decode_envelope(
		_game_starting_envelope(
			[_peer_connection({"connection_info": relay_future_transport_data})]
		)
	)
	_assert_equal(
		"game_starting",
		String(relay_future_transport.signal_name),
		"future relay transport accepted inbound"
	)
	_assert_equal(
		SFTypesScript.RelayTransport.UNKNOWN,
		relay_future_transport.args[0][0].connection_info.transport,
		"future relay transport value"
	)

	var future_connection_type_player := _minimal_player_data()
	future_connection_type_player["connection_info"] = {
		"type": "future_transport", "data": {"x": 1}
	}
	var future_connection_type := SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": future_connection_type_player}}
	)
	_assert_equal(
		"player_joined",
		String(future_connection_type.signal_name),
		"future connection_info type accepted inbound"
	)
	_assert_equal(
		"future_transport",
		future_connection_type.args[0].connection_info.type,
		"future connection_info type value"
	)

	var spectator_joined_unknown_data := _minimal_spectator_joined_data()
	spectator_joined_unknown_data["reason"] = "future_reason"
	var spectator_joined_unknown_reason := SFEventsScript.decode_envelope(
		{"type": "SpectatorJoined", "data": spectator_joined_unknown_data}
	)
	_assert_equal(
		"spectator_joined",
		String(spectator_joined_unknown_reason.signal_name),
		"spectator joined unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_joined_unknown_reason.args[0].reason,
		"spectator joined unknown reason value"
	)

	var spectator_left_unknown_reason := SFEventsScript.decode_envelope(
		{"type": "SpectatorLeft", "data": {"reason": "future_reason"}}
	)
	_assert_equal(
		"spectator_left",
		String(spectator_left_unknown_reason.signal_name),
		"spectator left unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_left_unknown_reason.args[2],
		"spectator left unknown reason value"
	)

	var new_spectator_unknown_reason := SFEventsScript.decode_envelope(
		{
			"type": "NewSpectatorJoined",
			"data": {"spectator": _minimal_spectator_data(), "reason": "future_reason"}
		}
	)
	_assert_equal(
		"new_spectator_joined",
		String(new_spectator_unknown_reason.signal_name),
		"new spectator unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		new_spectator_unknown_reason.args[2],
		"new spectator unknown reason value"
	)

	var disconnected_unknown_reason := SFEventsScript.decode_envelope(
		{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": "future_reason"}}
	)
	_assert_equal(
		"spectator_disconnected",
		String(disconnected_unknown_reason.signal_name),
		"spectator disconnected unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		disconnected_unknown_reason.args[1],
		"spectator disconnected unknown reason value"
	)

	var null_game_data := SFEventsScript.decode_envelope(
		{"type": "GameData", "data": {"from_player": "p1", "data": null}}
	)
	_assert_equal("game_data_received", String(null_game_data.signal_name), "null game data")
	_assert_equal(null, null_game_data.args[1], "null game data value")


func _test_non_empty_wire_strings() -> void:
	_assert_protocol_error_envelope(
		{"type": "ProtocolInfo", "data": {"game_data_formats": [""]}},
		"empty protocol game data format"
	)
	_assert_protocol_error_envelope(
		{"type": "GameDataBinary", "data": {"from_player": "p1", "encoding": "", "payload": "yv4"}},
		"empty binary encoding"
	)

	var empty_type_player := _minimal_player_data()
	empty_type_player["connection_info"] = {"type": "", "data": {"x": 1}}
	_assert_protocol_error_envelope(
		{"type": "PlayerJoined", "data": {"player": empty_type_player}},
		"empty connection_info type"
	)

	var empty_transport := _relay_connection_info({"transport": ""})
	_assert_protocol_error_envelope(
		_game_starting_envelope([_peer_connection({"connection_info": empty_transport})]),
		"empty relay transport"
	)

	var required_error_code_cases := [
		{
			"label": "auth empty error code",
			"envelope":
			{"type": "AuthenticationError", "data": {"error": "bad app", "error_code": ""}}
		},
		{
			"label": "reconnection empty error code",
			"envelope":
			{"type": "ReconnectionFailed", "data": {"reason": "bad token", "error_code": ""}}
		},
	]
	for test_case: Dictionary in required_error_code_cases:
		_assert_protocol_error_envelope(test_case["envelope"], test_case["label"])

	var optional_error_code_cases := [
		{
			"label": "room join empty error code",
			"envelope": {"type": "RoomJoinFailed", "data": {"reason": "bad room", "error_code": ""}}
		},
		{
			"label": "authority empty error code",
			"envelope": {"type": "AuthorityResponse", "data": {"granted": false, "error_code": ""}}
		},
		{
			"label": "spectator join empty error code",
			"envelope":
			{"type": "SpectatorJoinFailed", "data": {"reason": "bad spectator", "error_code": ""}}
		},
		{
			"label": "server error empty error code",
			"envelope": {"type": "Error", "data": {"message": "bad", "error_code": ""}}
		},
	]
	for test_case: Dictionary in optional_error_code_cases:
		_assert_protocol_error_envelope(test_case["envelope"], test_case["label"])

	var spectator_joined_data := _minimal_spectator_joined_data()
	spectator_joined_data["reason"] = ""
	var spectator_reason_cases := [
		{
			"label": "spectator joined empty reason",
			"envelope": {"type": "SpectatorJoined", "data": spectator_joined_data}
		},
		{
			"label": "spectator left empty reason",
			"envelope": {"type": "SpectatorLeft", "data": {"reason": ""}}
		},
		{
			"label": "new spectator empty reason",
			"envelope":
			{
				"type": "NewSpectatorJoined",
				"data": {"spectator": _minimal_spectator_data(), "reason": ""}
			}
		},
		{
			"label": "spectator disconnected empty reason",
			"envelope":
			{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": ""}}
		},
	]
	for test_case: Dictionary in spectator_reason_cases:
		_assert_protocol_error_envelope(test_case["envelope"], test_case["label"])


func _test_reconnected_missed_events_nonfatal() -> void:
	var future_missed_event_data := _minimal_room_joined_data()
	future_missed_event_data["missed_events"] = [
		{"type": "FutureEvent", "data": {"value": 1}},
		{"type": "Pong"},
		12,
	]
	var future_missed_event := SFEventsScript.decode_envelope(
		{"type": "Reconnected", "data": future_missed_event_data}
	)
	_assert_equal(
		"reconnected", String(future_missed_event.signal_name), "future missed event reconnect"
	)
	_assert_equal(3, future_missed_event.args[1].size(), "future missed event count")
	_assert_equal(
		"protocol_error",
		String(future_missed_event.args[1][0].signal_name),
		"future missed event entry"
	)
	_assert_equal("pong", String(future_missed_event.args[1][1].signal_name), "known missed event")
	_assert_protocol_error_contains(
		future_missed_event.args[1][2], "missed_events[2]", "non-object missed event"
	)


func _minimal_room_joined_data() -> Dictionary:
	return {
		"room_id": "r1",
		"room_code": "ABC123",
		"player_id": "p1",
		"game_name": "reef-rally",
		"max_players": 4,
		"supports_authority": false,
		"current_players": [],
		"is_authority": false,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket"
	}


func _minimal_player_data() -> Dictionary:
	return {
		"id": "p1", "name": "Alice", "is_authority": false, "is_ready": false, "connected_at": "now"
	}


func _minimal_spectator_joined_data() -> Dictionary:
	return {
		"room_id": "r1",
		"room_code": "ABC123",
		"spectator_id": "s1",
		"game_name": "reef-rally",
		"current_players": [],
		"current_spectators": [],
		"lobby_state": "waiting"
	}


func _minimal_spectator_data() -> Dictionary:
	return {"id": "s1", "name": "Watcher", "connected_at": "now"}


func _game_starting_envelope(peer_connections: Array) -> Dictionary:
	return {"type": "GameStarting", "data": {"peer_connections": peer_connections}}


func _peer_connection(overrides: Dictionary) -> Dictionary:
	return _with_overrides(
		{
			"player_id": "p1",
			"player_name": "Alice",
			"is_authority": false,
			"relay_type": "regional-relay"
		},
		overrides
	)


func _relay_connection_info(overrides: Dictionary) -> Dictionary:
	var data := {"type": "relay", "host": "relay.example.test", "port": 9000}
	data["allocation_id"] = "alloc"
	data["token"] = "relay-token"
	return _with_overrides(data, overrides)


func _with_overrides(data: Dictionary, overrides: Dictionary) -> Dictionary:
	for key: Variant in overrides:
		data[key] = overrides[key]
	return data


func _assert_valid_message(envelope: Dictionary, label: String) -> bool:
	if not _assert(not SFEnvelopeScript.is_invalid_message(envelope), "%s should be valid" % label):
		return false
	return _assert(not SFEnvelopeScript.encode(envelope).is_empty(), "%s should encode" % label)


func _assert_invalid_message(
	envelope: Dictionary, expected_error_substring: String, label: String
) -> bool:
	if not _assert(SFEnvelopeScript.is_invalid_message(envelope), "%s should be invalid" % label):
		return false
	if not _assert_equal(SFEnvelopeScript.INVALID_MESSAGE_TYPE, envelope.get("type"), label):
		return false
	return _assert_string_contains(
		SFEnvelopeScript.invalid_message_error(envelope), expected_error_substring, label
	)


func _assert_protocol_error_envelope(envelope: Dictionary, label: String) -> RefCounted:
	var decoded := SFEventsScript.decode_envelope(envelope)
	_assert_protocol_error(decoded, "%s envelope=%s" % [label, var_to_str(envelope)])
	return decoded


func _assert_protocol_error(decoded: RefCounted, label: String) -> bool:
	if not _assert_equal("protocol_error", String(decoded.signal_name), label):
		return false
	if not _assert_equal(1, decoded.args.size(), "%s protocol_error args" % label):
		return false
	return _assert(
		typeof(decoded.args[0]) == TYPE_STRING and not String(decoded.args[0]).is_empty(),
		"%s protocol_error message must be non-empty" % label
	)


func _assert_protocol_error_contains(
	decoded: RefCounted, expected_substring: String, label: String
) -> bool:
	if not _assert_protocol_error(decoded, label):
		return false
	return _assert_string_contains(String(decoded.args[0]), expected_substring, label)


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append(label)
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
