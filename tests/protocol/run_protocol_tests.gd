extends SceneTree

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

const CLIENT_FIXTURE := "res://tests/fixtures/v2_client_messages.jsonl"
const SERVER_FIXTURE := "res://tests/fixtures/v2_server_messages.jsonl"
const MALFORMED_FIXTURE := "res://tests/fixtures/malformed.jsonl"

var _failures: Array = []


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("protocol fixture tests passed")
		quit(0)
	else:
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _run() -> void:
	_test_client_encoders_match_fixtures()
	_test_server_decoders_match_fixtures()
	_test_malformed_inputs_decode_to_protocol_error()
	_test_binary_codec_accepts_base64_payload()
	_test_upstream_optional_fields_decode()
	_test_strict_protocol_validation()
	_test_error_code_table()


func _test_client_encoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(CLIENT_FIXTURE)
	_assert_equal(11, lines.size(), "client fixture count")
	var built := [
		SFMessagesScript.authenticate("mb_app_fixture", "0.1.0-godot", "godot", "json"),
		SFMessagesScript.join_room("reef-rally", "Alice", "ABC123", 4, true, "websocket"),
		SFMessagesScript.leave_room(),
		SFMessagesScript.game_data({"action": "move", "x": 10, "y": 20, "buttons": ["jump"]}),
		SFMessagesScript.authority_request(true),
		SFMessagesScript.player_ready(),
		SFMessagesScript.provide_connection_info(
			{"type": "direct", "host": "127.0.0.1", "port": 7777}
		),
		SFMessagesScript.ping(),
		SFMessagesScript.reconnect(
			"10000000-0000-0000-0000-000000000001",
			"20000000-0000-0000-0000-000000000001",
			"test-reconnect-token-not-secret"
		),
		SFMessagesScript.join_as_spectator("reef-rally", "ABC123", "Observer"),
		SFMessagesScript.leave_spectator(),
	]
	for index: int in lines.size():
		var encoded := SFEnvelopeScript.encode(built[index])
		_assert_equal(lines[index], encoded, "client fixture %d" % index)


