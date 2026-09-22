extends SceneTree

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const HeartbeatTestsScript = preload("res://tests/client/heartbeat_tests.gd")
const V3ClientTestsScript = preload("res://tests/client/v3_client_tests.gd")
const WebrtcMeshTestsScript = preload("res://tests/client/webrtc_mesh_tests.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const ROOM_ID := "20000000-0000-0000-0000-000000000001"

var _failures: Array = []
# Sentinel: an abort inside _run() unwinds before quit(); CI would hang instead of reporting red.
var _run_completed := false


func _init() -> void:
	_run()
	if not _run_completed:
		push_error("client tests aborted before completion")
		quit(1)
		return
	if _failures.is_empty():
		print("client tests passed")
		quit(0)
	else:
		push_error("client tests failed: %d failure(s)" % _failures.size())
		for failure: String in _failures:
			push_error(failure)
		quit(1)


## A helper suite that fails to compile preloads as a GDScript object with no
## members; calling it would abort _run() mid-way and the (empty) failure list
## would report a false pass. Verify every helper suite is loadable up front.
func _helper_suites_are_loadable() -> bool:
	if not (V3ClientTestsScript as Script).has_method("run"):
		push_error("helper suite failed to load: v3_client_tests")
		return false
	if not (WebrtcMeshTestsScript as Script).has_method("run"):
		push_error("helper suite failed to load: webrtc_mesh_tests")
		return false
	return true


func _run() -> void:
	if not _helper_suites_are_loadable():
		_failures.append("helper suites failed to load")
		return
	_test_configure_validation()
	_test_configure_and_connect_guards()
	_test_auto_authenticate_matches_builder_bytes()
	_test_preauth_guards_block_all_sends()
	_test_authenticated_args_and_send_surface()
	_test_duplicate_authenticated_is_once_per_dial()
	_test_room_lifecycle_state_machine()
	_test_spectators_keep_lobby_updates_and_rosters_stay_stable()
	_test_connected_handler_close_does_not_crash()
	_test_presence_and_data_events()
	_test_spectator_flow()
	_test_reconnected_restores_room_state()
	_test_backpressure_returns_busy_and_drops()
	_test_close_surfaces_code_reason_and_cleans_up()
	_test_process_and_exit_tree_paths()
	_test_roster_accessors_are_copies()
	_test_failures_clean_up_and_failed_open_surfaces_reason()
	_test_frame_cap_drops_oversized_and_binary_frames()
	_test_duplicate_key_frame_fails_closed()
	_test_mixed_content_guard_is_data_driven()
	_test_log_redaction_and_level_gate()
	_test_config_to_string_redacts_credential()
	_failures.append_array(V3ClientTestsScript.run(self))
	_failures.append_array(HeartbeatTestsScript.run(self))
	_failures.append_array(WebrtcMeshTestsScript.run(self))
	_run_completed = true


func _test_configure_validation() -> void:
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	_assert_equal(ERR_INVALID_PARAMETER, client.configure(null), "null config rejected")
	_assert_equal(1, errors.size(), "null config emits protocol_error")

	var config := SignalFishConfigScript.new()
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "empty app_id rejected")
	config.app_id = "test-app"
	config.game_data_format = "carrier_pigeon"
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "unknown format rejected")
	config.game_data_format = "message_pack"
	_assert_equal(OK, client.configure(config), "message_pack format accepted")
	config.game_data_format = "rkyv"
	_assert_equal(OK, client.configure(config), "rkyv format accepted")
	config.game_data_format = "json"
	config.max_buffered_bytes = 0
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "zero cap rejected")
	config.max_buffered_bytes = 16
	config.max_inbound_frame_bytes = -1
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "negative frame cap rejected")
	config.max_inbound_frame_bytes = 32
	config.max_inbound_packets_per_poll = 0
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "zero packet cap rejected")

	config.max_inbound_packets_per_poll = 8
	_assert_equal(OK, client.configure(config), "valid config accepted")

	var connected := _make_in_room_client()
	_assert_equal(
		ERR_BUSY,
		connected.configure(SignalFishConfigScript.new()),
		"reconfigure while connected rejected"
	)
	connected.free()
	client.free()


func _test_configure_and_connect_guards() -> void:
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	_assert_equal(
		ERR_UNCONFIGURED,
		client.connect_to_server("ws://example.test"),
		"unconfigured connect rejected"
	)
	_assert_equal(1, errors.size(), "unconfigured connect emits protocol_error")

	_assert_equal(OK, client.configure(_make_config()), "configure")
	_assert_equal(
		ERR_INVALID_PARAMETER,
		client.connect_to_server("http://example.test"),
		"invalid scheme rejected"
	)
	_assert_equal(
		ERR_INVALID_PARAMETER, client.connect_to_server(""), "missing url rejected without endpoint"
	)
	_assert_equal(
		SignalFishClientScript.ConnectionState.DISCONNECTED,
		client.get_connection_state(),
		"failed connects stay disconnected"
	)
	_assert_equal(3, errors.size(), "each refused connect emits protocol_error")

	var fake: SFFakeTransportScript = SFFakeTransportScript.new()
	client.transport = fake
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	_assert_equal(
		ERR_BUSY, client.connect_to_server("ws://example.test/socket"), "double connect rejected"
	)
	client.free()


