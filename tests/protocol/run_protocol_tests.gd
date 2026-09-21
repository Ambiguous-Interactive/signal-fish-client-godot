extends SceneTree

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const ProtocolHardeningTestsScript = preload("res://tests/protocol/protocol_hardening_tests.gd")
const BinaryFrameTestsScript = preload("res://tests/protocol/binary_frame_tests.gd")
const V3ProtocolTestsScript = preload("res://tests/protocol/v3_protocol_tests.gd")
const UpstreamSamplesTestsScript = preload("res://tests/protocol/upstream_samples_tests.gd")

const CLIENT_FIXTURE := "res://tests/fixtures/v2_client_messages.jsonl"
const SERVER_FIXTURE := "res://tests/fixtures/v2_server_messages.jsonl"
const MALFORMED_FIXTURE := "res://tests/fixtures/malformed.jsonl"

var _failures: Array = []
# Completion sentinel: an abort inside _run() skips quit() and would
# otherwise hang CI instead of reporting a red result.
var _run_completed := false


func _init() -> void:
	_run()
	if not _run_completed:
		push_error("protocol fixture tests aborted before completion")
		quit(1)
		return
	if _failures.is_empty():
		print("protocol fixture tests passed")
		quit(0)
	else:
		push_error("protocol fixture tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


## A helper suite that fails to compile preloads as a GDScript object with no
## members; calling it would abort _run() mid-way and the (empty) failure list
## would report a false pass. Verify every helper suite is loadable up front.
func _helper_suites_are_loadable() -> bool:
	var suites := [
		["protocol_hardening_tests", ProtocolHardeningTestsScript],
		["binary_frame_tests", BinaryFrameTestsScript],
		["v3_protocol_tests", V3ProtocolTestsScript],
		["upstream_samples_tests", UpstreamSamplesTestsScript],
	]
	var loadable := true
	for suite: Array in suites:
		var suite_script: Script = suite[1]
		if not suite_script.has_method("run"):
			push_error("helper suite failed to load: %s" % suite[0])
			loadable = false
	return loadable


func _run() -> void:
	if not _helper_suites_are_loadable():
		_failures.append("helper suites failed to load")
		return
	_test_client_encoders_match_fixtures()
	_test_server_decoders_match_fixtures()
	_test_malformed_inputs_decode_to_protocol_error()
	_test_binary_codec_accepts_base64_payload()
	_test_upstream_optional_fields_decode()
	_test_allowed_symbols_widen_parity()
	_test_strict_protocol_validation()
	_test_protocol_error_diagnostics()
	_test_error_code_table()
	_failures.append_array(ProtocolHardeningTestsScript.run())
	_failures.append_array(BinaryFrameTestsScript.run())
	_failures.append_array(V3ProtocolTestsScript.run())
	_failures.append_array(UpstreamSamplesTestsScript.run())
	_run_completed = true


func _test_allowed_symbols_widen_parity() -> void:
	# Issue #12: upstream widened allowed_symbols to multi-char strings; both
	# one-char and multi-char wire shapes must coerce verbatim.
	var shapes := [
		["legacy one-char symbols", ["_", "-"]],
		["widened multi-char symbols", ["_-", "SEP"]],
	]
	for shape: Array in shapes:
		var envelope := {
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
					"allowed_symbols": shape[1],
				}
			}
		}
		var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(envelope)
		if not _assert_equal("protocol_info", String(event.signal_name), "%s: decodes" % shape[0]):
			continue
		var expected_symbols: PackedStringArray = shape[1]
		_assert_equal(
			expected_symbols,
			event.args[0].player_name_rules.allowed_symbols,
			"%s: preserved verbatim" % shape[0]
		)
		_assert_equal(
			"",
			SFTypesScript.validate_player_name_rules(envelope["data"]["player_name_rules"]),
			"%s: validates" % shape[0]
		)


func _test_client_encoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(CLIENT_FIXTURE)
	if not _assert_fixture_count(12, lines, CLIENT_FIXTURE):
		return
	var built := [
		SFMessagesScript.authenticate("mb_app_fixture", "0.1.0-godot", "godot", "json"),
		SFMessagesScript.join_room(
			"reef-rally", "Alice", "ABC123", 4, true, "websocket", "hunter2-not-secret"
		),
		SFMessagesScript.leave_room(),
		SFMessagesScript.game_data({"action": "move", "x": 10, "y": 20, "buttons": ["jump"]}),
		SFMessagesScript.authority_request(true),
		SFMessagesScript.player_ready(),
		SFMessagesScript.start_game(),
		SFMessagesScript.provide_connection_info(
			{"type": "direct", "host": "127.0.0.1", "port": 7777}
		),
		SFMessagesScript.ping(),
		SFMessagesScript.reconnect(
			"10000000-0000-0000-0000-000000000001",
			"20000000-0000-0000-0000-000000000001",
			"test-reconnect-token-not-secret"
		),
		SFMessagesScript.join_as_spectator(
			"reef-rally", "ABC123", "Observer", "hunter2-not-secret"
		),
		SFMessagesScript.leave_spectator(),
	]
	if not _assert_equal(lines.size(), built.size(), "client fixture builder count"):
		return
	for index: int in lines.size():
		var message: Dictionary = built[index]
		var encoded := SFEnvelopeScript.encode(message)
		_assert_equal(lines[index], encoded, "%s line %d" % [CLIENT_FIXTURE, index + 1])


