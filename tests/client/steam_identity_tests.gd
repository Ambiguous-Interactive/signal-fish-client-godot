extends RefCounted

## Steam identity bootstrap tests (issue #312). Deterministic: the Steam seam
## is an injected fake (the GodotSteam GDExtension never runs in fast gates),
## time is injected `_process` delta, and the room rides the shared fake
## transport. Receives the client runner instance so connect/auth fakes stay
## defined in one place.

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFSteamIdentityScript = preload("res://addons/signal_fish/steam/sf_steam_identity.gd")
const SFSteamIdentityBootstrapScript = preload(
	"res://addons/signal_fish/steam/sf_steam_identity_bootstrap.gd"
)
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const HOST_ID := "76561197960265728"
const PEER_ID := "76561197960265736"
const OTHER_ID := "76561197960265744"

var _failures: Array[String] = []
var _test_done := false
var _runner: Object = null


func _done() -> void:
	_test_done = true


static func run(runner: Object) -> Array[String]:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_steam_id_validation,
		_test_envelope_round_trip_and_role_scoping,
		_test_lane_reads_absent_on_foreign_payloads,
		_test_attach_and_start_guards,
		_test_host_publishes_and_republishes,
		_test_peer_publishes_on_join,
		_test_host_fence_accepts_advertised_peer,
		_test_host_fence_grace_expiry_refuses,
		_test_host_fence_zero_grace_refuses_immediately,
		_test_host_fence_late_advertisement_accepts,
		_test_peer_consumes_host_id_and_connects,
		_test_peer_host_id_change_fails,
		_test_peer_dial_fail_fails_coordination,
		_test_peer_dial_and_host_id_timeouts,
		_test_authority_loss_fails_host,
		_test_room_loss_fails_coordination,
		_test_pending_requests_close_on_teardown,
		_test_accept_failure_closes_requester,
		_test_session_drop_detection,
		_test_requests_while_not_hosting_refused,
		_test_stop_closes_sessions,
		_test_host_id_wait_closes_on_arrival,
		_test_duplicate_room_baseline_does_not_rearm,
		_test_stop_inside_signal_silences_followups,
		_test_restart_after_failure_rewires,
		_test_connecting_session_never_drops,
		_test_host_republishes_on_peer_advertisement,
		_test_freed_client_tears_down,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _test_steam_id_validation() -> void:
	var valid: Array[String] = [
		"1",
		"9",
		"10",
		HOST_ID,
		"12345678901234567890",
		"99999999999999999999",
	]
	for steam_id: String in valid:
		_assert(SFSteamIdentityScript.is_valid_steam_id(steam_id), "valid %s" % steam_id)
	var invalid: Array[String] = [
		"",
		"0",
		"01",
		"007",
		"12a",
		"1.5",
		"1e5",
		"+12",
		"-12",
		" 1",
		"1 ",
		"123456789012345678901",
		"12\n",
		"abcd",
	]
	for steam_id: String in invalid:
		_assert(not SFSteamIdentityScript.is_valid_steam_id(steam_id), "invalid %s" % steam_id)
	_done()


func _test_envelope_round_trip_and_role_scoping() -> void:
	var host_envelope := SFSteamIdentityScript.host_envelope(HOST_ID)
	_assert_equal(
		{SFSteamIdentityScript.HOST_LANE_KEY: HOST_ID}, host_envelope, "host envelope shape"
	)
	_assert_equal(HOST_ID, SFSteamIdentityScript.read_host(host_envelope), "host read")
	_assert_equal("", SFSteamIdentityScript.read_peer(host_envelope), "host not on peer lane")
	var peer_envelope := SFSteamIdentityScript.peer_envelope(PEER_ID)
	_assert_equal(
		{SFSteamIdentityScript.PEER_LANE_KEY: PEER_ID}, peer_envelope, "peer envelope shape"
	)
	_assert_equal(PEER_ID, SFSteamIdentityScript.read_peer(peer_envelope), "peer read")
	_assert_equal("", SFSteamIdentityScript.read_host(peer_envelope), "peer not on host lane")
	_assert_equal({}, SFSteamIdentityScript.host_envelope("01"), "leading zero refused")
	_assert_equal({}, SFSteamIdentityScript.peer_envelope(""), "empty id refused")
	_done()


