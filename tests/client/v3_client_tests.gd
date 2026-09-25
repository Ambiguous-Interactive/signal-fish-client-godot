extends RefCounted

## Protocol v3-era client tests: the session-plan/WebRTC signaling surface and
## the v0.14.0 `connect_token` auth field. Receives the client runner instance
## so connect/auth fakes stay defined in one place.

const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const SFFakeTransportScript = preload("res://addons/signal_fish/transport/sf_fake_transport.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array = []
var _test_done := false
var _runner: Object = null


func _done() -> void:
	_test_done = true


static func run(runner: Variant) -> Array:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_v3_config_advertises_capabilities,
		_test_v3_events_surface,
		_test_v3_send_methods,
		_test_connect_token_reaches_wire,
		_test_encode_boundary_refuses_unserializable_payload,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _make_config() -> SignalFishConfigScript:
	return _runner.call("_make_config")


func _connect_new_client(config: SignalFishConfigScript) -> SignalFishClientScript:
	return _runner.call("_connect_new_client", config)


func _make_authenticated_client() -> SignalFishClientScript:
	return _runner.call("_make_authenticated_client")


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	return _runner.call("_track_protocol_errors", client)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
		var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
		_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
		return false
	return true


func _test_v3_config_advertises_capabilities() -> void:
	var client := SignalFishClientScript.new()
	_track_protocol_errors(client)
	var config := _make_config()
	config.app_id = "test-app"
	config.protocol_version = -1
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "negative version rejected")
	config.protocol_version = 70000
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "oversized version rejected")
	config.protocol_version = 3
	config.supported_transports = PackedStringArray(["relay", "carrier_pigeon"])
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "unknown transport rejected")
	config.supported_transports = PackedStringArray(["relay", "direct", "webrtc"])
	config.supported_topologies = PackedStringArray(["relay", "star"])
	_assert_equal(ERR_INVALID_DATA, client.configure(config), "unknown topology rejected")
	config.supported_topologies = PackedStringArray(["relay", "host", "mesh"])
	config.requested_capabilities = PackedStringArray(["room_operation_ids"])
	_assert_equal(OK, client.configure(config), "v3 capability config accepted")
	client.free()

	var v3_client := _connect_new_client(config)
	var v3_fake: SFFakeTransportScript = v3_client.transport
	v3_fake.inject_open()
	var expected := SFMessagesScript.encode(
		SFMessagesScript.authenticate(
			"test-app",
			"0.1.0",
			"linux",
			"json",
			3,
			["relay", "direct", "webrtc"],
			["relay", "host", "mesh"],
			["room_operation_ids"]
		)
	)
	_assert_equal([expected], v3_client.transport.sent_text, "v3 authenticate bytes")
	v3_client.free()

	var v2_client := _connect_new_client(_make_config())
	var v2_fake: SFFakeTransportScript = v2_client.transport
	v2_fake.inject_open()
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.authenticate("test-app", "0.1.0", "linux", "json")
			)
		],
		v2_client.transport.sent_text,
		"default config keeps v2 authenticate bytes"
	)
	v2_client.free()
	_done()