func _test_server_decoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(SERVER_FIXTURE)
	if not _assert_fixture_count(24, lines, SERVER_FIXTURE):
		return
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
	var expected_arg_counts := [
		3, 1, 2, 1, 2, 0, 1, 1, 2, 3, 2, 3, 3, 1, 0, 2, 2, 1, 1, 2, 4, 3, 3, 2
	]
	if not _assert_equal(lines.size(), expected_signals.size(), "server expected signal count"):
		return
	if not _assert_equal(lines.size(), expected_arg_counts.size(), "server expected arg count"):
		return
	var decoded_events: Array = []
	var failures_before_fixture_shape_checks := _failures.size()
	for index: int in lines.size():
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(lines[index])
		decoded_events.append(decoded)
		var expected_signal: String = expected_signals[index]
		if not _assert_decoded_signal(
			expected_signal, decoded, "%s line %d" % [SERVER_FIXTURE, index + 1]
		):
			continue
		_assert_equal(
			expected_arg_counts[index],
			decoded.args.size(),
			"%s line %d arg count" % [SERVER_FIXTURE, index + 1]
		)
	if _failures.size() != failures_before_fixture_shape_checks:
		return

	var authenticated: SFTypesScript.DecodedEvent = decoded_events[0]
	_assert_equal("Reef Rally", authenticated.args[0], "authenticated app_name")
	_assert_equal("Ambiguous Interactive", authenticated.args[1], "authenticated organization")
	_assert_equal(60, authenticated.args[2].per_minute, "authenticated rate limit type")
	_assert_equal(3600, authenticated.args[2].per_hour, "authenticated hourly rate")
	_assert_equal(86400, authenticated.args[2].per_day, "authenticated daily rate")

	var protocol_info: SFTypesScript.DecodedEvent = decoded_events[1]
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

	var authentication_error: SFTypesScript.DecodedEvent = decoded_events[2]
	_assert_equal("invalid app id", authentication_error.args[0], "auth error message")
	_assert_equal(
		SFErrorCodesScript.Code.INVALID_APP_ID, authentication_error.args[1], "auth error code"
	)

	var room_joined: SFTypesScript.DecodedEvent = decoded_events[3]
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
	_assert_equal(
		"test-reconnect-token-not-secret",
		room_joined.args[0].reconnection_token,
		"room join issues the reconnection token"
	)
	var room_joined_players: Array = room_joined.args[0].current_players
	_assert_equal(1, room_joined_players.size(), "room_joined players")
	_assert_equal("Alice", room_joined.args[0].current_players[0].name, "room player name")
	_assert_equal(true, room_joined.args[0].current_players[0].is_authority, "room player auth")
	_assert_equal(
		"direct", room_joined.args[0].current_players[0].connection_info.type, "room conn type"
	)
	_assert_equal(7777, room_joined.args[0].current_players[0].connection_info.port, "room port")
	var room_joined_spectators: Array = room_joined.args[0].current_spectators
	_assert_equal(1, room_joined_spectators.size(), "room spectators")
	_assert_equal("Observer", room_joined.args[0].current_spectators[0].name, "room spectator")

	var room_join_failed: SFTypesScript.DecodedEvent = decoded_events[4]
	_assert_equal("room is full", room_join_failed.args[0], "room join failed reason")
	_assert_equal(SFErrorCodesScript.Code.ROOM_FULL, room_join_failed.args[1], "room full code")

	var room_left: SFTypesScript.DecodedEvent = decoded_events[5]
	_assert_equal(0, room_left.args.size(), "room left args")

	var player_joined: SFTypesScript.DecodedEvent = decoded_events[6]
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

	var player_left: SFTypesScript.DecodedEvent = decoded_events[7]
	_assert_equal("10000000-0000-0000-0000-000000000002", player_left.args[0], "left id")

	var game_data: SFTypesScript.DecodedEvent = decoded_events[8]
	_assert_equal("10000000-0000-0000-0000-000000000002", game_data.args[0], "game data from")
	_assert_equal("move", game_data.args[1]["action"], "game data action")
	_assert_equal(30, game_data.args[1]["x"], "game data x")
	_assert_equal(40, game_data.args[1]["y"], "game data y")

	var binary: SFTypesScript.DecodedEvent = decoded_events[9]
	_assert_equal("10000000-0000-0000-0000-000000000002", binary.args[0], "binary from")
	_assert_equal(SFTypesScript.GameDataEncoding.MESSAGE_PACK, binary.args[1], "binary encoding")
	_assert_equal(PackedByteArray([202, 254]), binary.args[2], "binary payload bytes")

	var authority_changed: SFTypesScript.DecodedEvent = decoded_events[10]
	_assert_equal("", authority_changed.args[0], "authority changed player")
	_assert_equal(false, authority_changed.args[1], "authority changed self")

	var authority_response: SFTypesScript.DecodedEvent = decoded_events[11]
	_assert_equal(false, authority_response.args[0], "authority response granted")
	_assert_equal("authority conflict", authority_response.args[1], "authority response reason")
	_assert_equal(
		SFErrorCodesScript.Code.AUTHORITY_CONFLICT,
		authority_response.args[2],
		"authority response code"
	)
	var authority_response_null_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		'{"type":"AuthorityResponse","data":{"granted":true,"reason":null}}'
	)
	_assert_equal(
		"authority_response",
		String(authority_response_null_reason.signal_name),
		"authority response null reason"
	)
	_assert_equal("", authority_response_null_reason.args[1], "authority response null reason arg")
	_assert_equal(SFErrorCodesScript.Code.NONE, authority_response_null_reason.args[2], "auth none")

	var lobby_state_changed: SFTypesScript.DecodedEvent = decoded_events[12]
	_assert_equal(
		SFTypesScript.LobbyState.LOBBY, lobby_state_changed.args[0], "lobby changed state"
	)
	_assert_equal(
		PackedStringArray(["10000000-0000-0000-0000-000000000001"]),
		lobby_state_changed.args[1],
		"lobby ready players"
	)
	_assert_equal(false, lobby_state_changed.args[2], "lobby all ready")

	var game_starting: SFTypesScript.DecodedEvent = decoded_events[13]
	var game_starting_peers: Array = game_starting.args[0]
	_assert_equal(2, game_starting_peers.size(), "game starting peers")
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

	var pong: SFTypesScript.DecodedEvent = decoded_events[14]
	_assert_equal(0, pong.args.size(), "pong args")

	var reconnected: SFTypesScript.DecodedEvent = decoded_events[15]
	_assert_equal("ABC123", reconnected.args[0].room_code, "reconnected room payload type")
	_assert_equal(SFTypesScript.LobbyState.FINALIZED, reconnected.args[0].lobby_state, "re state")
	_assert_equal(
		PackedStringArray(["10000000-0000-0000-0000-000000000001"]),
		reconnected.args[0].ready_players,
		"re ready players"
	)
	var reconnected_missed_events: Array = reconnected.args[1]
	_assert_equal(2, reconnected_missed_events.size(), "reconnected missed event count")
	_assert_equal("pong", str(reconnected.args[1][0].signal_name), "reconnected missed pong")
	_assert_equal("player_left", str(reconnected.args[1][1].signal_name), "re missed left")
	_assert_equal(
		"test-reconnect-token-rotated-not-secret",
		reconnected.args[0].reconnection_token,
		"reconnect rotates the reconnection token"
	)
	var baseline_reconnection_token: String = room_joined.args[0].reconnection_token
	var rotated_reconnection_token: String = reconnected.args[0].reconnection_token
	_assert(
		baseline_reconnection_token != rotated_reconnection_token,
		"reconnection tokens rotate per baseline"
	)

	var reconnection_failed: SFTypesScript.DecodedEvent = decoded_events[16]
	_assert_equal("token expired", reconnection_failed.args[0], "reconnection failed reason")
	_assert_equal(
		SFErrorCodesScript.Code.RECONNECTION_EXPIRED,
		reconnection_failed.args[1],
		"reconnection failed code"
	)

	var player_reconnected: SFTypesScript.DecodedEvent = decoded_events[17]
	_assert_equal(
		"10000000-0000-0000-0000-000000000002", player_reconnected.args[0], "player reconnected id"
	)

	var spectator_joined: SFTypesScript.DecodedEvent = decoded_events[18]
	_assert_equal("ABC123", spectator_joined.args[0].room_code, "spectator joined room")
	_assert_equal(
		"30000000-0000-0000-0000-000000000001",
		spectator_joined.args[0].spectator_id,
		"spectator joined id"
	)
	var spectator_joined_players: Array = spectator_joined.args[0].current_players
	_assert_equal(1, spectator_joined_players.size(), "spectator joined players")
	_assert_equal("Alice", spectator_joined.args[0].current_players[0].name, "spectator player")
	var spectator_joined_spectators: Array = spectator_joined.args[0].current_spectators
	_assert_equal(1, spectator_joined_spectators.size(), "spectator joined spectators")
	_assert_equal(
		SFTypesScript.LobbyState.WAITING, spectator_joined.args[0].lobby_state, "spectator lobby"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.JOINED, spectator_joined.args[0].reason, "spectator reason"
	)

	var spectator_join_failed: SFTypesScript.DecodedEvent = decoded_events[19]
	_assert_equal("spectator mode disabled", spectator_join_failed.args[0], "spectator fail reason")
	_assert_equal(
		SFErrorCodesScript.Code.SPECTATOR_NOT_ALLOWED,
		spectator_join_failed.args[1],
		"spectator fail code"
	)

	var spectator_left: SFTypesScript.DecodedEvent = decoded_events[20]
	_assert_equal("20000000-0000-0000-0000-000000000001", spectator_left.args[0], "sl room")
	_assert_equal("ABC123", spectator_left.args[1], "sl code")
	_assert_equal(
		SFTypesScript.SpectatorReason.VOLUNTARY_LEAVE, spectator_left.args[2], "sl reason"
	)
	var spectator_left_spectators: Array = spectator_left.args[3]
	_assert_equal(0, spectator_left_spectators.size(), "sl current spectators")

	var new_spectator: SFTypesScript.DecodedEvent = decoded_events[21]
	_assert_equal("30000000-0000-0000-0000-000000000002", new_spectator.args[0].id, "ns id")
	_assert_equal("Watcher", new_spectator.args[0].name, "ns name")
	var new_spectator_spectators: Array = new_spectator.args[1]
	_assert_equal(1, new_spectator_spectators.size(), "ns current spectators")
	_assert_equal(SFTypesScript.SpectatorReason.JOINED, new_spectator.args[2], "ns reason")

	var spectator_disconnected: SFTypesScript.DecodedEvent = decoded_events[22]
	_assert_equal("30000000-0000-0000-0000-000000000002", spectator_disconnected.args[0], "sd id")
	_assert_equal(
		SFTypesScript.SpectatorReason.DISCONNECTED, spectator_disconnected.args[1], "sd reason"
	)
	var spectator_disconnected_spectators: Array = spectator_disconnected.args[2]
	_assert_equal(0, spectator_disconnected_spectators.size(), "sd current spectators")

	var server_error: SFTypesScript.DecodedEvent = decoded_events[23]
	_assert_equal("message too large", server_error.args[0], "server error message")
	_assert_equal(
		SFErrorCodesScript.Code.MESSAGE_TOO_LARGE, server_error.args[1], "server error code"
	)