func _test_lane_reads_absent_on_foreign_payloads() -> void:
	var absent: Array[Variant] = [
		null,
		42,
		"str",
		[],
		{},
		{"game": {"score": 1}},
		{SFSteamIdentityScript.HOST_LANE_KEY: 123},
		{SFSteamIdentityScript.HOST_LANE_KEY: ""},
		{SFSteamIdentityScript.HOST_LANE_KEY: "01"},
		{SFSteamIdentityScript.HOST_LANE_KEY: true},
		{SFSteamIdentityScript.PEER_LANE_KEY: 1.5},
	]
	for payload: Variant in absent:
		_assert_equal("", SFSteamIdentityScript.read_host(payload), "host absent %s" % [payload])
		_assert_equal("", SFSteamIdentityScript.read_peer(payload), "peer absent %s" % [payload])
	var mixed := {"game": {"score": 1}, SFSteamIdentityScript.PEER_LANE_KEY: PEER_ID}
	_assert_equal(PEER_ID, SFSteamIdentityScript.read_peer(mixed), "id next to game fields")
	_done()


func _test_attach_and_start_guards() -> void:
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, HOST_ID
	)
	_assert_equal(ERR_INVALID_PARAMETER, bootstrap.attach(null), "attach(null) refused")
	_assert_equal(ERR_INVALID_PARAMETER, bootstrap.start(), "start before attach")
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(ERR_BUSY, bootstrap.attach(client), "double attach refused")
	bootstrap.steam = RefCounted.new()
	_assert_equal(ERR_UNAVAILABLE, bootstrap.start(), "steam without the seam surface")
	_assert_equal(false, bootstrap.is_coordinating(), "failed start does not coordinate")
	bootstrap.steam = FakeSteam.new(HOST_ID)
	bootstrap.accept_grace_sec = -1.0
	_assert_equal(ERR_INVALID_PARAMETER, bootstrap.start(), "negative grace refused")
	bootstrap.accept_grace_sec = 5.0
	_assert_equal(OK, bootstrap.start(), "start")
	_assert_equal(true, bootstrap.is_coordinating(), "coordinating after start")
	_assert_equal(ERR_BUSY, bootstrap.start(), "double start refused")
	bootstrap.detach()
	_assert_equal(false, bootstrap.is_coordinating(), "detach stops coordination")
	_assert_equal(ERR_INVALID_PARAMETER, bootstrap.attach(null), "attach(null) refused")
	bootstrap.detach()
	bootstrap.free()
	client.free()
	_done()


func _test_host_publishes_and_republishes() -> void:
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_assert_equal(
		SFSteamIdentityScript.host_envelope(HOST_ID),
		_last_game_data_payload(client),
		"host id published on start"
	)
	_join_player(client, PLAYER_B)
	_assert_equal(
		SFSteamIdentityScript.host_envelope(HOST_ID),
		_last_game_data_payload(client),
		"host id re-published on join"
	)
	_assert_equal(2, _game_data_send_count(client), "exactly two publishes")
	bootstrap.free()
	client.free()
	_done()


func _test_peer_publishes_on_join() -> void:
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_assert_equal(
		SFSteamIdentityScript.peer_envelope(PEER_ID),
		_last_game_data_payload(client),
		"peer id published on start"
	)
	_join_player(client, PLAYER_B)
	_assert_equal(2, _game_data_send_count(client), "re-published on join")
	bootstrap.free()
	client.free()
	_done()


func _test_host_fence_accepts_advertised_peer() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	steam.request_session(int(PEER_ID))
	_assert_equal([], steam.accepts, "unknown requester waits in the grace window")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_assert_equal([int(PEER_ID)], steam.accepts, "advertisement opens the fence")
	_assert_equal([PEER_ID], _captured(bootstrap, "steam_peer_connected"), "connected signal")
	_assert_equal(1, steam.sends.size(), "handshake reply sent")
	var reply: Dictionary = steam.sends[0]
	_assert_equal(int(PEER_ID), reply["remote"], "reply remote")
	_assert_equal(PackedByteArray([0x41]), reply["data"], "reply payload")
	_assert_equal(2, reply["send_type"], "reply reliable")
	_assert_equal(1, reply["channel"], "reply bootstrap channel")
	bootstrap.free()
	client.free()
	_done()