func _test_v3_events_surface() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var plans: Array = []
	client.session_plan.connect(
		func(plan: SFSessionTypesScript.SessionPlanInfo) -> void: plans.append(plan)
	)
	var new_peers: Array = []
	client.new_peer.connect(
		func(peer_id: String, you_initiate: bool) -> void: new_peers.append([peer_id, you_initiate])
	)
	var signals_in: Array = []
	client.signal_received.connect(
		func(from_player: String, generation: String, payload: Variant) -> void:
			signals_in.append([from_player, generation, payload])
	)
	var statuses: Array = []
	client.peer_transport_status.connect(
		func(peer_id: String, transport: int, connected: bool) -> void:
			statuses.append([peer_id, transport, connected])
	)

	(
		fake
		. inject_server_message(
			{
				"type": "SessionPlan",
				"data":
				{
					"generation": "40000000-0000-0000-0000-000000000001",
					"topology": "mesh",
					"transport": "webrtc",
					"peers":
					[
						{
							"player_id": PLAYER_B,
							"player_name": "Bob",
							"is_authority": false,
							"initiate": true,
						},
					],
					"ice_servers": [{"urls": ["stun:stun.l.google.com:19302"]}],
					"fallback": "relay",
				}
			}
		)
	)
	_assert_equal(1, plans.size(), "session_plan surfaced")
	var first_plan: SFSessionTypesScript.SessionPlanInfo = plans[0]
	_assert_equal(
		"40000000-0000-0000-0000-000000000001", first_plan.generation, "plan generation surfaced"
	)
	_assert_equal(SFSessionTypesScript.Topology.MESH, first_plan.topology, "plan topology surfaced")
	_assert_equal(1, first_plan.peers.size(), "plan peers surfaced")
	_assert_equal(PLAYER_B, first_plan.peers[0].player_id, "plan peer id surfaced")
	_assert_equal(true, first_plan.peers[0].initiate, "plan initiate surfaced")
	_assert_equal(1, first_plan.ice_servers.size(), "plan ice surfaced")

	fake.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": false}}
	)
	_assert_equal(1, new_peers.size(), "new_peer surfaced")
	_assert_equal([PLAYER_B, false], new_peers[0], "new_peer args surfaced")

	(
		fake
		. inject_server_message(
			{
				"type": "Signal",
				"data":
				{
					"from": PLAYER_B,
					"generation": "40000000-0000-0000-0000-000000000001",
					"signal":
					{"IceCandidate": "candidate:1 1 UDP 2130706431 10.0.0.5 54321 typ host"},
				}
			}
		)
	)
	_assert_equal(1, signals_in.size(), "signal_received surfaced")
	_assert_equal(PLAYER_B, signals_in[0][0], "signal from surfaced")
	_assert_equal(
		"40000000-0000-0000-0000-000000000001", signals_in[0][1], "signal generation surfaced"
	)
	_assert_equal(
		"candidate:1 1 UDP 2130706431 10.0.0.5 54321 typ host",
		signals_in[0][2]["IceCandidate"],
		"signal payload round-trips"
	)

	(
		fake
		. inject_server_message(
			{
				"type": "Signal",
				"data": {"from": PLAYER_B, "signal": {"Answer": "v=0"}},
			}
		)
	)
	_assert_equal(2, signals_in.size(), "legacy signal surfaced")
	_assert_equal("", signals_in[1][1], "missing generation is empty string")

	fake.inject_server_message(
		{
			"type": "PeerTransportStatus",
			"data": {"peer_id": PLAYER_B, "transport": "webrtc", "connected": true}
		}
	)
	_assert_equal(1, statuses.size(), "peer_transport_status surfaced")
	_assert_equal(
		[PLAYER_B, SFSessionTypesScript.TransportKind.WEBRTC, true],
		statuses[0],
		"status args surfaced"
	)

	(
		fake
		. inject_server_message(
			{
				"type": "SessionPlan",
				"data":
				{
					"generation": "40000000-0000-0000-0000-000000000002",
					"topology": "relay",
					"transport": "relay",
					"peers": [],
					"fallback": "relay",
				}
			}
		)
	)
	_assert_equal(2, plans.size(), "relay reset plan surfaced")
	var relay_plan: SFSessionTypesScript.SessionPlanInfo = plans[1]
	_assert_equal(0, relay_plan.peers.size(), "relay reset plan has no peers")
	client.free()
	_done()