func _test_malformed_inputs_decode_to_protocol_error() -> void:
	var lines := _read_fixture_lines(MALFORMED_FIXTURE)
	if not _assert_fixture_count(9, lines, MALFORMED_FIXTURE):
		return
	for index: int in lines.size():
		_assert_protocol_error_text(lines[index], "%s line %d" % [MALFORMED_FIXTURE, index + 1])
	var inline_cases := [
		{"label": "GameStarting missing data", "envelope": {"type": "GameStarting"}},
		{
			"label": "PlayerJoined incomplete player",
			"envelope": {"type": "PlayerJoined", "data": {"player": {"id": "p1", "name": "Alice"}}}
		},
		{
			"label": "LobbyStateChanged unknown state",
			"envelope":
			{
				"type": "LobbyStateChanged",
				"data": {"lobby_state": "unknown", "ready_players": [], "all_ready": false}
			}
		},
		{
			"label": "GameStarting non-object connection_info",
			"envelope":
			_game_starting_envelope(
				[_peer_connection({"relay_type": "websocket", "connection_info": "not-an-object"})]
			)
		},
		{
			"label": "PlayerJoined direct connection missing host",
			"envelope":
			{
				"type": "PlayerJoined",
				"data":
				{
					"player":
					{
						"id": "p1",
						"name": "Alice",
						"is_authority": false,
						"is_ready": false,
						"connected_at": "now",
						"connection_info": {"type": "direct", "port": 7777}
					}
				}
			}
		},
	]
	for test_case: Dictionary in inline_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)