func _test_auto_authenticate_matches_builder_bytes() -> void:
	var client := _make_connected_client()
	var fake: SFFakeTransportScript = client.transport
	var expected := SFMessagesScript.encode(
		SFMessagesScript.authenticate("test-app", "0.1.0", "linux", "json")
	)
	_assert_equal([expected], fake.sent_text, "authenticate matches builder bytes")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATING,
		client.get_session_state(),
		"session authenticating after open"
	)
	client.free()

	var minimal_config := _make_config()
	minimal_config.sdk_version = ""
	minimal_config.platform = ""
	minimal_config.game_data_format = ""
	var minimal := _connect_new_client(minimal_config)
	var minimal_transport: SFFakeTransportScript = minimal.transport
	minimal_transport.inject_open()
	_assert_equal(
		[SFMessagesScript.encode(SFMessagesScript.authenticate("test-app"))],
		minimal.transport.sent_text,
		"unset optionals omitted from authenticate"
	)
	minimal.free()


func _test_preauth_guards_block_all_sends() -> void:
	var send_cases := _send_method_cases()
	for attempt: int in [0, 1]:
		var client := SignalFishClientScript.new()
		var errors := _track_protocol_errors(client)
		var phase := "unconfigured" if attempt == 0 else "authenticating"
		if attempt == 1:
			_assert_equal(OK, client.configure(_make_config()), "configure")
			var transport: SFFakeTransportScript = SFFakeTransportScript.new()
			client.transport = transport
			_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
			transport.inject_open()
		for send_case: Array in send_cases:
			var send_case_fn: Callable = send_case[1]
			_assert_equal(
				ERR_UNAUTHORIZED,
				send_case_fn.call(client),
				"%s blocked while %s" % [send_case[0], phase]
			)
		_assert_equal(send_cases.size(), errors.size(), "every blocked send explains itself")
		if attempt == 1:
			var fake: SFFakeTransportScript = client.transport
			_assert_equal(1, fake.sent_text.size(), "only authenticate was sent while guarding")
		client.free()


func _test_authenticated_args_and_send_surface() -> void:
	var client := _make_connected_client()
	var fake: SFFakeTransportScript = client.transport
	var authenticated_events: Array = []
	client.authenticated.connect(
		func(
			app_name: String, organization: String, rate_limits: SFTypesScript.RateLimitInfo
		) -> void:
			authenticated_events.append([app_name, organization, rate_limits.per_minute])
	)
	client.authentication_error.connect(
		func(error: String, error_code: int) -> void:
			authenticated_events.append(["error", error, error_code])
	)
	fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal(
		[["Reef Rally", "", 60]], authenticated_events, "authenticated surfaces typed payload"
	)
	_assert_equal(true, client.is_authenticated(), "is_authenticated after Authenticated")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session authenticated"
	)

	var params := SignalFishClientScript.JoinRoomParams.new()
	params.game_name = "reef-rally"
	params.player_name = "Alice"
	params.room_code = "ABC123"
	params.max_players = 4
	_assert_equal(OK, client.join_room(params), "join_room")
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_room("reef-rally", "Alice", "ABC123", 4, null, null)
		),
		fake.sent_text.back(),
		"join_room bytes"
	)

	params.max_players = 999
	_assert_equal(ERR_INVALID_DATA, client.join_room(params), "invalid join_room rejected")
	params.max_players = 0
	_assert_equal(OK, client.join_room(params), "join_room omits zero max_players")
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_room("reef-rally", "Alice", "ABC123", null, null, null)
		),
		fake.sent_text.back(),
		"zero max_players omitted"
	)

	_assert_equal(OK, client.set_ready(), "set_ready")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.player_ready()),
		fake.sent_text.back(),
		"set_ready bytes"
	)

	_assert_equal(OK, client.start_game(), "start_game")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.start_game()),
		fake.sent_text.back(),
		"start_game bytes"
	)

	# Issue #26: set passwords ride the wire, empty ones are omitted (refused upstream).
	var sealed_params := SignalFishClientScript.JoinRoomParams.new()
	sealed_params.game_name = "reef-rally"
	sealed_params.player_name = "Alice"
	sealed_params.room_code = "ABC123"
	sealed_params.password = "sealed-room-pass"
	_assert_equal(OK, client.join_room(sealed_params), "sealed join_room")
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_room(
				"reef-rally", "Alice", "ABC123", null, null, null, "sealed-room-pass"
			)
		),
		fake.sent_text.back(),
		"sealed join_room bytes"
	)
	_assert_equal(OK, client.join_room(params), "open join_room omits password")
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_room("reef-rally", "Alice", "ABC123", null, null, null, null)
		),
		fake.sent_text.back(),
		"password omitted from open join_room"
	)

	_assert_equal(OK, client.request_authority(true), "request_authority")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.authority_request(true)),
		fake.sent_text.back(),
		"request_authority bytes"
	)

	var info := SFTypesScript.ConnectionInfo.new({"type": "direct", "host": "127.0.0.1", "port": 1})
	_assert_equal(OK, client.provide_connection_info(info), "provide_connection_info")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.provide_connection_info(info.to_dict())),
		fake.sent_text.back(),
		"provide_connection_info bytes"
	)
	_assert_equal(
		ERR_INVALID_PARAMETER, client.provide_connection_info(null), "null connection info rejected"
	)

	_assert_equal(OK, client.ping(), "ping")
	_assert_equal(SFMessagesScript.encode(SFMessagesScript.ping()), fake.sent_text.back(), "ping")

	_assert_equal(OK, client.send_game_data({"score": 7}), "send_game_data")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.game_data({"score": 7})),
		fake.sent_text.back(),
		"send_game_data bytes"
	)

	_assert_equal(
		OK, client.join_as_spectator("reef-rally", "ABC123", "Watcher"), "join_as_spectator"
	)
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_as_spectator("reef-rally", "ABC123", "Watcher")
		),
		fake.sent_text.back(),
		"join_as_spectator bytes"
	)
	_assert_equal(
		OK,
		client.join_as_spectator("reef-rally", "ABC123", "Watcher", "sealed-room-pass"),
		"sealed join_as_spectator"
	)
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.join_as_spectator(
				"reef-rally", "ABC123", "Watcher", "sealed-room-pass"
			)
		),
		fake.sent_text.back(),
		"sealed join_as_spectator bytes"
	)
	_assert_equal(OK, client.leave_spectator(), "leave_spectator")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.leave_spectator()),
		fake.sent_text.back(),
		"leave_spectator bytes"
	)
	_assert_equal(OK, client.leave_room(), "leave_room")
	_assert_equal(
		SFMessagesScript.encode(SFMessagesScript.leave_room()),
		fake.sent_text.back(),
		"leave_room bytes"
	)

	client.close()
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"clean close observed"
	)
	_assert_equal(ERR_UNAUTHORIZED, client.send_game_data({}), "send after close blocked")
	client.free()