func _test_v3_send_methods() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var before: int = fake.sent_text.size()
	_assert_equal(
		OK,
		client.send_signal(PLAYER_B, "40000000-0000-0000-0000-000000000001", {"Offer": "v=0"}),
		"send_signal"
	)
	var expected_signal := SFMessagesScript.encode(
		SFMessagesScript.peer_signal(
			PLAYER_B, "40000000-0000-0000-0000-000000000001", {"Offer": "v=0"}
		)
	)
	_assert_equal(expected_signal, fake.sent_text[before], "send_signal wire bytes")

	_assert_equal(
		OK,
		client.send_signal(PLAYER_B, "", {"IceCandidate": "candidate:1"}),
		"legacy empty generation accepted"
	)
	var expected_legacy := SFMessagesScript.encode(
		SFMessagesScript.peer_signal(PLAYER_B, "", {"IceCandidate": "candidate:1"})
	)
	_assert_equal(expected_legacy, fake.sent_text[before + 1], "legacy signal omits generation")

	_assert_equal(
		ERR_INVALID_DATA,
		client.send_signal(PLAYER_B, "40000000-0000-0000-0000-000000000001", null),
		"null signal payload refused locally"
	)
	_assert_equal(
		ERR_INVALID_DATA,
		client.send_signal("", "40000000-0000-0000-0000-000000000001", {"Offer": "s"}),
		"empty peer refused locally"
	)

	_assert_equal(
		OK,
		client.send_transport_status(SFSessionTypesScript.TransportKind.WEBRTC, true),
		"send_transport_status"
	)
	var expected_status := SFMessagesScript.encode(
		SFMessagesScript.transport_status("webrtc", true)
	)
	_assert_equal(expected_status, fake.sent_text[before + 2], "status wire bytes")

	_assert_equal(
		ERR_INVALID_DATA,
		client.send_transport_status(SFSessionTypesScript.TransportKind.UNKNOWN, true),
		"unknown transport refused locally"
	)
	_assert_equal(before + 3, fake.sent_text.size(), "refused sends put nothing on the wire")
	client.free()
	_done()


func _test_connect_token_reaches_wire() -> void:
	# Credential rides Authenticate as the upstream connect_token field (rust SDK 0.14.0, issue #33).
	var config := _make_config()
	config.credential = "sfct_v1.tenant-secret"
	var credentialed := _connect_new_client(config)
	var credentialed_fake: SFFakeTransportScript = credentialed.transport
	credentialed_fake.inject_open()
	var expected := SFMessagesScript.encode(
		SFMessagesScript.authenticate(
			"test-app", "0.1.0", "linux", "json", null, null, null, null, "sfct_v1.tenant-secret"
		)
	)
	_assert_equal([expected], credentialed.transport.sent_text, "credential rides connect_token")
	credentialed.free()

	var anonymous := _connect_new_client(_make_config())
	var anonymous_fake: SFFakeTransportScript = anonymous.transport
	anonymous_fake.inject_open()
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.authenticate("test-app", "0.1.0", "linux", "json")
			)
		],
		anonymous.transport.sent_text,
		"unset credential keeps authenticate bytes unchanged"
	)
	anonymous.free()

	var wrong_type := SFMessagesScript.authenticate(
		"a", null, null, null, null, null, null, null, 5
	)
	_assert_equal(false, SFMessagesScript.is_valid_message(wrong_type), "non-string token refused")
	_assert_string_contains(
		SFMessagesScript.validation_error(wrong_type), "connect_token", "error names the field"
	)
	_done()


## Issue #76: the encode boundary is the last-resort JSON-shape net. A
## payload that skips the builder whitelist (ConnectionInfo.custom.data)
## must surface as ERR_INVALID_DATA + protocol_error with nothing on the
## wire — never as an empty text frame.


func _test_encode_boundary_refuses_unserializable_payload() -> void:
	var client := _make_authenticated_client()
	var fake: SFFakeTransportScript = client.transport
	var errors: Array = _track_protocol_errors(client)
	var info: SFTypesScript.ConnectionInfo = SFTypesScript.ConnectionInfo.new(
		{"type": "custom", "data": {"deep": Vector2(1, 2)}}
	)
	var baseline: int = fake.sent_text.size()
	_assert_equal(
		ERR_INVALID_DATA, client.provide_connection_info(info), "unserializable custom data refused"
	)
	_assert_equal(baseline, fake.sent_text.size(), "refused payload sends nothing")
	_assert_equal(1, errors.size(), "boundary refusal emits one protocol_error")
	_assert_string_contains(
		str(errors[0]), "not losslessly JSON-representable", "protocol_error names the cause"
	)
	var stringy := SFTypesScript.ConnectionInfo.new({"type": "custom", "data": {"deep": "ok"}})
	_assert_equal(OK, client.provide_connection_info(stringy), "JSON custom data accepted")
	_assert_equal(baseline + 1, fake.sent_text.size(), "accepted payload sends exactly one frame")
	client.free()
	_done()


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