func _test_binary_codec_accepts_base64_payload() -> void:
	var padded: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": "yv4="}
		}
	)
	_assert_equal("game_data_binary_received", String(padded.signal_name), "base64 binary event")
	_assert_equal(PackedByteArray([202, 254]), padded.args[2], "base64 binary payload")


func _test_upstream_optional_fields_decode() -> void:
	var protocol_info: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {}}
	)
	_assert_equal("protocol_info", String(protocol_info.signal_name), "minimal protocol info")
	_assert_equal("", protocol_info.args[0].platform, "minimal protocol platform")
	_assert_equal([], protocol_info.args[0].game_data_formats, "minimal protocol formats")

	var null_player_name_rules: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"player_name_rules": null}}
	)
	_assert_equal(
		"protocol_info",
		String(null_player_name_rules.signal_name),
		"null player name rules optional"
	)
	_assert_equal(null, null_player_name_rules.args[0].player_name_rules, "null name rules")

	var defaulted_player_name_rules: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
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
					"additional_allowed_characters": null
				}
			}
		}
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

	var game_starting: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		_game_starting_envelope([_peer_connection({})])
	)
	_assert_equal("game_starting", String(game_starting.signal_name), "optional peer connection")
	var optional_game_starting_peers: Array = game_starting.args[0]
	_assert_equal(1, optional_game_starting_peers.size(), "optional peer count")
	_assert_equal(null, game_starting.args[0][0].connection_info, "peer connection info optional")
	_assert_equal("regional-relay", game_starting.args[0][0].relay_type, "peer relay label")

	var relay_without_transport: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		_game_starting_envelope([_peer_connection({"connection_info": _relay_connection_info({})})])
	)
	_assert_equal(
		"game_starting", String(relay_without_transport.signal_name), "relay transport defaulted"
	)
	_assert_equal(
		SFTypesScript.RelayTransport.AUTO,
		relay_without_transport.args[0][0].connection_info.transport,
		"defaulted relay transport"
	)
	var relay_null_transport_data := _relay_connection_info({})
	relay_null_transport_data["transport"] = null
	var relay_null_transport: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		_game_starting_envelope([_peer_connection({"connection_info": relay_null_transport_data})])
	)
	_assert_equal("game_starting", String(relay_null_transport.signal_name), "relay null transport")
	_assert_equal(
		SFTypesScript.RelayTransport.AUTO,
		relay_null_transport.args[0][0].connection_info.transport,
		"null relay transport defaults to auto"
	)

	var spectator_joined_without_reason: SFTypesScript.DecodedEvent = (
		SFEventsScript
		. decode_envelope({"type": "SpectatorJoined", "data": _minimal_spectator_joined_data()})
	)
	_assert_equal(
		"spectator_joined",
		String(spectator_joined_without_reason.signal_name),
		"spectator joined absent reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_joined_without_reason.args[0].reason,
		"spectator joined absent reason value"
	)

	var spectator_joined_null_data := _minimal_spectator_joined_data()
	spectator_joined_null_data["reason"] = null
	var spectator_joined_null_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorJoined", "data": spectator_joined_null_data}
	)
	_assert_equal(
		"spectator_joined",
		String(spectator_joined_null_reason.signal_name),
		"spectator joined null reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_joined_null_reason.args[0].reason,
		"spectator joined null reason value"
	)

	var webrtc_player := _minimal_player_data()
	webrtc_player["connection_info"] = {"type": "webrtc", "sdp": null, "ice_candidates": []}
	var webrtc_null_sdp: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": webrtc_player}}
	)
	_assert_equal("player_joined", String(webrtc_null_sdp.signal_name), "webrtc null sdp")
	_assert_equal("", webrtc_null_sdp.args[0].connection_info.sdp, "webrtc null sdp value")

	var spectator_left: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorLeft"}
	)
	_assert_equal("spectator_left", String(spectator_left.signal_name), "minimal spectator left")
	_assert_equal("", spectator_left.args[0], "minimal spectator left room")
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, spectator_left.args[2], "minimal reason")
	var minimal_spectator_left_spectators: Array = spectator_left.args[3]
	_assert_equal(0, minimal_spectator_left_spectators.size(), "minimal spectator list")

	var spectator_left_null_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorLeft", "data": {"reason": null}}
	)
	_assert_equal(
		"spectator_left",
		String(spectator_left_null_reason.signal_name),
		"spectator left null reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_left_null_reason.args[2],
		"spectator left null reason value"
	)

	var new_spectator: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "NewSpectatorJoined", "data": {"spectator": _minimal_spectator_data()}}
	)
	_assert_equal(
		"new_spectator_joined", String(new_spectator.signal_name), "minimal new spectator"
	)
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, new_spectator.args[2], "new reason")

	var new_spectator_null_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "NewSpectatorJoined",
			"data": {"spectator": _minimal_spectator_data(), "reason": null}
		}
	)
	_assert_equal(
		"new_spectator_joined",
		String(new_spectator_null_reason.signal_name),
		"new spectator null reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		new_spectator_null_reason.args[2],
		"new spectator null reason value"
	)

	var disconnected: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1"}}
	)
	_assert_equal(
		"spectator_disconnected", String(disconnected.signal_name), "minimal spectator disconnected"
	)
	_assert_equal(SFTypesScript.SpectatorReason.UNKNOWN, disconnected.args[1], "disconnect reason")

	var disconnected_null_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": null}}
	)
	_assert_equal(
		"spectator_disconnected",
		String(disconnected_null_reason.signal_name),
		"spectator disconnected null reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		disconnected_null_reason.args[1],
		"spectator disconnected null reason value"
	)