func _test_duplicate_authenticated_is_once_per_dial() -> void:
	# Issue #24: duplicate Authenticated on a normal dial is hostile input; the guard keeps it silent.
	var client := _make_connected_client()
	var fake: SFFakeTransportScript = client.transport
	var authenticated_events: Array = []
	client.authenticated.connect(
		func(_app: String, _org: String, _rate_limits: SFTypesScript.RateLimitInfo) -> void:
			authenticated_events.append(1)
	)
	fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal([1], authenticated_events, "authenticated emitted exactly once per dial")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"session state untouched by the duplicate"
	)
	client.free()

	var room_client := _make_authenticated_client()
	var room_fake: SFFakeTransportScript = room_client.transport
	var room_events: Array = []
	room_client.authenticated.connect(
		func(_app: String, _org: String, _rate_limits: SFTypesScript.RateLimitInfo) -> void:
			room_events.append(1)
	)
	var params := SignalFishClientScript.JoinRoomParams.new()
	params.game_name = "reef-rally"
	params.player_name = "Alice"
	room_client.join_room(params)
	room_fake.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_WAITING,
		room_client.get_session_state(),
		"in-room before the duplicate"
	)
	room_fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	_assert_equal([], room_events, "in-room duplicate stays consumer-silent")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_WAITING,
		room_client.get_session_state(),
		"in-room state untouched by the duplicate"
	)
	room_client.free()


func _test_room_lifecycle_state_machine() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var joined_payloads: Array = []
	var lobby_events: Array = []
	var room_left_count := [0]
	client.room_joined.connect(
		func(info: SFTypesScript.RoomJoinedInfo) -> void: joined_payloads.append(info)
	)
	client.lobby_state_changed.connect(
		func(state: int, ready_players: PackedStringArray, all_ready: bool) -> void:
			lobby_events.append([state, ready_players, all_ready])
	)
	client.room_left.connect(func() -> void: room_left_count[0] += 1)

	fake.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(1, joined_payloads.size(), "room_joined emitted")
	_assert_equal(PLAYER_A, joined_payloads[0].player_id, "room_joined payload player")
	_assert_equal("ABC123", client.get_room_code(), "room_code cached")
	_assert_equal(ROOM_ID, client.get_room_id(), "room_id cached")
	_assert_equal(PLAYER_A, client.get_player_id(), "player_id cached")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_WAITING,
		client.get_session_state(),
		"waiting session state"
	)
	_assert_equal(1, client.get_players().size(), "roster populated")
	_assert_equal(1, client.get_spectators().size(), "spectators populated")

	fake.inject_server_message(
		{
			"type": "LobbyStateChanged",
			"data": {"lobby_state": "lobby", "ready_players": [PLAYER_A], "all_ready": true}
		}
	)
	_assert_equal(
		[[SFTypesScript.LobbyState.LOBBY, PackedStringArray([PLAYER_A]), true]],
		lobby_events,
		"lobby_state_changed emitted"
	)
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"lobby session state"
	)
	_assert_equal(SFTypesScript.LobbyState.LOBBY, client.get_lobby_state(), "lobby state cached")

	fake.inject_server_message(
		{"type": "GameStarting", "data": {"peer_connections": [_peer_connection()]}}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"game_starting does not change session state"
	)

	fake.inject_server_message(
		{
			"type": "LobbyStateChanged",
			"data": {"lobby_state": "finalized", "ready_players": [], "all_ready": false}
		}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_FINALIZED,
		client.get_session_state(),
		"finalized session state"
	)

	fake.inject_server_message({"type": "RoomLeft"})
	_assert_equal(1, room_left_count[0], "room_left emitted")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"room_left returns to authenticated"
	)
	_assert_equal("", client.get_room_id(), "room state cleared on leave")
	_assert_equal("", client.get_player_id(), "player id cleared on leave")
	_assert_equal([], client.get_players(), "roster cleared on leave")
	client.free()


