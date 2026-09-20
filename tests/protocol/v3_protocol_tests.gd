extends RefCounted

## Protocol v3 (session-plan/WebRTC signaling) codec tests. Kept as a helper
## suite (same shape as protocol_hardening_tests.gd) so the fixture runner
## stays within the project's max-file-lines lint.

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

const V3_CLIENT_FIXTURE := "res://tests/fixtures/v3_client_messages.jsonl"
const V3_SERVER_FIXTURE := "res://tests/fixtures/v3_server_messages.jsonl"

var _failures: Array = []


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_v3_client_encoders_match_fixtures()
	_test_v3_server_decoders_match_fixtures()
	_test_v3_validation_and_sentinels()


func _test_v3_client_encoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(V3_CLIENT_FIXTURE)
	if not _assert_fixture_count(5, lines, V3_CLIENT_FIXTURE):
		return
	var built := [
		SFMessagesScript.authenticate(
			"mb_app_fixture",
			"0.1.0-godot",
			"godot",
			"json",
			3,
			["relay", "direct", "webrtc"],
			["relay", "host", "mesh"],
			["room_operation_ids"]
		),
		SFMessagesScript.peer_signal(
			"30000000-0000-0000-0000-000000000001",
			"40000000-0000-0000-0000-000000000001",
			{"Offer": "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=signal-fish-fixture\r\n"}
		),
		SFMessagesScript.peer_signal(
			"30000000-0000-0000-0000-000000000001",
			"40000000-0000-0000-0000-000000000001",
			{"IceCandidate": "candidate:1 1 UDP 2130706431 10.0.0.5 54321 typ host"}
		),
		SFMessagesScript.transport_status("webrtc", true),
		SFMessagesScript.transport_status(SFSessionTypesScript.TransportKind.RELAY, false),
	]
	if not _assert_equal(lines.size(), built.size(), "v3 client fixture builder count"):
		return
	for index: int in lines.size():
		var encoded := SFEnvelopeScript.encode(built[index])
		_assert_equal(lines[index], encoded, "%s line %d" % [V3_CLIENT_FIXTURE, index + 1])