func _test_strict_protocol_validation() -> void:
	var required_unknown_error_code: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "AuthenticationError",
			"data": {"error": "bad app", "error_code": "NOT_A_REAL_CODE"}
		}
	)
	_assert_equal(
		"authentication_error",
		String(required_unknown_error_code.signal_name),
		"required unknown error code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		required_unknown_error_code.args[1],
		"required unknown error code value"
	)

	var optional_unknown_error_code: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "RoomJoinFailed", "data": {"reason": "bad room", "error_code": "NOT_A_REAL_CODE"}}
	)
	_assert_equal(
		"room_join_failed",
		String(optional_unknown_error_code.signal_name),
		"optional unknown error code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		optional_unknown_error_code.args[1],
		"optional unknown error code value"
	)

	var required_numeric_error_code: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "AuthenticationError", "data": {"error": "bad app", "error_code": 12}}
	)
	_assert_equal(
		"protocol_error",
		String(required_numeric_error_code.signal_name),
		"required numeric error code"
	)

	var optional_numeric_error_code: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "RoomJoinFailed", "data": {"reason": "bad room", "error_code": 12}}
	)
	_assert_equal(
		"protocol_error",
		String(optional_numeric_error_code.signal_name),
		"optional numeric error code"
	)

	var optional_null_error_code: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "RoomJoinFailed", "data": {"reason": "bad room", "error_code": null}}
	)
	_assert_equal(
		"room_join_failed", String(optional_null_error_code.signal_name), "optional null error code"
	)
	_assert_equal(SFErrorCodesScript.Code.NONE, optional_null_error_code.args[1], "null code")

	var spectator_joined_number_data := _minimal_spectator_joined_data()
	spectator_joined_number_data["reason"] = 3
	var invalid_spectator_reason_cases := [
		{
			"label": "spectator joined numeric reason",
			"envelope": {"type": "SpectatorJoined", "data": spectator_joined_number_data}
		},
		{
			"label": "spectator left numeric reason",
			"envelope": {"type": "SpectatorLeft", "data": {"reason": 3}}
		},
		{
			"label": "new spectator numeric reason",
			"envelope":
			{
				"type": "NewSpectatorJoined",
				"data": {"spectator": _minimal_spectator_data(), "reason": 3}
			}
		},
		{
			"label": "spectator disconnected numeric reason",
			"envelope":
			{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": 3}}
		},
	]
	for test_case: Dictionary in invalid_spectator_reason_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)

	var room_joined_float_data := _minimal_room_joined_data()
	room_joined_float_data["max_players"] = 4.5
	var negative_rate_limit_data := {
		"app_name": "game", "rate_limits": {"per_minute": -1, "per_hour": 0, "per_day": 0}
	}
	var direct_bad_port_player := _minimal_player_data()
	direct_bad_port_player["connection_info"] = {
		"type": "direct", "host": "127.0.0.1", "port": 65536
	}
	var relay_float_client_id_player := _minimal_player_data()
	relay_float_client_id_player["connection_info"] = _relay_connection_info({"client_id": 1.5})
	var invalid_numeric_cases := [
		{
			"label": "float max_players",
			"envelope": {"type": "RoomJoined", "data": room_joined_float_data}
		},
		{
			"label": "negative rate limit",
			"envelope": {"type": "Authenticated", "data": negative_rate_limit_data}
		},
		{
			"label": "port above u16",
			"envelope": {"type": "PlayerJoined", "data": {"player": direct_bad_port_player}}
		},
		{
			"label": "float client id",
			"envelope": {"type": "PlayerJoined", "data": {"player": relay_float_client_id_player}}
		},
	]
	for test_case: Dictionary in invalid_numeric_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)