func _test_server_decoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(SERVER_FIXTURE)
	_assert_equal(24, lines.size(), "server fixture count")
	var expected_signals := [
		"authenticated",
		"protocol_info",
		"authentication_error",
		"room_joined",
		"room_join_failed",
		"room_left",
		"player_joined",
		"player_left",
		"game_data_received",
		"game_data_binary_received",
		"authority_changed",
		"authority_response",
		"lobby_state_changed",
		"game_starting",
		"pong",
		"reconnected",
		"reconnection_failed",
		"player_reconnected",
		"spectator_joined",
		"spectator_join_failed",
		"spectator_left",
		"new_spectator_joined",
		"spectator_disconnected",
		"server_error",
	]
	for index: int in lines.size():
		var decoded := SFEventsScript.decode_text(lines[index])
		_assert_equal(
			expected_signals[index], String(decoded.signal_name), "server fixture signal %d" % index
		)
		_assert(decoded.args.size() >= 0, "server fixture args reachable %d" % index)

	var authenticated := SFEventsScript.decode_text(lines[0])
	_assert_equal("Reef Rally", authenticated.args[0], "authenticated app_name")
	_assert_equal("Ambiguous Interactive", authenticated.args[1], "authenticated organization")
	_assert_equal(60, authenticated.args[2].per_minute, "authenticated rate limit type")
	_assert_equal(3600, authenticated.args[2].per_hour, "authenticated hourly rate")
	_assert_equal(86400, authenticated.args[2].per_day, "authenticated daily rate")

	var protocol_info := SFEventsScript.decode_text(lines[1])
	_assert_equal("godot", protocol_info.args[0].platform, "protocol_info platform")
	_assert_equal("0.1.0-godot", protocol_info.args[0].sdk_version, "protocol_info sdk")
	_assert_equal("0.1.0", protocol_info.args[0].minimum_version, "protocol_info minimum")
	_assert_equal("0.1.0", protocol_info.args[0].recommended_version, "protocol_info recommended")
	_assert_equal(
		PackedStringArray(["authority", "reconnection", "spectators"]),
		protocol_info.args[0].capabilities,
		"protocol_info capabilities"
	)
	_assert_equal("fixture protocol info", protocol_info.args[0].notes, "protocol_info notes")
	_assert_equal(
		[
			SFTypesScript.GameDataEncoding.JSON,
			SFTypesScript.GameDataEncoding.MESSAGE_PACK,
			SFTypesScript.GameDataEncoding.RKYV
		],
		protocol_info.args[0].game_data_formats,
		"protocol_info game data formats"
	)
	_assert_equal(32, protocol_info.args[0].player_name_rules.max_length, "name max")
	_assert_equal(1, protocol_info.args[0].player_name_rules.min_length, "name min")
	_assert_equal(true, protocol_info.args[0].player_name_rules.allow_spaces, "name spaces")
	_assert_equal(
		PackedStringArray(["_", "-"]),
		protocol_info.args[0].player_name_rules.allowed_symbols,
		"name symbols"
	)

	var authentication_error := SFEventsScript.decode_text(lines[2])
	_assert_equal("invalid app id", authentication_error.args[0], "auth error message")
	_assert_equal(
		SFErrorCodesScript.Code.INVALID_APP_ID, authentication_error.args[1], "auth error code"
	)

	var room_joined := SFEventsScript.decode_text(lines[3])
	_assert_equal(
		"20000000-0000-0000-0000-000000000001", room_joined.args[0].room_id, "room_joined room id"
	)
	_assert_equal("ABC123", room_joined.args[0].room_code, "room_joined payload type")
	_assert_equal(
		"10000000-0000-0000-0000-000000000001",
		room_joined.args[0].player_id,
		"room_joined player id"
	)
	_assert_equal("reef-rally", room_joined.args[0].game_name, "room_joined game")
	_assert_equal(4, room_joined.args[0].max_players, "room_joined max players")
	_assert_equal(true, room_joined.args[0].supports_authority, "room_joined authority support")
	_assert_equal(true, room_joined.args[0].is_authority, "room_joined is authority")
	_assert_equal(
		SFTypesScript.LobbyState.WAITING, room_joined.args[0].lobby_state, "room_joined lobby state"
	)
	_assert_equal(PackedStringArray(), room_joined.args[0].ready_players, "room ready players")
	_assert_equal("websocket", room_joined.args[0].relay_type, "room relay type")
	_assert_equal(1, room_joined.args[0].current_players.size(), "room_joined players")
	_assert_equal("Alice", room_joined.args[0].current_players[0].name, "room player name")
	_assert_equal(true, room_joined.args[0].current_players[0].is_authority, "room player auth")
	_assert_equal(
		"direct", room_joined.args[0].current_players[0].connection_info.type, "room conn type"
	)
	_assert_equal(7777, room_joined.args[0].current_players[0].connection_info.port, "room port")
	_assert_equal(1, room_joined.args[0].current_spectators.size(), "room spectators")
	_assert_equal("Observer", room_joined.args[0].current_spectators[0].name, "room spectator")

	var room_join_failed := SFEventsScript.decode_text(lines[4])
	_assert_equal("room is full", room_join_failed.args[0], "room join failed reason")
	_assert_equal(SFErrorCodesScript.Code.ROOM_FULL, room_join_failed.args[1], "room full code")

	var room_left := SFEventsScript.decode_text(lines[5])
	_assert_equal(0, room_left.args.size(), "room left args")

	var player_joined := SFEventsScript.decode_text(lines[6])
	_assert_equal("10000000-0000-0000-0000-000000000002", player_joined.args[0].id, "pj id")
	_assert_equal("Bob", player_joined.args[0].name, "pj name")
	_assert_equal(false, player_joined.args[0].is_authority, "pj authority")
	_assert_equal(false, player_joined.args[0].is_ready, "pj ready")
	_assert_equal("webrtc", player_joined.args[0].connection_info.type, "pj connection")
	_assert_equal("fixture-sdp", player_joined.args[0].connection_info.sdp, "pj sdp")
	_assert_equal(
		PackedStringArray(["candidate:fixture"]),
		player_joined.args[0].connection_info.ice_candidates,
		"pj ice"
	)

	var player_left := SFEventsScript.decode_text(lines[7])
	_assert_equal("10000000-0000-0000-0000-000000000002", player_left.args[0], "left id")

	var game_data := SFEventsScript.decode_text(lines[8])
	_assert_equal("10000000-0000-0000-0000-000000000002", game_data.args[0], "game data from")
	_assert_equal("move", game_data.args[1]["action"], "game data action")
	_assert_equal(30, game_data.args[1]["x"], "game data x")
	_assert_equal(40, game_data.args[1]["y"], "game data y")

	var binary := SFEventsScript.decode_text(lines[9])
	_assert_equal("10000000-0000-0000-0000-000000000002", binary.args[0], "binary from")
	_assert_equal(SFTypesScript.GameDataEncoding.MESSAGE_PACK, binary.args[1], "binary encoding")
	_assert_equal(PackedByteArray([202, 254]), binary.args[2], "binary payload bytes")

	var authority_changed := SFEventsScript.decode_text(lines[10])
	_assert_equal("", authority_changed.args[0], "authority changed player")
	_assert_equal(false, authority_changed.args[1], "authority changed self")

	var authority_response := SFEventsScript.decode_text(lines[11])
	_assert_equal(false, authority_response.args[0], "authority response granted")
	_assert_equal("authority conflict", authority_response.args[1], "authority response reason")
	_assert_equal(
		SFErrorCodesScript.Code.AUTHORITY_CONFLICT,
		authority_response.args[2],
		"authority response code"
	)
	var authority_response_null_reason := SFEventsScript.decode_text(
		'{"type":"AuthorityResponse","data":{"granted":true,"reason":null}}'
	)
	_assert_equal(
		"authority_response",
		String(authority_response_null_reason.signal_name),
		"authority response null reason"
	)
	_assert_equal("", authority_response_null_reason.args[1], "authority response null reason arg")
	_assert_equal(SFErrorCodesScript.Code.NONE, authority_response_null_reason.args[2], "auth none")

	var lobby_state_changed := SFEventsScript.decode_text(lines[12])
	_assert_equal(
		SFTypesScript.LobbyState.LOBBY, lobby_state_changed.args[0], "lobby changed state"
	)
	_assert_equal(
		PackedStringArray(["10000000-0000-0000-0000-000000000001"]),
		lobby_state_changed.args[1],
		"lobby ready players"
	)
	_assert_equal(false, lobby_state_changed.args[2], "lobby all ready")

	var game_starting := SFEventsScript.decode_text(lines[13])
	_assert_equal(2, game_starting.args[0].size(), "game starting peers")
	_assert_equal(
		"10000000-0000-0000-0000-000000000001",
		game_starting.args[0][0].player_id,
		"game starting p1"
	)
	_assert_equal("Alice", game_starting.args[0][0].player_name, "game starting p1 name")
	_assert_equal(true, game_starting.args[0][0].is_authority, "game starting p1 authority")
	_assert_equal("websocket", game_starting.args[0][0].relay_type, "game starting relay")
	_assert_equal("direct", game_starting.args[0][0].connection_info.type, "game starting conn")
	_assert_equal("custom", game_starting.args[0][1].connection_info.type, "game starting custom")
	_assert_equal(
		{"transport": "fixture"}, game_starting.args[0][1].connection_info.data, "custom data"
	)

	var pong := SFEventsScript.decode_text(lines[14])
	_assert_equal(0, pong.args.size(), "pong args")

	var reconnected := SFEventsScript.decode_text(lines[15])
	_assert_equal("ABC123", reconnected.args[0].room_code, "reconnected room payload type")
	_assert_equal(SFTypesScript.LobbyState.FINALIZED, reconnected.args[0].lobby_state, "re state")
	_assert_equal(
		PackedStringArray(["10000000-0000-0000-0000-000000000001"]),
		reconnected.args[0].ready_players,
		"re ready players"
	)
	_assert_equal(2, reconnected.args[1].size(), "reconnected missed event count")
	_assert_equal("pong", String(reconnected.args[1][0].signal_name), "reconnected missed pong")
	_assert_equal("player_left", String(reconnected.args[1][1].signal_name), "re missed left")

	var reconnection_failed := SFEventsScript.decode_text(lines[16])
	_assert_equal("token expired", reconnection_failed.args[0], "reconnection failed reason")
	_assert_equal(
		SFErrorCodesScript.Code.RECONNECTION_EXPIRED,
		reconnection_failed.args[1],
		"reconnection failed code"
	)

	var player_reconnected := SFEventsScript.decode_text(lines[17])
	_assert_equal(
		"10000000-0000-0000-0000-000000000002", player_reconnected.args[0], "player reconnected id"
	)

	var spectator_joined := SFEventsScript.decode_text(lines[18])
	_assert_equal("ABC123", spectator_joined.args[0].room_code, "spectator joined room")
	_assert_equal(
		"30000000-0000-0000-0000-000000000001",
		spectator_joined.args[0].spectator_id,
		"spectator joined id"
	)
	_assert_equal(1, spectator_joined.args[0].current_players.size(), "spectator joined players")
	_assert_equal("Alice", spectator_joined.args[0].current_players[0].name, "spectator player")
	_assert_equal(
		1, spectator_joined.args[0].current_spectators.size(), "spectator joined spectators"
	)
	_assert_equal(
		SFTypesScript.LobbyState.WAITING, spectator_joined.args[0].lobby_state, "spectator lobby"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.JOINED, spectator_joined.args[0].reason, "spectator reason"
	)

	var spectator_join_failed := SFEventsScript.decode_text(lines[19])
	_assert_equal("spectator mode disabled", spectator_join_failed.args[0], "spectator fail reason")
	_assert_equal(
		SFErrorCodesScript.Code.SPECTATOR_NOT_ALLOWED,
		spectator_join_failed.args[1],
		"spectator fail code"
	)

	var spectator_left := SFEventsScript.decode_text(lines[20])
	_assert_equal("20000000-0000-0000-0000-000000000001", spectator_left.args[0], "sl room")
	_assert_equal("ABC123", spectator_left.args[1], "sl code")
	_assert_equal(
		SFTypesScript.SpectatorReason.VOLUNTARY_LEAVE, spectator_left.args[2], "sl reason"
	)
	_assert_equal(0, spectator_left.args[3].size(), "sl current spectators")

	var new_spectator := SFEventsScript.decode_text(lines[21])
	_assert_equal("30000000-0000-0000-0000-000000000002", new_spectator.args[0].id, "ns id")
	_assert_equal("Watcher", new_spectator.args[0].name, "ns name")
	_assert_equal(1, new_spectator.args[1].size(), "ns current spectators")
	_assert_equal(SFTypesScript.SpectatorReason.JOINED, new_spectator.args[2], "ns reason")

	var spectator_disconnected := SFEventsScript.decode_text(lines[22])
	_assert_equal("30000000-0000-0000-0000-000000000002", spectator_disconnected.args[0], "sd id")
	_assert_equal(
		SFTypesScript.SpectatorReason.DISCONNECTED, spectator_disconnected.args[1], "sd reason"
	)
	_assert_equal(0, spectator_disconnected.args[2].size(), "sd current spectators")

	var server_error := SFEventsScript.decode_text(lines[23])
	_assert_equal("message too large", server_error.args[0], "server error message")
	_assert_equal(
		SFErrorCodesScript.Code.MESSAGE_TOO_LARGE, server_error.args[1], "server error code"
	)