func _test_spectators_keep_lobby_updates_and_rosters_stay_stable() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	# Lambdas capture locals by value; hold the payload in an Array to observe it.
	var room_holder: Array = []
	client.room_joined.connect(
		func(info: SFTypesScript.RoomJoinedInfo) -> void: room_holder.append(info)
	)
	fake.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	_assert_equal(1, client.get_players().size(), "initial roster")
	fake.inject_server_message(
		{"type": "PlayerJoined", "data": {"player": _player(PLAYER_B, "Bob")}}
	)
	_assert_equal(2, client.get_players().size(), "roster updated")
	var emitted_info: SFTypesScript.RoomJoinedInfo = room_holder[0]
	_assert_equal(
		1, emitted_info.current_players.size(), "emitted room_joined payload never mutates"
	)

	fake.inject_server_message(
		{
			"type": "SpectatorJoined",
			"data":
			{
				"room_id": "20000000-0000-0000-0000-000000000009",
				"room_code": "SPEC1",
				"spectator_id": PLAYER_B,
				"game_name": "reef-rally",
				"current_players": [_player(PLAYER_A, "Alice")],
				"current_spectators": [],
				"lobby_state": "waiting"
			}
		}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING,
		client.get_session_state(),
		"spectating before lobby update"
	)
	fake.inject_server_message(
		{
			"type": "LobbyStateChanged",
			"data": {"lobby_state": "lobby", "ready_players": [PLAYER_A], "all_ready": true}
		}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING,
		client.get_session_state(),
		"spectators stay spectating across lobby updates"
	)
	_assert_equal(
		SFTypesScript.LobbyState.LOBBY, client.get_lobby_state(), "spectator lobby state tracked"
	)
	client.free()


func _test_connected_handler_close_does_not_crash() -> void:
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	var close_events: Array = []
	client.connected.connect(func() -> void: client.close())
	client.disconnected.connect(
		func(code: int, reason: String) -> void: close_events.append([code, reason])
	)
	_assert_equal(OK, client.configure(_make_config()), "configure")
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	client.transport = transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	transport.inject_open()
	_assert_equal([[1000, ""]], close_events, "handler-driven close completes cleanly")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED, client.get_connection_state(), "closed"
	)
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		client.get_session_state(),
		"no authenticate attempted after handler close"
	)
	_assert_equal(0, errors.size(), "no protocol errors from the torn-down session")
	client.free()


func _test_presence_and_data_events() -> void:
	var client := _make_in_room_client()
	var fake: SFFakeTransportScript = client.transport
	var events: Array = []
	client.player_joined.connect(
		func(player: SFTypesScript.PlayerInfo) -> void: events.append(["joined", player.id])
	)
	client.player_left.connect(func(id: String) -> void: events.append(["left", id]))
	client.player_reconnected.connect(func(id: String) -> void: events.append(["reconnected", id]))
	client.game_data_received.connect(
		func(from_player: String, data: Variant) -> void: events.append(["data", from_player, data])
	)
	client.game_data_binary_received.connect(
		func(from_player: String, encoding: int, payload: PackedByteArray) -> void:
			events.append(["binary", from_player, encoding, payload])
	)
	client.pong.connect(func() -> void: events.append(["pong"]))
	client.authority_changed.connect(
		func(authority_player: String, you_are_authority: bool) -> void:
			events.append(["authority", authority_player, you_are_authority])
	)
	client.authority_response.connect(
		func(granted: bool, reason: String, error_code: int) -> void:
			events.append(["authority_response", granted, reason, error_code])
	)
	client.server_error.connect(
		func(message: String, error_code: int) -> void:
			events.append(["server_error", message, error_code])
	)
	client.protocol_info.connect(
		func(info: SFTypesScript.ProtocolInfo) -> void:
			events.append(["protocol_info", info.sdk_version])
	)

	fake.inject_server_message(
		{"type": "PlayerJoined", "data": {"player": _player(PLAYER_B, "Bob")}}
	)
	_assert_equal(2, client.get_players().size(), "player_joined upserts roster")
	fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_B}})
	_assert_equal(1, client.get_players().size(), "player_left removes from roster")
	fake.inject_server_message({"type": "PlayerReconnected", "data": {"player_id": PLAYER_A}})
	fake.inject_server_message({"type": "Pong"})
	fake.inject_server_message(
		{"type": "GameData", "data": {"from_player": PLAYER_A, "data": {"score": 3}}}
	)
	fake.inject_server_message(
		{
			"type": "GameDataBinary",
			"data": {"from_player": PLAYER_A, "encoding": "message_pack", "payload": [1, 2, 3]}
		}
	)
	fake.inject_server_message(
		{
			"type": "AuthorityChanged",
			"data": {"authority_player": PLAYER_A, "you_are_authority": true}
		}
	)
	fake.inject_server_message(
		{"type": "AuthorityResponse", "data": {"granted": false, "reason": "not eligible"}}
	)
	fake.inject_server_message(
		{"type": "Error", "data": {"message": "slow down", "error_code": "RATE_LIMIT_EXCEEDED"}}
	)
	fake.inject_server_message({"type": "ProtocolInfo", "data": _protocol_info()})

	_assert_equal(
		[
			["joined", PLAYER_B],
			["left", PLAYER_B],
			["reconnected", PLAYER_A],
			["pong"],
			["data", PLAYER_A, {"score": 3.0}],
			[
				"binary",
				PLAYER_A,
				SFTypesScript.GameDataEncoding.MESSAGE_PACK,
				PackedByteArray([1, 2, 3])
			],
			["authority", PLAYER_A, true],
			["authority_response", false, "not eligible", SFErrorCodesScript.Code.NONE],
			["server_error", "slow down", SFErrorCodesScript.Code.RATE_LIMIT_EXCEEDED],
			["protocol_info", "0.8.0"],
		],
		events,
		"presence and data events surface with typed payloads"
	)
	client.free()