func _test_host_fence_grace_expiry_refuses() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	bootstrap.accept_grace_sec = 5.0
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	steam.request_session(int(PEER_ID))
	bootstrap._process(4.9)
	_assert_equal([], steam.closes, "inside the grace window the session waits")
	bootstrap._process(0.2)
	_assert_equal([int(PEER_ID)], steam.closes, "expired requester refused")
	_assert_equal([], _captured(bootstrap, "steam_peer_connected"), "no connect signal")
	bootstrap.free()
	client.free()
	_done()


func _test_host_fence_zero_grace_refuses_immediately() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	bootstrap.accept_grace_sec = 0.0
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	steam.request_session(int(PEER_ID))
	_assert_equal([int(PEER_ID)], steam.closes, "zero grace refuses on the spot")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_assert_equal([int(PEER_ID)], steam.closes, "advertisement after refusal does not resurrect")
	_assert_equal([], steam.accepts, "no accept")
	bootstrap.free()
	client.free()
	_done()


func _test_host_fence_late_advertisement_accepts() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	bootstrap.accept_grace_sec = 5.0
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	steam.request_session(int(PEER_ID))
	bootstrap._process(2.0)
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_assert_equal([int(PEER_ID)], steam.accepts, "late advertisement still opens the fence")
	_assert_equal([], steam.closes, "nothing refused")
	bootstrap.free()
	client.free()
	_done()


func _test_peer_consumes_host_id_and_connects() -> void:
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	bootstrap.steam_connect_timeout_sec = 10.0
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_host(client, PLAYER_A, HOST_ID)
	_assert_equal([HOST_ID], _captured(bootstrap, "steam_host_id_received"), "host id signal")
	_assert_equal(HOST_ID, bootstrap.get_host_steam_id(), "host id diagnostic")
	_assert_equal(1, steam.sends.size(), "dial poke sent")
	var poke: Dictionary = steam.sends[0]
	_assert_equal(int(HOST_ID), poke["remote"], "poke remote")
	_assert_equal(PackedByteArray([0x53]), poke["data"], "poke payload")
	_assert_equal(2, poke["send_type"], "poke reliable")
	_assert_equal(1, poke["channel"], "poke bootstrap channel")
	steam.queue_packet(int(HOST_ID), PackedByteArray([0x41]))
	bootstrap.poll()
	_assert_equal([HOST_ID], _captured(bootstrap, "steam_host_connected"), "connected on ack")
	# A repeat host publish is a re-publish, not a change: nothing new fires.
	_advertise_host(client, PLAYER_A, HOST_ID)
	_assert_equal(1, _captured(bootstrap, "steam_host_id_received").size(), "repeat id silent")
	bootstrap.free()
	client.free()
	_done()


func _test_peer_host_id_change_fails() -> void:
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_host(client, PLAYER_A, HOST_ID)
	_advertise_host(client, PLAYER_A, OTHER_ID)
	_assert_equal(
		["the published host id changed mid-session"],
		_captured(bootstrap, "coordination_failed"),
		"host id change fails the coordination"
	)
	_assert_equal(false, bootstrap.is_coordinating(), "coordination stopped")
	_assert_equal([int(HOST_ID)], steam.closes, "the dial is closed")
	bootstrap.free()
	client.free()
	_done()


func _test_peer_dial_fail_fails_coordination() -> void:
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_host(client, PLAYER_A, HOST_ID)
	steam.fail_session(int(HOST_ID), 4)
	_assert_equal(
		["the Steam dial failed (session error 4)"],
		_captured(bootstrap, "coordination_failed"),
		"connect fail surfaces the session error"
	)
	bootstrap.free()
	client.free()
	_done()


func _test_peer_dial_and_host_id_timeouts() -> void:
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	bootstrap.host_id_timeout_sec = 10.0
	bootstrap.steam_connect_timeout_sec = 10.0
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	bootstrap._process(10.1)
	_assert_equal(
		["the host id did not arrive in time"],
		_captured(bootstrap, "coordination_failed"),
		"host id wait times out"
	)
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(PEER_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam)
	bootstrap.steam_connect_timeout_sec = 10.0
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	_advertise_host(client, PLAYER_A, HOST_ID)
	bootstrap._process(10.1)
	_assert_equal(
		["the Steam dial timed out"],
		_captured(bootstrap, "coordination_failed"),
		"ack wait times out"
	)
	_assert_equal([int(HOST_ID)], steam.closes, "timed-out dial closed")
	bootstrap.free()
	client.free()
	_done()