func _test_v3_server_decoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(V3_SERVER_FIXTURE)
	if not _assert_fixture_count(9, lines, V3_SERVER_FIXTURE):
		return
	var expected_signals := [
		"session_plan",
		"session_plan",
		"session_plan",
		"session_plan",
		"new_peer",
		"signal_received",
		"peer_transport_status",
		"room_joined",
		"protocol_info",
	]
	var expected_arg_counts := [1, 1, 1, 1, 2, 3, 3, 1, 1]
	if not _assert_equal(lines.size(), expected_signals.size(), "v3 expected signal count"):
		return
	var decoded_events: Array = []
	var failures_before_fixture_shape_checks := _failures.size()
	for index: int in lines.size():
		var decoded := SFEventsScript.decode_text(lines[index])
		decoded_events.append(decoded)
		if not _assert_decoded_signal(
			expected_signals[index], decoded, "%s line %d" % [V3_SERVER_FIXTURE, index + 1]
		):
			continue
		_assert_equal(
			expected_arg_counts[index],
			decoded.args.size(),
			"%s line %d arg count" % [V3_SERVER_FIXTURE, index + 1]
		)
	if _failures.size() != failures_before_fixture_shape_checks:
		return

	# Line 1: mesh + webrtc plan with two peers and STUN/TURN ICE.
	var mesh_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[0].args[0]
	_assert_equal(
		"40000000-0000-0000-0000-000000000001", mesh_plan.generation, "mesh plan generation"
	)
	_assert_equal(SFSessionTypesScript.Topology.MESH, mesh_plan.topology, "mesh plan topology")
	_assert_equal(
		SFSessionTypesScript.TransportKind.WEBRTC, mesh_plan.transport, "mesh plan transport"
	)
	_assert_equal(
		SFSessionTypesScript.TransportKind.RELAY, mesh_plan.fallback, "mesh plan fallback"
	)
	_assert_equal("", mesh_plan.host, "mesh plan has no host")
	_assert_equal(null, mesh_plan.direct_endpoint, "mesh plan has no direct endpoint")
	_assert_equal(2, mesh_plan.peers.size(), "mesh plan peer count")
	_assert_equal(
		"30000000-0000-0000-0000-000000000001", mesh_plan.peers[0].player_id, "mesh peer id"
	)
	_assert_equal("Alice", mesh_plan.peers[0].player_name, "mesh peer name")
	_assert_equal(true, mesh_plan.peers[0].is_authority, "mesh peer authority")
	_assert_equal(true, mesh_plan.peers[0].initiate, "mesh peer initiate flag")
	_assert_equal(false, mesh_plan.peers[1].initiate, "mesh second peer answers")
	_assert_equal(2, mesh_plan.ice_servers.size(), "mesh plan ice count")
	_assert_equal(
		PackedStringArray(["stun:stun.l.google.com:19302"]),
		mesh_plan.ice_servers[0].urls,
		"stun urls"
	)
	_assert_equal("", mesh_plan.ice_servers[0].credential, "stun has no credential")
	_assert_equal(
		PackedStringArray(["turn:turn.example.com:3478"]),
		mesh_plan.ice_servers[1].urls,
		"turn urls"
	)
	_assert_equal("1700003600:fixture", mesh_plan.ice_servers[1].username, "turn username")
	_assert_equal("fixture-turn-secret", mesh_plan.ice_servers[1].credential, "turn credential")
	_assert(
		not mesh_plan._to_string().contains("fixture-turn-secret"),
		"plan debug must not contain the turn credential"
	)

	# Line 2: host + direct plan with host and endpoint.
	var host_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[1].args[0]
	_assert_equal(SFSessionTypesScript.Topology.HOST, host_plan.topology, "host plan topology")
	_assert_equal(
		SFSessionTypesScript.TransportKind.DIRECT, host_plan.transport, "host plan transport"
	)
	_assert_equal("30000000-0000-0000-0000-000000000001", host_plan.host, "host plan host id")
	_assert_equal("10.0.0.5", host_plan.direct_endpoint.host, "host endpoint address")
	_assert_equal(7777, host_plan.direct_endpoint.port, "host endpoint port")
	_assert_equal(0, host_plan.ice_servers.size(), "direct plan has no ice servers")

	# Line 3: explicit relay-floor reset plan.
	var relay_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[2].args[0]
	_assert_equal(SFSessionTypesScript.Topology.RELAY, relay_plan.topology, "relay reset topology")
	_assert_equal(
		SFSessionTypesScript.TransportKind.RELAY, relay_plan.transport, "relay reset transport"
	)
	_assert_equal(0, relay_plan.peers.size(), "relay reset has no peers")

	# Line 4: legacy Server 0.4 shape without generation.
	var legacy_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[3].args[0]
	_assert_equal("", legacy_plan.generation, "legacy plan has no generation")

	var new_peer: SFTypesScript.DecodedEvent = decoded_events[4]
	_assert_equal("30000000-0000-0000-0000-000000000003", new_peer.args[0], "new peer id")
	_assert_equal(true, new_peer.args[1], "new peer initiate flag")

	var signal_event: SFTypesScript.DecodedEvent = decoded_events[5]
	_assert_equal("30000000-0000-0000-0000-000000000002", signal_event.args[0], "signal from peer")
	_assert_equal("40000000-0000-0000-0000-000000000001", signal_event.args[1], "signal generation")
	_assert_equal(
		"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=signal-fish-fixture\r\n",
		signal_event.args[2]["Answer"],
		"signal answer payload round-trips verbatim"
	)

	var status: SFTypesScript.DecodedEvent = decoded_events[6]
	_assert_equal("30000000-0000-0000-0000-000000000002", status.args[0], "status peer id")
	_assert_equal(
		SFSessionTypesScript.TransportKind.WEBRTC, status.args[1], "status transport kind"
	)
	_assert_equal(true, status.args[2], "status connected")

	var pre_gather: SFTypesScript.RoomJoinedInfo = decoded_events[7].args[0]
	_assert_equal(1, pre_gather.ice_servers.size(), "room joined ice pre-gather")
	_assert_equal(
		PackedStringArray(["stun:stun.l.google.com:19302"]),
		pre_gather.ice_servers[0].urls,
		"room joined stun urls"
	)
	# Protocol-v3 snapshots trim connected_at (server #539); absent -> "".
	_assert_equal("", pre_gather.current_players[0].connected_at, "v3 snapshot trims connected_at")

	var v3_info: SFTypesScript.ProtocolInfo = decoded_events[8].args[0]
	_assert_equal(3, v3_info.protocol_version, "info negotiated version")
	_assert_equal(2, v3_info.min_protocol_version, "info min version")
	_assert_equal(3, v3_info.max_protocol_version, "info max version")
	_assert_equal(PackedStringArray(["websocket"]), v3_info.transports, "info transports")
	_assert_equal(1048576, v3_info.max_outbound_message_size, "info outbound cap")