func _test_malformed_inputs_decode_to_protocol_error() -> void:
	var lines := _read_fixture_lines(MALFORMED_FIXTURE)
	_assert_equal(8, lines.size(), "malformed fixture count")
	for index: int in lines.size():
		var decoded := SFEventsScript.decode_text(lines[index])
		_assert_equal(
			"protocol_error", String(decoded.signal_name), "malformed fixture signal %d" % index
		)
		_assert_equal(1, decoded.args.size(), "malformed fixture args %d" % index)
		_assert(
			typeof(decoded.args[0]) == TYPE_STRING and not String(decoded.args[0]).is_empty(),
			"malformed fixture message %d" % index
		)
	var inline_cases := [
		'{"type":"GameStarting"}',
		'{"type":"PlayerJoined","data":{"player":{"id":"p1","name":"Alice"}}}',
		(
			'{"type":"LobbyStateChanged","data":{"lobby_state":"unknown",'
			+ '"ready_players":[],"all_ready":false}}'
		),
		(
			'{"type":"GameStarting","data":{"peer_connections":[{"player_id":"p1",'
			+ '"player_name":"Alice","is_authority":false,"relay_type":"websocket",'
			+ '"connection_info":"not-an-object"}]}}'
		),
		(
			'{"type":"PlayerJoined","data":{"player":{"id":"p1","name":"Alice",'
			+ '"is_authority":false,"is_ready":false,"connected_at":"now",'
			+ '"connection_info":{"type":"direct","port":7777}}}}'
		),
	]
	for index: int in inline_cases.size():
		var decoded := SFEventsScript.decode_text(inline_cases[index])
		_assert_equal(
			"protocol_error", String(decoded.signal_name), "inline malformed signal %d" % index
		)
		_assert_equal(1, decoded.args.size(), "inline malformed args %d" % index)