func _test_protocol_error_diagnostics() -> void:
	var json_error := _assert_protocol_error_text("not-json", "invalid JSON diagnostics")
	_assert_protocol_error_contains(json_error, "line", "invalid JSON includes line")

	var bad_binary := _assert_protocol_error_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": [1, "bad"]}
		},
		"binary payload bad byte diagnostics"
	)
	_assert_protocol_error_contains(bad_binary, "payload byte array[1]", "binary byte index")

	var bad_player := _minimal_player_data()
	bad_player["name"] = 12
	var bad_room_data := _minimal_room_joined_data()
	bad_room_data["current_players"] = [bad_player]
	var bad_room := _assert_protocol_error_envelope(
		{"type": "RoomJoined", "data": bad_room_data}, "room player index diagnostics"
	)
	_assert_protocol_error_contains(bad_room, "current_players: [0]", "room player index")

	var bad_missed_event_data := _minimal_room_joined_data()
	bad_missed_event_data["missed_events"] = [{"type": "PlayerLeft", "data": {}}]
	var bad_missed_event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Reconnected", "data": bad_missed_event_data}
	)
	_assert_equal("reconnected", String(bad_missed_event.signal_name), "missed event diagnostics")
	var bad_missed_events: Array = bad_missed_event.args[1]
	_assert_equal(1, bad_missed_events.size(), "bad missed event count")
	var bad_missed_event_decoded: RefCounted = bad_missed_events[0]
	_assert_protocol_error_contains(
		bad_missed_event_decoded, "missed_events[0]", "missed event index"
	)