func _test_v3_validation_and_sentinels() -> void:
	# Builder validation.
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal("", "gen", {"Offer": "s"})
		),
		"signal to is required"
	)
	_assert(
		not SFMessagesScript.is_valid_message(SFMessagesScript.peer_signal("peer", "gen", null)),
		"signal payload is required"
	)
	_assert(
		SFMessagesScript.is_valid_message(SFMessagesScript.peer_signal("peer", "gen", [])),
		"empty array signal payload is still JSON data"
	)
	_assert(
		SFMessagesScript.is_valid_message(SFMessagesScript.peer_signal("peer", "", {"Offer": "s"})),
		"empty generation is omitted (legacy shape)"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.transport_status(SFSessionTypesScript.TransportKind.UNKNOWN, true)
		),
		"unknown transport status is an invalid message"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.authenticate("app", null, null, null, 70000)
		),
		"protocol_version above u16 is rejected"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.authenticate("app", null, null, null, null, ["carrier_pigeon"])
		),
		"unknown supported transport is rejected"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.authenticate("app", null, null, null, null, null, ["star"])
		),
		"unknown supported topology is rejected"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.authenticate("app", null, null, null, null, null, null, [""])
		),
		"empty capability token is rejected"
	)

	# Unset v3 fields are omitted from the authenticate wire bytes.
	var minimal_auth := SFMessagesScript.authenticate("app")
	_assert(
		not SFEnvelopeScript.encode(minimal_auth).contains("protocol_version"),
		"unset protocol_version omitted"
	)

	# Decoder validation: malformed v3 frames are protocol errors, never crashes.
	var bad_plans := [
		[
			"plan with unknown topology",
			{"topology": "star", "transport": "webrtc", "peers": [], "fallback": "relay"}
		],
		[
			"plan with unknown transport",
			{"topology": "mesh", "transport": "smoke", "peers": [], "fallback": "relay"}
		],
		["plan without peers", {"topology": "mesh", "transport": "webrtc", "fallback": "relay"}],
		[
			"plan with peer missing initiate",
			{
				"topology": "mesh",
				"transport": "webrtc",
				"peers": [{"player_id": "p", "player_name": "P", "is_authority": false}],
				"fallback": "relay"
			}
		],
		[
			"plan with bad ice server",
			{
				"topology": "mesh",
				"transport": "webrtc",
				"peers": [],
				"ice_servers": [{"urls": []}],
				"fallback": "relay"
			}
		],
		[
			"plan with bad direct endpoint port",
			{
				"topology": "host",
				"transport": "direct",
				"host": "host-id",
				"direct_endpoint": {"host": "10.0.0.5", "port": 0},
				"peers": [],
				"fallback": "relay"
			}
		],
	]
	for bad: Array in bad_plans:
		var envelope := {"type": "SessionPlan", "data": bad[1]}
		var decoded := SFEventsScript.decode_envelope(envelope)
		_assert_protocol_error(decoded, "bad session plan: %s" % bad[0])

	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope({"type": "Signal", "data": {"from": "p"}}),
		"Signal requires from and signal",
		"signal without payload"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "Signal", "data": {"from": "p", "generation": 7, "signal": {}}}
		),
		"Signal generation must be a string",
		"signal with non-string generation"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope({"type": "NewPeer", "data": {"peer_id": "p"}}),
		"NewPeer requires peer_id and you_initiate",
		"new peer without you_initiate"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{
				"type": "PeerTransportStatus",
				"data": {"peer_id": "p", "transport": "smoke", "connected": true}
			}
		),
		"PeerTransportStatus transport is unknown",
		"status with unknown transport"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "ProtocolInfo", "data": {"protocol_version": "three"}}
		),
		"ProtocolInfo protocol_version must be u16",
		"info with bad protocol_version"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope({"type": "RoomJoined", "data": _room_joined_with_bad_ice()}),
		"RoomJoinedInfo ice_servers",
		"room joined with bad ice"
	)

	# Hostile / edge shapes.
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope({"type": "ProtocolInfo", "data": {"transports": ["smoke"]}}),
		"ProtocolInfo transports contains an unknown token",
		"info with unknown message transport"
	)
	var big_outbound := SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"max_outbound_message_size": 8589934592}}
	)
	if _assert_decoded_signal("protocol_info", big_outbound, "u64-range outbound cap decodes"):
		_assert_equal(
			8589934592, big_outbound.args[0].max_outbound_message_size, "outbound cap kept"
		)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "ProtocolInfo", "data": {"max_outbound_message_size": -1}}
		),
		"max_outbound_message_size must be a non-negative integer",
		"negative outbound cap rejected"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{
				"type": "RoomJoined",
				"data":
				{
					"room_id": "r",
					"room_code": "RC",
					"player_id": "p",
					"game_name": "g",
					"max_players": 4,
					"supports_authority": true,
					"current_players":
					[
						{
							"id": "p",
							"name": "P",
							"is_authority": false,
							"is_ready": false,
							"connected_at": 7
						}
					],
					"is_authority": true,
					"lobby_state": "waiting",
					"ready_players": [],
					"relay_type": "websocket"
				}
			}
		),
		"PlayerInfo connected_at must be a string",
		"non-string connected_at rejected"
	)
	# Explicit JSON null connected_at decodes to the "" sentinel without
	# aborting the rest of the player parse (upstream rejects null, but the
	# validator accepts it, so the parse must stay total).
	var null_connected := SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": _player_with_null_connected_at()}}
	)
	if _assert_decoded_signal("player_joined", null_connected, "null connected_at decodes"):
		_assert_equal("", null_connected.args[0].connected_at, "null connected_at sentinel")
		var info: SFTypesScript.ConnectionInfo = null_connected.args[0].connection_info
		_assert_equal("direct", info.type, "connection_info survives null connected_at")

	# JSON null signal payloads round-trip verbatim (upstream Value::Null).
	var null_signal := SFEventsScript.decode_envelope(
		{"type": "Signal", "data": {"from": "p", "generation": "gen", "signal": null}}
	)
	if _assert_decoded_signal("signal_received", null_signal, "null signal payload decodes"):
		_assert_equal(null_signal.args[2], null, "null signal payload kept verbatim")

	# Engine-only Variants nested in a signal payload are refused locally
	# instead of being stringified onto the wire.
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal("peer", "gen", {"Offer": Vector2(1, 2)})
		),
		"engine-only nested payload refused"
	)

	# A v3 plan inside missed_events decodes like any other event.
	var reconnected := (
		SFEventsScript
		. decode_envelope(
			{
				"type": "Reconnected",
				"data":
				{
					"room_id": "r",
					"room_code": "RC",
					"player_id": "p",
					"game_name": "g",
					"max_players": 4,
					"supports_authority": true,
					"current_players": [],
					"is_authority": true,
					"lobby_state": "finalized",
					"ready_players": [],
					"relay_type": "websocket",
					"missed_events":
					[
						{
							"type": "SessionPlan",
							"data":
							{
								"generation": "gen",
								"topology": "relay",
								"transport": "relay",
								"peers": [],
								"fallback": "relay"
							}
						}
					],
				}
			}
		)
	)
	if _assert_decoded_signal("reconnected", reconnected, "reconnect with v3 replay"):
		_assert_decoded_signal("session_plan", reconnected.args[1][0], "replayed v3 plan decodes")