func _test_spectator_flow() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var spectator_events: Array = []
	client.spectator_joined.connect(
		func(info: SFTypesScript.SpectatorJoinedInfo) -> void:
			spectator_events.append(["joined", info.spectator_id])
	)
	client.new_spectator_joined.connect(
		func(
			spectator: SFTypesScript.SpectatorInfo, current_spectators: Array, reason: int
		) -> void:
			spectator_events.append(["new", spectator.id, current_spectators.size(), reason])
	)
	client.spectator_disconnected.connect(
		func(spectator_id: String, reason: int, current_spectators: Array) -> void:
			spectator_events.append(["gone", spectator_id, current_spectators.size(), reason])
	)
	client.spectator_left.connect(
		func(room_id: String, room_code: String, reason: int, current_spectators: Array) -> void:
			spectator_events.append(["left", room_code, reason, current_spectators.size()])
	)
	client.spectator_join_failed.connect(
		func(reason: String, error_code: int) -> void:
			spectator_events.append(["failed", reason, error_code])
	)

	fake.inject_server_message(
		{
			"type": "SpectatorJoined",
			"data":
			{
				"room_id": "20000000-0000-0000-0000-000000000009",
				"room_code": "SPEC1",
				"spectator_id": PLAYER_B,
				"game_name": "reef-rally",
				"current_players": [_player(PLAYER_A, "Alice")],
				"current_spectators": [],
				"lobby_state": "waiting"
			}
		}
	)
	_assert_equal(
		SignalFishClientScript.SessionState.SPECTATING,
		client.get_session_state(),
		"spectating session state"
	)
	_assert_equal("SPEC1", client.get_room_code(), "spectator room code cached")
	_assert_equal(1, client.get_players().size(), "spectator sees players")

	fake.inject_server_message(
		{
			"type": "NewSpectatorJoined",
			"data":
			{
				"spectator": _spectator(PLAYER_A, "Second"),
				"current_spectators": [_spectator(PLAYER_B, "Watcher")],
				"reason": "joined"
			}
		}
	)
	_assert_equal(1, client.get_spectators().size(), "new_spectator_joined upserts roster")
	fake.inject_server_message(
		{
			"type": "SpectatorDisconnected",
			"data":
			{
				"spectator_id": PLAYER_A,
				"reason": "disconnected",
				"current_spectators": [_spectator(PLAYER_B, "Watcher")]
			}
		}
	)
	_assert_equal(0, client.get_spectators().size(), "spectator_disconnected updates roster")
	fake.inject_server_message(
		{"type": "SpectatorJoinFailed", "data": {"reason": "room full", "error_code": "ROOM_FULL"}}
	)
	fake.inject_server_message(
		{
			"type": "SpectatorLeft",
			"data":
			{
				"room_id": "20000000-0000-0000-0000-000000000009",
				"room_code": "SPEC1",
				"reason": "voluntary_leave",
				"current_spectators": []
			}
		}
	)
	_assert_equal("", client.get_room_id(), "spectator_left clears room state")
	_assert_equal(
		SignalFishClientScript.SessionState.AUTHENTICATED,
		client.get_session_state(),
		"spectator_left returns to authenticated"
	)
	_assert_equal(
		[
			["joined", PLAYER_B],
			["new", PLAYER_A, 1, SFTypesScript.SpectatorReason.JOINED],
			["gone", PLAYER_A, 1, SFTypesScript.SpectatorReason.DISCONNECTED],
			["failed", "room full", SFErrorCodesScript.Code.ROOM_FULL],
			["left", "SPEC1", SFTypesScript.SpectatorReason.VOLUNTARY_LEAVE, 0],
		],
		spectator_events,
		"spectator events surface"
	)
	client.free()


func _test_reconnected_restores_room_state() -> void:
	# `Reconnected` only arrives in response to the directed handshake
	# (issue #82), so the test drives a real reconnect dial instead of
	# injecting the event into a normal-auth session.
	var client := _make_reconnect_dial_client()
	var fake: SFFakeTransportScript = client.transport
	var restored: Array = []
	var failures: Array = []
	client.reconnected.connect(
		func(info: SFTypesScript.RoomJoinedInfo, missed_events: Array) -> void:
			restored.append([info, missed_events])
	)
	client.reconnection_failed.connect(
		func(reason: String, error_code: int) -> void: failures.append([reason, error_code])
	)
	fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})

	var reconnected_data := _room_joined_data({"lobby_state": "lobby", "ready_players": [PLAYER_A]})
	reconnected_data["missed_events"] = [
		{"type": "Pong"},
		{"type": "GameData", "data": {"from_player": PLAYER_A, "data": {"hp": 2}}},
	]
	fake.inject_server_message({"type": "Reconnected", "data": reconnected_data})
	_assert_equal(1, restored.size(), "reconnected emitted")
	var missed_events: Array = restored[0][1]
	_assert_equal(2, missed_events.size(), "missed_events decoded")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_LOBBY,
		client.get_session_state(),
		"reconnected restores lobby state"
	)
	_assert_equal(SFTypesScript.LobbyState.LOBBY, client.get_lobby_state(), "lobby state restored")
	_assert_equal([], failures, "no reconnection_failed")
	client.free()