## Data-driven sweep over the whole wire table (issue #26): every enum token
## must round-trip through both string conversions and own a category, so a
## future append can never silently decode to UNKNOWN or land in the wrong
## bucket. Category spot pins guard the upstream-doc grouping semantics.
func _test_error_code_table() -> void:
	_assert_equal(
		SFTypesScript.GameDataEncoding.UNKNOWN,
		SFTypesScript.game_data_encoding_from_string(null),
		"null game data encoding"
	)
	_assert_equal(
		SFTypesScript.LobbyState.UNKNOWN,
		SFTypesScript.lobby_state_from_string(null),
		"null lobby state"
	)
	_assert_equal(
		SFTypesScript.RelayTransport.UNKNOWN,
		SFTypesScript.relay_transport_from_string(null),
		"null relay transport"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		SFTypesScript.spectator_reason_from_string(null),
		"null spectator reason"
	)
	for token: String in SFErrorCodesScript.Code:
		if token == "UNKNOWN" or token == "NONE":
			continue
		var code: int = SFErrorCodesScript.Code[token]
		_assert_equal(
			code, SFErrorCodesScript.from_string(token), "%s round-trips from_string" % token
		)
		_assert_equal(
			token, SFErrorCodesScript.to_wire_string(code), "%s round-trips to_wire_string" % token
		)
		_assert(SFErrorCodesScript.is_known(token), "%s is_known" % token)
		_assert(
			SFErrorCodesScript.category(code) != "unknown", "%s has an explicit category" % token
		)
	var non_emitted: Array[String] = SFErrorCodesScript.NON_EMITTED_CODES
	_assert_equal(6, non_emitted.size(), "NON_EMITTED_CODES matches upstream count")
	for token: String in non_emitted:
		_assert(SFErrorCodesScript.is_known(token), "non-emitted %s stays decodable" % token)
	var categories := [
		["UNAUTHORIZED", "authentication"],
		["INVALID_TOKEN", "authentication"],
		["AUTHENTICATION_REQUIRED", "authentication"],
		["INVALID_APP_ID", "authentication"],
		["APP_ID_EXPIRED", "authentication"],
		["APP_ID_REVOKED", "authentication"],
		["APP_ID_SUSPENDED", "authentication"],
		["MISSING_APP_ID", "authentication"],
		["AUTHENTICATION_TIMEOUT", "authentication"],
		["SDK_VERSION_UNSUPPORTED", "authentication"],
		["UNSUPPORTED_GAME_DATA_FORMAT", "authentication"],
		["CONNECTION_IDLE_TIMEOUT", "authentication"],
		["SLOW_CONSUMER", "authentication"],
		["ACTIVITY_TIMEOUT", "authentication"],
		["UNSUPPORTED_PROTOCOL_VERSION", "authentication"],
		["CONNECT_TOKEN_INVALID", "authentication"],
		["CONNECT_TOKEN_REQUIRED", "authentication"],
		["INVALID_INPUT", "validation"],
		["INVALID_GAME_NAME", "validation"],
		["INVALID_ROOM_CODE", "validation"],
		["INVALID_PLAYER_NAME", "validation"],
		["INVALID_MAX_PLAYERS", "validation"],
		["MESSAGE_TOO_LARGE", "validation"],
		["INVALID_DELIVERY_CLASS", "validation"],
		["ROOM_NOT_FOUND", "room"],
		["ROOM_FULL", "room"],
		["ALREADY_IN_ROOM", "room"],
		["NOT_IN_ROOM", "room"],
		["ROOM_CREATION_FAILED", "room"],
		["MAX_ROOMS_PER_GAME_EXCEEDED", "room"],
		["INVALID_ROOM_STATE", "room"],
		["GAME_START_NOT_READY", "room"],
		["GAME_START_FORBIDDEN", "room"],
		["ROOM_SESSION_INCOMPATIBLE", "room"],
		["NOT_ROOM_AUTHORITY", "room"],
		["KICK_TARGET_NOT_FOUND", "room"],
		["KICKED", "room"],
		["PASSWORD_REQUIRED", "room"],
		["BANNED", "room"],
		["TRANSFER_TARGET_NOT_FOUND", "room"],
		["AUTHORITY_NOT_SUPPORTED", "authority"],
		["AUTHORITY_CONFLICT", "authority"],
		["AUTHORITY_DENIED", "authority"],
		["RATE_LIMIT_EXCEEDED", "ratelimit"],
		["TOO_MANY_CONNECTIONS", "ratelimit"],
		["RECONNECTION_FAILED", "reconnection"],
		["RECONNECTION_TOKEN_INVALID", "reconnection"],
		["RECONNECTION_EXPIRED", "reconnection"],
		["PLAYER_ALREADY_CONNECTED", "reconnection"],
		["SPECTATOR_NOT_ALLOWED", "spectator"],
		["TOO_MANY_SPECTATORS", "spectator"],
		["NOT_A_SPECTATOR", "spectator"],
		["SPECTATOR_JOIN_FAILED", "spectator"],
		["CROSS_ROOM_SIGNAL", "signaling"],
		["UNSUPPORTED_TRANSPORT", "signaling"],
		["SIGNAL_TARGET_NOT_FOUND", "signaling"],
		["SIGNAL_RATE_LIMITED", "signaling"],
		["SIGNAL_TOO_LARGE", "signaling"],
		["INTERNAL_ERROR", "server"],
		["STORAGE_ERROR", "server"],
		["SERVICE_UNAVAILABLE", "server"],
		["DATABASE_ERROR", "server"],
		["SERVER_DRAINING", "server"],
	]
	for entry: Array in categories:
		var entry_code: int = SFErrorCodesScript.Code[entry[0]]
		_assert_equal(entry[1], SFErrorCodesScript.category(entry_code), "%s category" % entry[0])
	_assert_equal(
		SFErrorCodesScript.Code.NONE, SFErrorCodesScript.from_string(null), "absent optional code"
	)
	_assert_equal(
		"none", SFErrorCodesScript.category(SFErrorCodesScript.Code.NONE), "none category"
	)
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		SFErrorCodesScript.from_string("NOT_A_REAL_CODE"),
		"unknown code"
	)
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		SFErrorCodesScript.from_string(12),
		"non-string input stays UNKNOWN"
	)
	_assert_equal(
		"UNKNOWN",
		SFErrorCodesScript.to_wire_string(SFErrorCodesScript.Code.UNKNOWN),
		"unknown wire"
	)
	_assert_equal("UNKNOWN", SFErrorCodesScript.to_wire_string(-999), "unmapped int wire")
	_assert_equal("unknown", SFErrorCodesScript.category(-999), "unknown category")
	_assert_equal(
		SFErrorCodesScript.Code.UNKNOWN,
		SFErrorCodesScript.from_string("UNKNOWN"),
		"UNKNOWN token stays UNKNOWN"
	)
	_assert_equal("", SFErrorCodesScript.to_wire_string(SFErrorCodesScript.Code.NONE), "none wire")


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