func _test_binary_codec_accepts_base64_payload() -> void:
	var line := (
		'{"type":"GameDataBinary","data":{"from_player":"p1",'
		+ '"encoding":"message_pack","payload":"yv4="}}'
	)
	var decoded := SFEventsScript.decode_text(line)
	_assert_equal("game_data_binary_received", String(decoded.signal_name), "base64 binary event")
	_assert_equal(PackedByteArray([202, 254]), decoded.args[2], "base64 binary payload")


func _test_upstream_optional_fields_decode() -> void:
	var protocol_info := SFEventsScript.decode_text('{"type":"ProtocolInfo","data":{}}')
	_assert_equal("protocol_info", String(protocol_info.signal_name), "minimal protocol info")
	_assert_equal("", protocol_info.args[0].platform, "minimal protocol platform")
	_assert_equal([], protocol_info.args[0].game_data_formats, "minimal protocol formats")

	var null_player_name_rules := SFEventsScript.decode_text(
		'{"type":"ProtocolInfo","data":{"player_name_rules":null}}'
	)
	_assert_equal(
		"protocol_info",
		String(null_player_name_rules.signal_name),
		"null player name rules optional"
	)
	_assert_equal(null, null_player_name_rules.args[0].player_name_rules, "null name rules")

	var defaulted_player_name_rules := SFEventsScript.decode_text(
		(
			'{"type":"ProtocolInfo","data":{"player_name_rules":{'
			+ '"max_length":32,"min_length":1,"allow_unicode_alphanumeric":true,'
			+ '"allow_spaces":true,"allow_leading_trailing_whitespace":false,'
			+ '"additional_allowed_characters":null}}}'
		)
	)
	_assert_equal(
		"protocol_info",
		String(defaulted_player_name_rules.signal_name),
		"defaulted player name rules"
	)
	_assert_equal(
		PackedStringArray(),
		defaulted_player_name_rules.args[0].player_name_rules.allowed_symbols,
		"defaulted allowed symbols"
	)
	_assert_equal(
		"",
		defaulted_player_name_rules.args[0].player_name_rules.additional_allowed_characters,
		"defaulted additional characters"
	)

	var game_starting := SFEventsScript.decode_text(
		(
			'{"type":"GameStarting","data":{"peer_connections":[{'
			+ '"player_id":"p1","player_name":"Alice","is_authority":false,'
			+ '"relay_type":"regional-relay"}]}}'
		)
	)
	_assert_equal("game_starting", String(game_starting.signal_name), "optional peer connection")
	_assert_equal(1, game_starting.args[0].size(), "optional peer count")
	_assert_equal(null, game_starting.args[0][0].connection_info, "peer connection info optional")
	_assert_equal("regional-relay", game_starting.args[0][0].relay_type, "peer relay label")

	var relay_without_transport := SFEventsScript.decode_text(
		(
			'{"type":"GameStarting","data":{"peer_connections":[{'
			+ '"player_id":"p1","player_name":"Alice","is_authority":false,'
			+ '"relay_type":"regional-relay","connection_info":{"type":"relay",'
			+ '"host":"relay.example.test","port":9000,"allocation_id":"alloc",'
			+ '"token":"relay-token"}}]}}'
		)
	)
	_assert_equal(
		"game_starting", String(relay_without_transport.signal_name), "relay transport defaulted"
	)
	_assert_equal(
		SFTypesScript.RelayTransport.UNKNOWN,
		relay_without_transport.args[0][0].connection_info.transport,
		"defaulted relay transport"
	)
	var relay_null_transport := SFEventsScript.decode_text(
		(
			'{"type":"GameStarting","data":{"peer_connections":[{'
			+ '"player_id":"p1","player_name":"Alice","is_authority":false,'
			+ '"relay_type":"regional-relay","connection_info":{"type":"relay",'
			+ '"host":"relay.example.test","port":9000,"transport":null,'
			+ '"allocation_id":"alloc","token":"relay-token"}}]}}'
		)
	)
	_assert_equal("game_starting", String(relay_null_transport.signal_name), "relay null transport")

	var webrtc_null_sdp := SFEventsScript.decode_text(
		(
			'{"type":"PlayerJoined","data":{"player":{"id":"p1","name":"Alice",'
			+ '"is_authority":false,"is_ready":false,"connected_at":"now",'
			+ '"connection_info":{"type":"webrtc","sdp":null,"ice_candidates":[]}}}}'
		)
	)
	_assert_equal("player_joined", String(webrtc_null_sdp.signal_name), "webrtc null sdp")
	_assert_equal("", webrtc_null_sdp.args[0].connection_info.sdp, "webrtc null sdp value")

	var spectator_left := SFEventsScript.decode_text('{"type":"SpectatorLeft"}')
	_assert_equal("spectator_left", String(spectator_left.signal_name), "minimal spectator left")
	_assert_equal("", spectator_left.args[0], "minimal spectator left room")
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, spectator_left.args[2], "minimal reason")
	_assert_equal(0, spectator_left.args[3].size(), "minimal spectator list")

	var new_spectator := SFEventsScript.decode_text(
		(
			'{"type":"NewSpectatorJoined","data":{"spectator":{'
			+ '"id":"s1","name":"Watcher","connected_at":"now"}}}'
		)
	)
	_assert_equal(
		"new_spectator_joined", String(new_spectator.signal_name), "minimal new spectator"
	)
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, new_spectator.args[2], "new reason")

	var disconnected := SFEventsScript.decode_text(
		'{"type":"SpectatorDisconnected","data":{"spectator_id":"s1"}}'
	)
	_assert_equal(
		"spectator_disconnected", String(disconnected.signal_name), "minimal spectator disconnected"
	)
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, disconnected.args[1], "disconnect reason")