func _make_reconnect_dial_client() -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	var errors := _track_protocol_errors(client)
	var config := _make_config()
	config.endpoint_url = "ws://example.test/socket"
	_assert_equal(OK, client.configure(config), "configure")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(
		OK, client.reconnect(PLAYER_A, ROOM_ID, "test-reconnect-token-not-secret"), "reconnect dial"
	)
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	_assert_equal([], errors, "reconnect dial is error-free")
	return client


func _test_backpressure_returns_busy_and_drops() -> void:
	var client := _make_authenticated_client()
	var errors := _track_protocol_errors(client)
	var fake: SFFakeTransportScript = client.transport
	var baseline: int = fake.sent_text.size()
	fake.buffered_amount = _make_config().max_buffered_bytes + 1
	_assert_equal(ERR_BUSY, client.send_game_data({"x": 1}), "backpressure returns ERR_BUSY")
	_assert_equal(baseline, fake.sent_text.size(), "backpressure drops the message")
	_assert_equal(1, errors.size(), "backpressure emits protocol_error")
	var backpressure_error: String = errors[0]
	_assert_string_contains(backpressure_error, "backpressure", "backpressure message")
	client.free()


func _test_close_surfaces_code_reason_and_cleans_up() -> void:
	for close_case: Array in [[1000, "bye"], [-1, ""]]:
		var client := _make_in_room_client()
		var fake: SFFakeTransportScript = client.transport
		var close_events: Array = []
		client.disconnected.connect(
			func(code: int, reason: String) -> void: close_events.append([code, reason])
		)
		_assert_equal(0, client.get_buffered_amount(), "buffered amount proxies transport")

		var close_code: int = close_case[0]
		var close_reason: String = close_case[1]
		fake.inject_close(close_code, close_reason)
		_assert_equal([close_case], close_events, "close code/reason surfaced (%d)" % close_case[0])
		_assert_equal(
			SignalFishClientScript.ConnectionState.CLOSED,
			client.get_connection_state(),
			"closed (%d)" % close_case[0]
		)
		_assert_equal(
			SignalFishClientScript.SessionState.UNAUTHENTICATED,
			client.get_session_state(),
			"session reset on close (%d)" % close_case[0]
		)
		_assert_equal("", client.get_room_id(), "room cleared on close (%d)" % close_case[0])
		_assert_equal("", client.get_player_id(), "player id cleared on close")
		_assert_equal([], client.get_players(), "roster cleared on close (%d)" % close_case[0])
		_assert_equal(null, client.transport, "transport released on close")
		_assert_equal(true, client.close() == OK, "close after closed is a no-op")
		client.free()


func _test_process_and_exit_tree_paths() -> void:
	var config := _make_config()
	config.auto_poll = true
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	_assert_equal(OK, client.configure(config), "configure")
	var transport: PollCountingTransport = PollCountingTransport.new()
	client.transport = transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	client._process(0.016)
	_assert_equal(1, client.transport.poll_count, "_process drives transport poll")
	transport.inject_open()
	client._process(0.016)
	_assert_equal(2, client.transport.poll_count, "poll continues while connected")

	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	config.auto_poll = false
	client._process(0.016)
	_assert_equal(2, client.transport.poll_count, "auto_poll off disables _process polling")

	client._exit_tree()
	_assert_equal(
		SignalFishClientScript.ConnectionState.CLOSED,
		client.get_connection_state(),
		"tree exit closes the session"
	)
	_assert_equal(null, client.transport, "tree exit releases the transport")
	client.free()


## Issue #87: the accessors hand out defensive copies — a live-array
## reference would let one caller mutation corrupt session state silently.
func _test_roster_accessors_are_copies() -> void:
	var client := _make_in_room_client()
	var roster: Array = client.get_players()
	var spectators: Array = client.get_spectators()
	_assert(not is_same(client.get_players(), roster), "get_players returns a copy")
	_assert(not is_same(client.get_spectators(), spectators), "get_spectators returns a copy")
	roster.clear()
	spectators.clear()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_A}})
	_assert_equal(0, client.get_players().size(), "cleared copy left the real roster intact")
	transport.inject_server_message(
		{"type": "PlayerJoined", "data": {"player": _player(PLAYER_B, "Bob")}}
	)
	_assert_equal(1, client.get_players().size(), "presence lands on the real roster")
	_assert_equal(PLAYER_B, client.get_players()[0].id, "the joined player is queryable")
	client.free()