func _test_authority_loss_fails_host() -> void:
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message(
		{
			"type": "AuthorityChanged",
			"data": {"authority_player": PLAYER_B, "you_are_authority": false}
		}
	)
	client.poll()
	_assert_equal(
		["authority left the host; the fence has no holder"],
		_captured(bootstrap, "coordination_failed"),
		"authority loss fails the host"
	)
	_assert_equal(false, bootstrap.is_coordinating(), "coordination stopped")
	bootstrap.free()
	client.free()
	_done()


func _test_room_loss_fails_coordination() -> void:
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "RoomLeft", "data": {}})
	client.poll()
	_assert_equal(
		["the room session ended"],
		_captured(bootstrap, "coordination_failed"),
		"room left fails the coordination"
	)
	bootstrap.free()
	client.free()

	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	transport = client.transport
	transport.inject_open()
	client.close(1000, "done")
	client.poll()
	_assert_equal(
		["the room connection closed"],
		_captured(bootstrap, "coordination_failed"),
		"link loss fails the coordination"
	)
	bootstrap.free()
	client.free()
	_done()


func _test_pending_requests_close_on_teardown() -> void:
	# Parity: a fence request that was neither accepted nor refused still
	# opened a Steam session; once the coordination stops nobody owns it, so
	# every teardown path closes it (the dotnet adapter's teardown does).
	# An established session stays with the game on a failure.
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	steam.request_session(int(OTHER_ID))
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message(
		{
			"type": "AuthorityChanged",
			"data": {"authority_player": PLAYER_B, "you_are_authority": false}
		}
	)
	client.poll()
	_assert_equal(
		["authority left the host; the fence has no holder"],
		_captured(bootstrap, "coordination_failed"),
		"authority loss fails the host"
	)
	_assert_equal(
		[int(OTHER_ID)], steam.closes, "failure closes the pending requester, keeps the fenced peer"
	)
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(HOST_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	steam.request_session(int(OTHER_ID))
	bootstrap.stop()
	_assert_equal([int(OTHER_ID)], steam.closes, "stop closes the pending requester")
	bootstrap.free()
	client.free()
	_done()


func _test_accept_failure_closes_requester() -> void:
	# Parity: a refused accept leaves the poke's Steam session unowned; it
	# closes on the spot (the dotnet adapter's accept path does the same).
	var steam := FakeSteam.new(HOST_ID)
	steam.accept_result = false
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	_assert_equal([int(PEER_ID)], steam.closes, "failed accept closes the poke session")
	_assert_equal([], _captured(bootstrap, "steam_peer_connected"), "no connect signal")
	_assert_equal([], steam.sends, "no handshake reply")
	bootstrap.free()
	client.free()
	_done()


func _test_session_drop_detection() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	_assert_equal([int(PEER_ID)], steam.accepts, "fenced")
	bootstrap.poll()
	steam.set_session_active(int(PEER_ID), false)
	bootstrap.poll()
	_assert_equal([PEER_ID], _captured(bootstrap, "steam_peer_disconnected"), "drop reported")
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(PEER_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	_advertise_host(client, PLAYER_A, HOST_ID)
	steam.queue_packet(int(HOST_ID), PackedByteArray([0x41]))
	bootstrap.poll()
	_assert_equal([HOST_ID], _captured(bootstrap, "steam_host_connected"), "connected 2")
	steam.set_session_active(int(HOST_ID), false)
	bootstrap.poll()
	_assert_equal(
		["the host Steam session closed"],
		_captured(bootstrap, "coordination_failed"),
		"host drop fails the peer"
	)
	bootstrap.free()
	client.free()
	_done()


func _test_requests_while_not_hosting_refused() -> void:
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	steam.request_session(int(OTHER_ID))
	_assert_equal([int(OTHER_ID)], steam.closes, "a peer role refuses dialed sessions")
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(HOST_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	bootstrap.stop()
	steam.request_session(int(OTHER_ID))
	_assert_equal([], steam.accepts, "a stopped host hears no session requests")
	_assert_equal([], _captured(bootstrap, "steam_peer_connected"), "no signals after stop")
	bootstrap.free()
	client.free()
	_done()


func _test_stop_closes_sessions() -> void:
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	bootstrap.stop()
	_assert_equal([int(PEER_ID)], steam.closes, "stop closes fenced sessions")
	_assert_equal(false, bootstrap.is_coordinating(), "stop ends coordination")
	_assert_equal("", bootstrap.get_local_steam_id(), "state cleared")
	bootstrap.free()
	client.free()
	_done()


func _test_host_id_wait_closes_on_arrival() -> void:
	# Regression: the armed host-id wait must close when the id arrives, or
	# every default-config peer session dies at the deadline (adversarial
	# review, session 170).
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	bootstrap._process(1.0)
	_advertise_host(client, PLAYER_A, HOST_ID)
	steam.queue_packet(int(HOST_ID), PackedByteArray([0x41]))
	bootstrap.poll()
	_assert_equal([HOST_ID], _captured(bootstrap, "steam_host_connected"), "connected")
	bootstrap._process(31.0)
	_assert_equal([], _captured(bootstrap, "coordination_failed"), "no spurious failure")
	_assert_equal(true, bootstrap.is_coordinating(), "session survives the deadline")
	bootstrap.free()
	client.free()
	_done()


func _test_duplicate_room_baseline_does_not_rearm() -> void:
	# Regression: the client re-emits room_joined on every RoomJoined
	# baseline (issue #107); a duplicate must not re-arm or slide the
	# host-id wait, before or after the id arrives.
	var steam := FakeSteam.new(PEER_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	var transport: SFFakeTransportScript = client.transport
	var baseline: Dictionary = _runner.call("_room_joined_data")
	# A duplicate baseline while the id is still pending must not slide the
	# deadline: the wait fails at 30 s, not at 30 s from the last baseline.
	bootstrap._process(10.0)
	transport.inject_server_message({"type": "RoomJoined", "data": baseline})
	client.poll()
	bootstrap._process(19.9)
	_assert_equal([], _captured(bootstrap, "coordination_failed"), "alive inside the window")
	bootstrap._process(0.2)
	_assert_equal(
		["the host id did not arrive in time"],
		_captured(bootstrap, "coordination_failed"),
		"deadline held at the first baseline"
	)
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(PEER_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.PEER, PEER_ID, steam)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	_advertise_host(client, PLAYER_A, HOST_ID)
	steam.queue_packet(int(HOST_ID), PackedByteArray([0x41]))
	bootstrap.poll()
	transport = client.transport
	baseline = _runner.call("_room_joined_data")
	transport.inject_server_message({"type": "RoomJoined", "data": baseline})
	client.poll()
	bootstrap._process(31.0)
	_assert_equal([], _captured(bootstrap, "coordination_failed"), "no re-armed wait")
	_assert_equal(true, bootstrap.is_coordinating(), "session survives the baseline")
	bootstrap.free()
	client.free()
	_done()


func _test_stop_inside_signal_silences_followups() -> void:
	# Regression: stop() inside a signal handler must silence the signals
	# that would still fire in the same pump (adversarial review, session 170).
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_advertise_peer(client, PLAYER_B, OTHER_ID)
	steam.request_session(int(PEER_ID))
	steam.request_session(int(OTHER_ID))
	bootstrap.steam_peer_disconnected.connect(func(_steam_id: String) -> void: bootstrap.stop())
	bootstrap.poll()
	steam.set_session_active(int(PEER_ID), false)
	steam.set_session_active(int(OTHER_ID), false)
	bootstrap.poll()
	_assert_equal(1, _captured(bootstrap, "steam_peer_disconnected").size(), "one report")
	_assert_equal(false, bootstrap.is_coordinating(), "the handler stopped it")
	bootstrap.free()
	client.free()
	_done()


func _test_restart_after_failure_rewires() -> void:
	# After a failure the Steam listeners must be gone (a zombie listener
	# would answer requests and the next start() would double-connect).
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message({"type": "RoomLeft", "data": {}})
	client.poll()
	_assert_equal(1, _captured(bootstrap, "coordination_failed").size(), "failed")
	steam.request_session(int(OTHER_ID))
	_assert_equal([], steam.closes, "no zombie listener answers after failure")
	bootstrap.accept_grace_sec = 0.0
	_assert_equal(OK, bootstrap.start(), "restart")
	_assert_equal(true, bootstrap.is_coordinating(), "coordinating again")
	steam.request_session(int(OTHER_ID))
	_assert_equal(1, steam.closes.size(), "listener rewired")
	bootstrap.free()
	client.free()
	_done()


func _test_connecting_session_never_drops() -> void:
	# Bugbot: Steam reports a just-accepted session as connecting/inactive
	# while it sets the channel up; that setup must never read as a drop,
	# and only a session seen active (or failed by Steam) can drop.
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	_assert_equal([PEER_ID], _captured(bootstrap, "steam_peer_connected"), "fenced")
	steam.set_session(int(PEER_ID), false, true)
	bootstrap.poll()
	_assert_equal([], _captured(bootstrap, "steam_peer_disconnected"), "setup is not a drop")
	steam.set_session(int(PEER_ID), true, false)
	bootstrap.poll()
	steam.set_session(int(PEER_ID), false, false)
	bootstrap.poll()
	_assert_equal([PEER_ID], _captured(bootstrap, "steam_peer_disconnected"), "seen-active drop")
	bootstrap.free()
	client.free()

	steam = FakeSteam.new(HOST_ID)
	bootstrap = _make_bootstrap(SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam)
	client = _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach 2")
	_assert_equal(OK, bootstrap.start(), "start 2")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	steam.request_session(int(PEER_ID))
	steam.set_session(int(PEER_ID), false, false)
	bootstrap.poll()
	_assert_equal(
		[],
		_captured(bootstrap, "steam_peer_disconnected"),
		"never-active waits for Steam's verdict"
	)
	steam.fail_session(int(PEER_ID), 4)
	_assert_equal(
		[PEER_ID],
		_captured(bootstrap, "steam_peer_disconnected"),
		"Steam's connect fail drops the peer"
	)
	bootstrap.free()
	client.free()
	_done()


func _test_host_republishes_on_peer_advertisement() -> void:
	# Bugbot: a peer that starts coordinating after the host's publish never
	# sees a join-triggered re-publish; the advertisement must close that gap.
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	_assert_equal(1, _game_data_send_count(client), "one publish so far")
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_assert_equal(2, _game_data_send_count(client), "advertisement re-publishes")
	_assert_equal(
		SFSteamIdentityScript.host_envelope(HOST_ID),
		_last_game_data_payload(client),
		"the re-publish carries the host id"
	)
	_advertise_peer(client, PLAYER_B, PEER_ID)
	_assert_equal(2, _game_data_send_count(client), "repeat advertisement is silent")
	bootstrap.free()
	client.free()
	_done()


func _test_freed_client_tears_down() -> void:
	# Bugbot: a freed client must not leave Steam listeners armed; the
	# coordination fails loudly and detach() still stops the bootstrap.
	var steam := FakeSteam.new(HOST_ID)
	var bootstrap: SFSteamIdentityBootstrapScript = _make_bootstrap(
		SFSteamIdentityBootstrapScript.Role.HOST, HOST_ID, steam
	)
	var client := _in_room_client()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(OK, bootstrap.start(), "start")
	client.free()
	bootstrap.poll()
	_assert_equal(
		["the attached client vanished"],
		_captured(bootstrap, "coordination_failed"),
		"vanished client fails the coordination"
	)
	steam.request_session(int(OTHER_ID))
	_assert_equal([], steam.closes, "no listener answers after the client vanished")
	bootstrap.free()
	_done()


func _make_bootstrap(
	role: SFSteamIdentityBootstrapScript.Role, local_id: String, seam: FakeSteam = null
) -> SFSteamIdentityBootstrapScript:
	var bootstrap: SFSteamIdentityBootstrapScript = SFSteamIdentityBootstrapScript.new()
	bootstrap.role = role
	bootstrap.steam = seam if seam != null else FakeSteam.new(local_id)
	for signal_name: String in [
		"steam_host_id_received",
		"steam_host_connected",
		"steam_peer_connected",
		"steam_peer_disconnected",
		"coordination_failed",
	]:
		var captured: Array[String] = []
		bootstrap.connect(signal_name, func(value: String) -> void: captured.append(value))
		bootstrap.set_meta(signal_name, captured)
	return bootstrap


func _captured(bootstrap: SFSteamIdentityBootstrapScript, signal_name: String) -> Array[String]:
	return bootstrap.get_meta(signal_name)


func _in_room_client() -> SignalFishClientScript:
	return _runner.call("_make_in_room_client")


func _advertise_host(client: SignalFishClientScript, from_player: String, host_id: String) -> void:
	_inject_game_data(client, from_player, SFSteamIdentityScript.host_envelope(host_id))


func _advertise_peer(client: SignalFishClientScript, from_player: String, peer_id: String) -> void:
	_inject_game_data(client, from_player, SFSteamIdentityScript.peer_envelope(peer_id))


func _inject_game_data(
	client: SignalFishClientScript, from_player: String, payload: Dictionary
) -> void:
	var transport: SFFakeTransportScript = client.transport
	transport.inject_server_message(
		{"type": "GameData", "data": {"from_player": from_player, "data": payload}}
	)
	client.poll()


func _join_player(client: SignalFishClientScript, player_id: String) -> void:
	var transport: SFFakeTransportScript = client.transport
	(
		transport
		. inject_server_message(
			{
				"type": "PlayerJoined",
				"data": {"player": _runner.call("_player", player_id, "P")},
			}
		)
	)
	client.poll()


func _game_data_send_count(client: SignalFishClientScript) -> int:
	var transport: SFFakeTransportScript = client.transport
	var count := 0
	for text: String in transport.sent_text:
		var envelope: Dictionary = JSON.parse_string(text)
		if envelope.get("type") == "GameData":
			count += 1
	return count


func _last_game_data_payload(client: SignalFishClientScript) -> Dictionary:
	var transport: SFFakeTransportScript = client.transport
	var sent: String = transport.sent_text.back()
	var envelope: Dictionary = JSON.parse_string(sent)
	var data: Dictionary = envelope["data"]
	return data["data"]


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


class FakeSteam:
	extends RefCounted

	## Duck-typed GodotSteam seam: records calls, queues handshake packets,
	## and simulates the session lifetime Steam implies (a poke or an accept
	## makes a session active; a close ends it).

	signal p2p_session_request(remote_steam_id: int)
	signal p2p_session_connect_fail(remote_steam_id: int, session_error: int)

	var local_id: int
	var sends: Array[Dictionary] = []
	var accepts: Array[int] = []
	var closes: Array[int] = []
	var queue: Array[Dictionary] = []
	var session_states: Dictionary = {}
	var send_result := true
	var accept_result := true

	func _init(id: String) -> void:
		local_id = int(id)

	# gdlint: disable=function-name
	func getSteamID() -> int:
		return local_id

	func sendP2PPacket(
		remote_steam_id: int, data: PackedByteArray, send_type: int, channel: int
	) -> bool:
		(
			sends
			. append(
				{
					"remote": remote_steam_id,
					"data": data,
					"send_type": send_type,
					"channel": channel,
				}
			)
		)
		set_session_active(remote_steam_id, true)
		return send_result

	func acceptP2PSessionWithUser(remote_steam_id: int) -> bool:
		accepts.append(remote_steam_id)
		set_session_active(remote_steam_id, accept_result)
		return accept_result

	func closeP2PSessionWithUser(remote_steam_id: int) -> bool:
		closes.append(remote_steam_id)
		set_session_active(remote_steam_id, false)
		return true

	func getAvailableP2PPacketSize(_channel: int) -> int:
		return queue.size()

	func readP2PPacket(_packet_size: int, _channel: int) -> Dictionary:
		if queue.is_empty():
			return {}
		return queue.pop_front()

	func getP2PSessionState(remote_steam_id: int) -> Dictionary:
		if not session_states.has(remote_steam_id):
			return {}
		var entry: Dictionary = session_states[remote_steam_id]
		return {"connection_active": entry["active"], "connecting": entry["connecting"]}

	func set_session(remote_steam_id: int, active: bool, connecting: bool) -> void:
		session_states[remote_steam_id] = {"active": active, "connecting": connecting}

	func set_session_active(remote_steam_id: int, active: bool) -> void:
		set_session(remote_steam_id, active, false)

	func request_session(remote_steam_id: int) -> void:
		set_session_active(remote_steam_id, true)
		p2p_session_request.emit(remote_steam_id)

	func fail_session(remote_steam_id: int, session_error: int) -> void:
		p2p_session_connect_fail.emit(remote_steam_id, session_error)

	func queue_packet(remote_steam_id: int, data: PackedByteArray) -> void:
		queue.append({"data": data, "remote_steam_id": remote_steam_id})
	# gdlint: enable=function-name