func _test_strict_protocol_validation() -> void:
	var required_unknown_error_code := SFEventsScript.decode_text(
		(
			'{"type":"AuthenticationError","data":{"error":"bad app",'
			+ '"error_code":"NOT_A_REAL_CODE"}}'
		)
	)
	_assert_equal(
		"protocol_error",
		String(required_unknown_error_code.signal_name),
		"required unknown error code"
	)

	var optional_unknown_error_code := SFEventsScript.decode_text(
		'{"type":"RoomJoinFailed","data":{"reason":"bad room",' + '"error_code":"NOT_A_REAL_CODE"}}'
	)
	_assert_equal(
		"protocol_error",
		String(optional_unknown_error_code.signal_name),
		"optional unknown error code"
	)

	var optional_null_error_code := SFEventsScript.decode_text(
		'{"type":"RoomJoinFailed","data":{"reason":"bad room","error_code":null}}'
	)
	_assert_equal(
		"room_join_failed", String(optional_null_error_code.signal_name), "optional null error code"
	)
	_assert_equal(SFErrorCodesScript.Code.NONE, optional_null_error_code.args[1], "null code")

	var invalid_numeric_cases := [
		[
			(
				'{"type":"RoomJoined","data":{"room_id":"r1","room_code":"ABC123",'
				+ '"player_id":"p1","game_name":"game","max_players":4.5,'
				+ '"supports_authority":false,"current_players":[],"is_authority":false,'
				+ '"lobby_state":"waiting","ready_players":[],"relay_type":"websocket"}}'
			),
			"float max_players"
		],
		[
			(
				'{"type":"Authenticated","data":{"app_name":"game","rate_limits":{'
				+ '"per_minute":-1,"per_hour":0,"per_day":0}}}'
			),
			"negative rate limit"
		],
		[
			(
				'{"type":"PlayerJoined","data":{"player":{"id":"p1","name":"Alice",'
				+ '"is_authority":false,"is_ready":false,"connected_at":"now",'
				+ '"connection_info":{"type":"direct","host":"127.0.0.1",'
				+ '"port":65536}}}}'
			),
			"port above u16"
		],
		[
			(
				'{"type":"PlayerJoined","data":{"player":{"id":"p1","name":"Alice",'
				+ '"is_authority":false,"is_ready":false,"connected_at":"now",'
				+ '"connection_info":{"type":"relay","host":"relay.example.test",'
				+ '"port":9000,"allocation_id":"alloc","token":"relay-token",'
				+ '"client_id":1.5}}}}'
			),
			"float client id"
		],
	]
	for invalid_case: Array in invalid_numeric_cases:
		var decoded := SFEventsScript.decode_text(invalid_case[0])
		_assert_equal("protocol_error", String(decoded.signal_name), invalid_case[1])


func _test_error_code_table() -> void:
	_assert_equal(
		SFErrorCodesScript.Code.INVALID_APP_ID,
		SFErrorCodesScript.from_string("INVALID_APP_ID"),
		"invalid app id code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.ROOM_FULL,
		SFErrorCodesScript.from_string("ROOM_FULL"),
		"room full code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.NONE, SFErrorCodesScript.from_string(null), "absent optional code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		SFErrorCodesScript.from_string("NOT_A_REAL_CODE"),
		"unknown code"
	)
	_assert_equal(
		"reconnection",
		SFErrorCodesScript.category(SFErrorCodesScript.Code.RECONNECTION_EXPIRED),
		"reconnection category"
	)


func _read_fixture_lines(path: String) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append(
			"failed to open %s: %s" % [path, error_string(FileAccess.get_open_error())]
		)
		return PackedStringArray()
	var lines := PackedStringArray()
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		lines.append(line)
	return lines


func _assert(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)