func _test_failures_clean_up_and_failed_open_surfaces_reason() -> void:
	var client := SignalFishClientScript.new()
	var failures: Array = []
	client.connection_failed.connect(func(error: String) -> void: failures.append(error))
	_assert_equal(OK, client.configure(_make_config()), "configure")
	var transport: SFFakeTransportScript = SFFakeTransportScript.new()
	client.transport = transport
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	transport.close(4321, "aborted during dial")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		client.get_connection_state(),
		"close during connecting is a failed open"
	)
	var open_failure: String = failures[0]
	_assert_string_contains(open_failure, "aborted during dial", "failed open surfaces reason")
	_assert_equal(null, client.transport, "transport released after failed open")
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		client.get_session_state(),
		"session reset after failed open"
	)
	client.free()

	var drop_client := _make_in_room_client()
	var drop_fake: SFFakeTransportScript = drop_client.transport
	var drop_failures: Array = []
	drop_client.connection_failed.connect(func(error: String) -> void: drop_failures.append(error))
	drop_fake.inject_failure("socket exploded")
	_assert_equal(["socket exploded"], drop_failures, "failure surfaced")
	_assert_equal(
		SignalFishClientScript.ConnectionState.FAILED,
		drop_client.get_connection_state(),
		"failed state"
	)
	_assert_equal(
		SignalFishClientScript.SessionState.UNAUTHENTICATED,
		drop_client.get_session_state(),
		"session reset on failure"
	)
	_assert_equal("", drop_client.get_room_id(), "room cleared on failure")
	_assert_equal(null, drop_client.transport, "transport released on failure")
	drop_client.free()


func _test_frame_cap_drops_oversized_and_binary_frames() -> void:
	var config := _make_config()
	config.max_inbound_frame_bytes = 32
	var client := _connect_new_client(config)
	var fake: SFFakeTransportScript = client.transport
	fake.inject_open()
	fake.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	var errors := _track_protocol_errors(client)
	var big_data := {"type": "GameData", "data": {"from_player": PLAYER_A, "data": "x"}}
	var payload := JSON.stringify(big_data)
	while payload.length() <= 64:
		big_data["data"]["data"] += "x"
		payload = JSON.stringify(big_data)
	fake.inject_text(payload)
	_assert_equal(1, errors.size(), "oversized text frame flagged")
	var oversized_error: String = errors[0]
	_assert_string_contains(oversized_error, "exceeds cap", "oversized frame message")

	fake.inject_binary(PackedByteArray([0, 1, 2]))
	_assert_equal(2, errors.size(), "binary frame flagged pre-negotiation")
	var binary_error: String = errors[1]
	_assert_string_contains(binary_error, "binary frame", "binary frame message")

	fake.inject_server_message({"type": "Pong"})
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTED,
		client.get_connection_state(),
		"client stays connected after dropped frames"
	)
	client.free()


## Issue #92: a repeated envelope key used to silently substitute the decoded
## event (the engine parser is last-wins) — here the smuggled RoomLeft used
## to wipe the in-room session while the server still counted the player as
## joined. The duplicate-key guard fails the frame closed instead: one
## protocol_error, connection and room state untouched.
func _test_duplicate_key_frame_fails_closed() -> void:
	var client := _make_in_room_client()
	var fake: SFFakeTransportScript = client.transport
	var errors := _track_protocol_errors(client)
	fake.inject_text('{"type":"GameData","data":{"from_player":"p1","data":{}},"type":"RoomLeft"}')
	_assert_equal(1, errors.size(), "duplicate key frame flagged")
	var duplicate_error: String = errors[0]
	_assert_string_contains(duplicate_error, "duplicate", "duplicate key message")
	_assert_equal(
		SignalFishClientScript.ConnectionState.CONNECTED,
		client.get_connection_state(),
		"stays connected after duplicate key frame"
	)
	_assert(not client.get_room_id().is_empty(), "room state survives the smuggled RoomLeft")
	_assert_equal(
		SignalFishClientScript.SessionState.IN_ROOM_WAITING,
		client.get_session_state(),
		"session state survives the smuggled RoomLeft"
	)
	client.free()


func _test_mixed_content_guard_is_data_driven() -> void:
	var cases := [
		["ws://x.test", true, true, true, "ws blocked on secure page"],
		["ws://x.test", true, false, false, "ws allowed on insecure page"],
		["ws://x.test", false, true, false, "ws allowed off web"],
		["wss://x.test", true, true, false, "wss always allowed"],
		["WS://x.test", true, true, true, "uppercase ws blocked"],
		["ftp://x.test", false, false, true, "non-websocket scheme rejected"],
	]
	for case_row: Array in cases:
		var case_url: String = case_row[0]
		var case_web_platform: bool = case_row[1]
		var case_secure_page: bool = case_row[2]
		var case_label: String = case_row[4]
		var message: String = SignalFishClientScript.insecure_scheme_error(
			case_url, case_web_platform, case_secure_page
		)
		if case_row[3]:
			_assert(not message.is_empty(), "%s: expected an error" % case_row[4])
		else:
			_assert_equal("", message, case_label)
	var mixed_message: String = SignalFishClientScript.insecure_scheme_error(
		"ws://x.test", true, true
	)
	_assert_string_contains(mixed_message, "mixed content", "mixed-content message names the fix")
	var scheme_message: String = SignalFishClientScript.insecure_scheme_error(
		"ftp://x.test", false, false
	)
	_assert_string_contains(scheme_message, "invalid WebSocket URL scheme", "scheme message")


func _test_log_redaction_and_level_gate() -> void:
	var cases := [
		["token=abc123 ok", PackedStringArray(["abc123"]), "token=[REDACTED] ok"],
		["no secrets", PackedStringArray(), "no secrets"],
		["a b a", PackedStringArray(["a", "b"]), "[REDACTED] [REDACTED] [REDACTED]"],
		["keep empty", PackedStringArray([""]), "keep empty"],
	]
	for case_row: Array in cases:
		var case_text: String = case_row[0]
		var case_secrets: PackedStringArray = case_row[1]
		_assert_equal(case_row[2], SFLogScript.redact(case_text, case_secrets), "redact case")

	var original_level: int = SFLogScript.min_level
	SFLogScript.min_level = SFLogScript.Level.OFF
	SFLogScript.error("suppressed")
	SFLogScript.min_level = original_level
	SFLogScript.debug("debug hidden by default", PackedStringArray(["secret-value"]))
	_assert(true, "log calls do not crash under gates")