func _assert_fixture_count(expected: int, lines: PackedStringArray, path: String) -> bool:
	return _assert_equal(expected, lines.size(), "%s fixture count" % path)


func _assert_decoded_signal(expected: String, decoded: RefCounted, label: String) -> bool:
	if decoded == null:
		_failures.append("%s: expected signal %s, got <null decoded event>" % [label, expected])
		return false
	if str(decoded.get("signal_name")) == expected:
		return true
	_failures.append(
		"%s: expected signal %s, got %s" % [label, expected, _decoded_summary(decoded)]
	)
	return false


func _assert_protocol_error_text(text: String, label: String) -> RefCounted:
	var decoded := SFEventsScript.decode_text(text)
	_assert_protocol_error(decoded, label)
	return decoded


func _assert_protocol_error_envelope(envelope: Dictionary, label: String) -> RefCounted:
	var decoded := SFEventsScript.decode_envelope(envelope)
	_assert_protocol_error(decoded, "%s envelope=%s" % [label, var_to_str(envelope)])
	return decoded


func _assert_protocol_error(decoded: RefCounted, label: String) -> bool:
	if not _assert_decoded_signal("protocol_error", decoded, label):
		return false
	var args: Array = decoded.get("args")
	if not _assert_equal(1, args.size(), "%s protocol_error args" % label):
		return false
	return _assert(
		typeof(args[0]) == TYPE_STRING and not str(args[0]).is_empty(),
		"%s protocol_error message must be non-empty" % label
	)


func _assert_protocol_error_contains(
	decoded: RefCounted, expected_substring: String, label: String
) -> bool:
	if not _assert_protocol_error(decoded, label):
		return false
	var args: Array = decoded.get("args")
	return _assert_string_contains(str(args[0]), expected_substring, label)


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


func _decoded_summary(decoded: RefCounted) -> String:
	if decoded == null:
		return "<null decoded event>"
	var signal_text := "<missing>"
	if decoded.get("signal_name") != null:
		signal_text = str(decoded.get("signal_name"))
	var args_text := "<missing>"
	if decoded.get("args") != null:
		args_text = var_to_str(decoded.get("args"))
	return "%s args=%s" % [signal_text, args_text]