func _room_joined_with_bad_ice() -> Dictionary:
	return {
		"room_id": "r",
		"room_code": "RC",
		"player_id": "p",
		"game_name": "g",
		"max_players": 4,
		"supports_authority": true,
		"current_players": [],
		"is_authority": true,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket",
		"ice_servers": [{"urls": "not-an-array"}],
	}


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
	if String(decoded.signal_name) == expected:
		return true
	_failures.append(
		"%s: expected signal %s, got %s" % [label, expected, _decoded_summary(decoded)]
	)
	return false


func _assert_protocol_error(decoded: RefCounted, label: String) -> bool:
	if not _assert_decoded_signal("protocol_error", decoded, label):
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


func _decoded_summary(decoded: RefCounted) -> String:
	if decoded == null:
		return "<null decoded event>"
	var signal_text := "<missing>"
	if decoded.get("signal_name") != null:
		signal_text = String(decoded.signal_name)
	var args_text := "<missing>"
	if decoded.get("args") != null:
		args_text = var_to_str(decoded.args)
	return "%s args=%s" % [signal_text, args_text]


func _player_with_null_connected_at() -> Dictionary:
	return {
		"id": "p",
		"name": "P",
		"is_authority": false,
		"is_ready": false,
		"connected_at": null,
		"connection_info": {"type": "direct", "host": "h", "port": 1},
	}