func _test_config_to_string_redacts_credential() -> void:
	var config := SignalFishConfigScript.new()
	config.app_id = "test-app"
	config.credential = "sfk_super_secret"
	var text := config.to_string()
	_assert_string_not_contains(text, "sfk_super_secret", "credential never in _to_string")
	_assert_string_contains(text, "test-app", "_to_string keeps public fields")


func _make_config() -> SignalFishConfigScript:
	var config := SignalFishConfigScript.new()
	config.app_id = "test-app"
	config.sdk_version = "0.1.0"
	config.platform = "linux"
	config.game_data_format = "json"
	return config


func _connect_new_client(config: SignalFishConfigScript) -> SignalFishClientScript:
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	_assert_equal(OK, client.configure(config), "configure")
	client.transport = SFFakeTransportScript.new()
	_assert_equal(OK, client.connect_to_server("ws://example.test/socket"), "connect")
	return client


func _make_connected_client() -> SignalFishClientScript:
	var client := _connect_new_client(_make_config())
	var transport: SFFakeTransportScript = client.transport
	transport.inject_open()
	return client


func _make_authenticated_client() -> SignalFishClientScript:
	var client := _make_connected_client()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "Authenticated", "data": _authenticated_data()})
	return client


func _make_in_room_client() -> SignalFishClientScript:
	var client := _make_authenticated_client()
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "RoomJoined", "data": _room_joined_data()})
	return client


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	var errors: Array = []
	client.protocol_error.connect(func(error: String) -> void: errors.append(error))
	return errors


func _send_method_cases() -> Array:
	var params := SignalFishClientScript.JoinRoomParams.new()
	params.game_name = "g"
	params.player_name = "p"
	return [
		[
			"join_room",
			func(client: SignalFishClientScript) -> Error: return client.join_room(params)
		],
		["leave_room", func(client: SignalFishClientScript) -> Error: return client.leave_room()],
		[
			"send_game_data",
			func(client: SignalFishClientScript) -> Error: return client.send_game_data({})
		],
		[
			"send_game_data_binary",
			func(client: SignalFishClientScript) -> Error: return _send_binary_game_data(client)
		],
		["set_ready", func(client: SignalFishClientScript) -> Error: return client.set_ready()],
		["start_game", func(client: SignalFishClientScript) -> Error: return client.start_game()],
		[
			"request_authority",
			func(client: SignalFishClientScript) -> Error: return client.request_authority(true)
		],
		[
			"provide_connection_info",
			func(client: SignalFishClientScript) -> Error: return _send_conn_info(client)
		],
		["ping", func(client: SignalFishClientScript) -> Error: return client.ping()],
		[
			"join_as_spectator",
			func(client: SignalFishClientScript) -> Error: return _join_as_spectator(client)
		],
		[
			"leave_spectator",
			func(client: SignalFishClientScript) -> Error: return client.leave_spectator()
		],
		[
			"send_signal",
			func(client: SignalFishClientScript) -> Error: return _send_signal_fixture(client)
		],
		[
			"send_transport_status",
			func(client: SignalFishClientScript) -> Error: return _send_webrtc_status(client)
		],
	]


func _send_binary_game_data(client: SignalFishClientScript) -> Error:
	return client.send_game_data_binary(PackedByteArray([0x01]))


func _join_as_spectator(client: SignalFishClientScript) -> Error:
	return client.join_as_spectator("g", "ROOM1", "s")


func _send_signal_fixture(client: SignalFishClientScript) -> Error:
	return client.send_signal(PLAYER_B, "gen", {"Offer": "s"})


func _send_webrtc_status(client: SignalFishClientScript) -> Error:
	return client.send_transport_status(SFSessionTypesScript.TransportKind.WEBRTC, true)


func _send_conn_info(client: SignalFishClientScript) -> Error:
	var info := SFTypesScript.ConnectionInfo.new({"type": "custom", "data": {}})
	return client.provide_connection_info(info)


func _authenticated_data() -> Dictionary:
	return ClientFixtures.authenticated_data()


func _protocol_info() -> Dictionary:
	return ClientFixtures.protocol_info()


func _player(id: String, display_name: String) -> Dictionary:
	return ClientFixtures.player(id, display_name)


func _spectator(id: String, display_name: String) -> Dictionary:
	return ClientFixtures.spectator(id, display_name)


func _peer_connection() -> Dictionary:
	return ClientFixtures.peer_connection()


func _room_joined_data(overrides: Dictionary = {}) -> Dictionary:
	return ClientFixtures.room_joined_data(overrides)


class PollCountingTransport:
	extends "res://addons/signal_fish/transport/sf_fake_transport.gd"

	var poll_count := 0

	func poll() -> void:
		poll_count += 1


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append("%s: expected condition to be true" % label)
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


func _assert_string_not_contains(actual: String, substring: String, label: String) -> bool:
	if actual.find(substring) != -1:
		_failures.append(
			"%s: expected %s not to contain %s" % [label, var_to_str(actual), var_to_str(substring)]
		)
		return false
	return true
