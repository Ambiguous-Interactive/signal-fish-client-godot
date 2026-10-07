extends RefCounted

## Protocol v3 (session-plan/WebRTC signaling) codec tests. Kept as a helper
## suite (same shape as protocol_hardening_tests.gd) so the fixture runner
## stays within the project's max-file-lines lint.

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const V3_CLIENT_FIXTURE := "res://tests/fixtures/v3_client_messages.jsonl"
const V3_SERVER_FIXTURE := "res://tests/fixtures/v3_server_messages.jsonl"

var _failures: Array[String] = []
var _test_done := false


func _done() -> void:
	_test_done = true


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_v3_client_encoders_match_fixtures,
		_test_v3_server_decoders_match_fixtures,
		_test_v3_validation_and_sentinels,
		_test_truncated_missed_events_keep_the_newest,
		_test_plan_debug_repr_count_bounds,
		_test_ice_debug_repr_item_bounds,
		_test_plan_debug_repr_id_bounds,
		_test_v3_advisory_events,
		_test_v3_room_operation_results,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## GoingAway/DeliveryReport decode contracts: the accept paths pin the typed
## args; the refusal matrix is data-driven so each hostile shape names its
## diagnostic.
func _test_v3_advisory_events() -> void:
	var going_away := SFEventsScript.decode_text(
		'{"type": "GoingAway", "data": {"deadline_ms": 1700000000000, "retry_after_secs": 30}}'
	)
	if _assert_decoded_signal("going_away", going_away, "going away decodes"):
		_assert_equal(1700000000000, going_away.args[0], "going away deadline")
		_assert_equal(30, going_away.args[1], "going away retry hint")
	var silent := SFEventsScript.decode_text('{"type": "GoingAway", "data": {"deadline_ms": 5}}')
	if _assert_decoded_signal("going_away", silent, "going away without hint decodes"):
		_assert_equal(-1, silent.args[1], "absent retry hint decodes to the -1 sentinel")
	var explicit_null := SFEventsScript.decode_text(
		'{"type": "GoingAway", "data": {"deadline_ms": 5, "retry_after_secs": null}}'
	)
	if _assert_decoded_signal("going_away", explicit_null, "null retry hint decodes"):
		_assert_equal(-1, explicit_null.args[1], "null retry hint decodes to the -1 sentinel")
	var going_away_refusals := {
		"missing deadline": '{"type": "GoingAway", "data": {"retry_after_secs": 1}}',
		"negative deadline": '{"type": "GoingAway", "data": {"deadline_ms": -1}}',
		"non-integer deadline": '{"type": "GoingAway", "data": {"deadline_ms": 1.5}}',
		"deadline above i64": '{"type": "GoingAway", "data": {"deadline_ms": 9223372036854775808}}',
		"hint above i64": (
			'{"type": "GoingAway", "data": {"deadline_ms": 1,'
			+ ' "retry_after_secs": 9223372036854775808}}'
		),
		"non-integer hint": '{"type": "GoingAway", "data": {"deadline_ms": 1, "retry_after_secs": "soon"}}',
	}
	for label: String in going_away_refusals:
		var going_away_text: String = going_away_refusals[label]
		_assert_protocol_error(
			SFEventsScript.decode_text(going_away_text),
			"GoingAway refuses %s" % label
		)

	var report := SFEventsScript.decode_text(
		(
			'{"type": "DeliveryReport", "data": {"per_class": {"reliable": {"delivered": 8,'
			+ ' "abandoned": 0, "unsupported_format": 0}, "latest": {"delivered": 1,'
			+ ' "superseded": 2, "dropped_full": 0, "abandoned": 0, "unsupported_format": 0}},'
			+ ' "gaps": [{"from_player": "10000000-0000-0000-0000-000000000001", "epoch": 1,'
			+ ' "from_seq": 42, "to_seq": 43, "reason": "volatile_dropped"}]}}'
		)
	)
	if _assert_decoded_signal("delivery_report", report, "delivery report decodes"):
		var info: SFSessionTypesScript.DeliveryReportInfo = report.args[0]
		_assert_equal(8, info.counters_for("reliable").get_count("delivered"), "reliable delivered")
		_assert_equal(2, info.counters_for("latest").get_count("superseded"), "latest superseded")
		_assert_equal(0, info.counters_for("latest").get_count("dropped_full"), "latest dropped_full")
		_assert_equal(null, info.counters_for("volatile"), "absent class has no counters object")
		_assert_equal(1, info.gaps.size(), "gap count")
		if info.gaps.size() == 1:
			_assert_equal(
				SFSessionTypesScript.DeliveryGapReason.VOLATILE_DROPPED,
				info.gaps[0].reason,
				"gap reason"
			)
			_assert_equal(43, info.gaps[0].to_seq, "gap to_seq")
	var gaps_cap := {"type": "DeliveryReport", "data": {"per_class": {}, "gaps": []}}
	var hostile_gaps: Array = gaps_cap["data"]["gaps"]
	for index: int in 257:
		hostile_gaps.append(
			{
				"from_player": "10000000-0000-0000-0000-000000000001",
				"epoch": 1,
				"from_seq": 1,
				"to_seq": 1,
				"reason": "volatile_dropped",
			}
		)
	_assert_protocol_error(
		SFEventsScript.decode_text(JSON.stringify(gaps_cap)),
		"DeliveryReport refuses more than the upstream gap cap"
	)
	var report_refusals := {
		"missing per_class": '{"type": "DeliveryReport", "data": {}}',
		"non-object per_class": '{"type": "DeliveryReport", "data": {"per_class": 3}}',
		"negative counter": (
			'{"type": "DeliveryReport", "data": {"per_class": {"reliable": {"delivered": -1}}}}'
		),
		"counter above i64": (
			'{"type": "DeliveryReport", "data": {"per_class": {"reliable":'
			+ ' {"delivered": 9223372036854775808}}}}'
		),
		"non-object gap": '{"type": "DeliveryReport", "data": {"per_class": {}, "gaps": [1]}}',
		"gap bad sender": (
			'{"type": "DeliveryReport", "data": {"per_class": {}, "gaps":'
			+ ' [{"from_player": "peer-b", "epoch": 1, "from_seq": 1, "to_seq": 1,'
			+ ' "reason": "volatile_dropped"}]}}'
		),
		"gap epoch above u32": (
			'{"type": "DeliveryReport", "data": {"per_class": {}, "gaps":'
			+ ' [{"from_player": "10000000-0000-0000-0000-000000000001", "epoch": 4294967296,'
			+ ' "from_seq": 1, "to_seq": 1, "reason": "volatile_dropped"}]}}'
		),
		"gap unknown reason": (
			'{"type": "DeliveryReport", "data": {"per_class": {}, "gaps":'
			+ ' [{"from_player": "10000000-0000-0000-0000-000000000001", "epoch": 1,'
			+ ' "from_seq": 1, "to_seq": 1, "reason": "vaporized"}]}}'
		),
	}
	for label: String in report_refusals:
		var report_text: String = report_refusals[label]
		_assert_protocol_error(
			SFEventsScript.decode_text(report_text),
			"DeliveryReport refuses %s" % label
		)
	var no_gaps := SFEventsScript.decode_text(
		'{"type": "DeliveryReport", "data": {"per_class": {"reliable": {"delivered": 1}}}}'
	)
	if _assert_decoded_signal("delivery_report", no_gaps, "delivery report without gaps decodes"):
		var lean: SFSessionTypesScript.DeliveryReportInfo = no_gaps.args[0]
		_assert_equal(0, lean.gaps.size(), "absent gaps decode to an empty array")
	_done()


## RoomOperationResult decode contracts: the closed 15-variant set, the
## canonical operation-id gate, and per-variant payload refusals. The client
## never issues operations yet, so results only ever decode and surface.
func _test_v3_room_operation_results() -> void:
	var room_left := SFEventsScript.decode_text(
		(
			'{"type": "RoomOperationResult", "data": {"operation_id":'
			+ ' "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "result": {"type": "RoomLeft"}}}'
		)
	)
	if _assert_decoded_signal("room_operation_result", room_left, "RoomLeft result decodes"):
		var info: SFSessionTypesScript.RoomOperationResultInfo = room_left.args[0]
		_assert_equal("RoomLeft", info.result_type, "RoomLeft result type")
		_assert_equal({}, info.data, "unit variant carries no data")
	var accepted_variants := {
		"PlayerKicked": {"player_id": "10000000-0000-0000-0000-000000000001"},
		"RoomCodeRegenerated": {"room_code": "USE4XP"},
		"RoomAccessUpdated": {"requires_password": true},
		"OperationFailed": {"reason": "room is closed"},
		"ReconnectionFailed": {"reason": "stale", "error_code": "RECONNECTION_EXPIRED"},
		"SpectatorLeft": {"reason": "voluntary_leave", "current_spectators": []},
	}
	for variant: String in accepted_variants:
		var decoded := SFEventsScript.decode_text(
			JSON.stringify({
				"type": "RoomOperationResult",
				"data": {
					"operation_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
					"result": {"type": variant, "data": accepted_variants[variant]},
				},
			})
		)
		if _assert_decoded_signal("room_operation_result", decoded, "%s result decodes" % variant):
			_assert_equal(variant, decoded.args[0].result_type, "%s result type" % variant)
	var room_joined_result := SFEventsScript.decode_text(
		JSON.stringify({
			"type": "RoomOperationResult",
			"data": {
				"operation_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
				"result": {"type": "RoomJoined", "data": _room_joined_with_bad_ice()},
			},
		})
	)
	_assert_protocol_error_contains(
		room_joined_result, "urls", "RoomJoined result payload is validated"
	)
	var result_refusals := {
		"unknown variant": {"type": "ConfettiCannon"},
		"empty variant": {"type": ""},
		"missing result": null,
		"unit variant with data": {"type": "RoomLeft", "data": {}},
		"player variant without id": {"type": "PlayerKicked", "data": {}},
		"player variant bad id": {
			"type": "PlayerKicked",
			"data": {"player_id": "peer-b"},
		},
		"code variant empty code": {"type": "RoomCodeRegenerated", "data": {"room_code": ""}},
		"access variant without flag": {"type": "RoomAccessUpdated", "data": {}},
		"failure variant without reason": {"type": "OperationFailed", "data": {}},
		"reconnection variant without code": {
			"type": "ReconnectionFailed",
			"data": {"reason": "stale"},
		},
		"spectator-left variant non-string reason": {
			"type": "SpectatorLeft",
			"data": {"reason": 5},
		},
	}
	for label: String in result_refusals:
		var payload: Dictionary = {"operation_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
		if result_refusals[label] != null:
			payload["result"] = result_refusals[label]
		_assert_protocol_error(
			SFEventsScript.decode_text(
				JSON.stringify({"type": "RoomOperationResult", "data": payload})
			),
			"RoomOperationResult refuses %s" % label
		)
	var id_refusals := {
		"missing operation id": {"result": {"type": "RoomLeft"}},
		"non-canonical operation id": {
			"operation_id": "{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}",
			"result": {"type": "RoomLeft"},
		},
	}
	for label: String in id_refusals:
		_assert_protocol_error(
			SFEventsScript.decode_text(
				JSON.stringify({"type": "RoomOperationResult", "data": id_refusals[label]})
			),
			"RoomOperationResult refuses %s" % label
		)
	_done()


## Issue #284: wire-derived lists in debug reprs are count-bounded, so a
## hostile relay cannot stretch one printed line with thousands of peers
## or ICE urls.
func _test_plan_debug_repr_count_bounds() -> void:
	var peers: Array = []
	for index: int in 300:
		var peer := {
			"player_id": "30000000-0000-0000-0000-%012d" % index,
			"player_name": "p%d" % index,
			"is_authority": false,
			"initiate": true,
		}
		peers.append(peer)
	var plan_data := {
		"generation": "50000000-0000-0000-0000-000000000001",
		"topology": "mesh",
		"transport": "webrtc",
		"fallback": "relay",
		"peers": peers,
	}
	var plan: SFSessionTypesScript.SessionPlanInfo = SFSessionTypesScript.make_session_plan_info(
		plan_data
	)
	var plan_text := plan._to_string()
	_assert_string_contains(plan_text, "and 292 more", "plan debug caps peer list")
	_assert(plan_text.length() < 600, "plan debug stays bounded")

	# Legit traffic keeps the plain, readable repr: no array brackets or
	# per-item quotes.
	var small_peers: Array = []
	for index: int in 2:
		var peer := {
			"player_id": "30000000-0000-0000-0000-%012d" % index,
			"player_name": "p%d" % index,
			"is_authority": false,
			"initiate": true,
		}
		small_peers.append(peer)
	var small_plan_data := {
		"generation": "50000000-0000-0000-0000-000000000001",
		"topology": "mesh",
		"transport": "webrtc",
		"fallback": "relay",
		"peers": small_peers,
	}
	var small_plan: SFSessionTypesScript.SessionPlanInfo = (
		SFSessionTypesScript.make_session_plan_info(small_plan_data)
	)
	var small_text := small_plan._to_string()
	_assert_string_contains(
		small_text,
		"peers=[30000000-0000-0000-0000-000000000000, 30000000-0000-0000-0000-000000000001]",
		"plan debug keeps the plain repr"
	)

	var urls: Array = []
	for index: int in 40:
		urls.append("stun:stun.example.com:%d" % index)
	var ice := SFSessionTypesScript.IceServerInfo.new({"urls": urls})
	var ice_text := ice._to_string()
	_assert_string_contains(ice_text, "and 32 more", "ice debug caps url list")
	_assert(ice_text.length() < 300, "ice debug stays bounded")
	var small_ice := SFSessionTypesScript.IceServerInfo.new({"urls": ["stun:a:1", "stun:b:2"]})
	_assert_equal(
		"IceServerInfo(stun:a:1, stun:b:2)",
		small_ice._to_string(),
		"ice debug keeps the plain repr"
	)
	_done()


## Issue #286: urls stay free text after validation (array shape only),
## so each rendered item is length-capped and control-escaped: 8 hostile
## urls cannot stretch one printed line, and embedded control
## characters cannot forge log lines. The ninth hostile url pins both
## caps composed: count collapse plus per-item truncation.
func _test_ice_debug_repr_item_bounds() -> void:
	var hostile_urls: Array = []
	for index: int in 9:
		hostile_urls.append("stun:%s" % "x".repeat(60000))
	var hostile := SFSessionTypesScript.IceServerInfo.new({"urls": hostile_urls})
	var hostile_text := hostile._to_string()
	_assert(hostile_text.length() < 600, "hostile urls stay bounded in the repr")
	_assert(not hostile_text.contains("\n"), "the repr stays one line")
	_assert_string_contains(
		hostile_text, ", and 1 more)", "the count cap still collapses the overflow"
	)
	_assert_string_contains(
		hostile_text, "stun:%s, and 1 more)" % "x".repeat(27), "overflow items render truncated"
	)

	var over_cap := "stun:abc123abc123abc123abc123abc123abc123"
	var truncated := SFSessionTypesScript.IceServerInfo.new({"urls": [over_cap]})
	_assert_equal(
		"IceServerInfo(stun:abc123abc123abc123abc123abc)",
		truncated._to_string(),
		"over-cap urls truncate at the 32-char key cap"
	)

	var control := SFSessionTypesScript.IceServerInfo.new({"urls": ["stun:a\nb"]})
	_assert_equal(
		"IceServerInfo(stun:a\\x0Ab)", control._to_string(), "embedded newlines render as escapes"
	)
	_done()


## Issue #287: generation and peer ids also render through the public
## constructor path, where no validator ran, so each id is length-capped
## at the canonical UUID width and control-escaped: a self-inflicted
## dictionary cannot stretch one printed line or forge log lines.
func _test_plan_debug_repr_id_bounds() -> void:
	var hostile_plan_data := {
		"generation": "%s\n%s" % ["5".repeat(35), "6".repeat(60000)],
		"topology": "mesh",
		"transport": "webrtc",
		"fallback": "relay",
		"peers": [],
	}
	var hostile_plan: SFSessionTypesScript.SessionPlanInfo = (
		SFSessionTypesScript.make_session_plan_info(hostile_plan_data)
	)
	_assert_equal(
		(
			"SessionPlanInfo(generation=%s\\x0A topology=mesh transport=webrtc peers=[])"
			% "5".repeat(35)
		),
		hostile_plan._to_string(),
		"over-cap generation truncates at 36 chars and escapes controls"
	)

	var hostile_peers: Array = []
	for index: int in 9:
		var hostile_peer := {
			"player_id": "p%d\n%s" % [index, "x".repeat(60000)],
			"player_name": "p%d" % index,
			"is_authority": false,
			"initiate": true,
		}
		hostile_peers.append(hostile_peer)
	var hostile_peer_plan_data := {
		"generation": "50000000-0000-0000-0000-000000000001",
		"topology": "mesh",
		"transport": "webrtc",
		"fallback": "relay",
		"peers": hostile_peers,
	}
	var hostile_peer_plan: SFSessionTypesScript.SessionPlanInfo = (
		SFSessionTypesScript.make_session_plan_info(hostile_peer_plan_data)
	)
	var hostile_text := hostile_peer_plan._to_string()
	_assert(hostile_text.length() < 600, "hostile peer ids stay bounded in the repr")
	_assert(not hostile_text.contains("\n"), "the repr stays one line")
	_assert_string_contains(
		hostile_text, ", and 1 more])", "the count cap still collapses the overflow"
	)
	_assert_string_contains(hostile_text, "p0\\x0A", "embedded newlines render as escapes")
	_assert_string_contains(
		hostile_text,
		"generation=50000000-0000-0000-0000-000000000001 topology=mesh",
		"canonical generation keeps the plain repr"
	)

	var boundary_data := {
		"generation": "50000000-0000-0000-0000-000000000001",
		"topology": "relay",
		"transport": "relay",
		"peers":
		[
			{
				"player_id": "a".repeat(37),
				"player_name": "p",
				"is_authority": false,
				"initiate": false,
			},
		],
	}
	var boundary_plan: SFSessionTypesScript.SessionPlanInfo = (
		SFSessionTypesScript.make_session_plan_info(boundary_data)
	)
	_assert_string_contains(
		boundary_plan._to_string(),
		"peers=[%s])" % "a".repeat(36),
		"over-cap ids truncate at the 36-char UUID width"
	)
	_done()


func _test_v3_client_encoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(V3_CLIENT_FIXTURE)
	if not _assert_fixture_count(5, lines, V3_CLIENT_FIXTURE):
		_done()
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
		_done()
		return
	for index: int in lines.size():
		var message: Dictionary = built[index]
		var encoded := SFEnvelopeScript.encode(message)
		_assert_equal(lines[index], encoded, "%s line %d" % [V3_CLIENT_FIXTURE, index + 1])
	_done()


func _test_v3_server_decoders_match_fixtures() -> void:
	var lines := _read_fixture_lines(V3_SERVER_FIXTURE)
	if not _assert_fixture_count(9, lines, V3_SERVER_FIXTURE):
		_done()
		return
	var expected_signals: Array[String] = [
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
	var expected_arg_counts: Array[int] = [1, 1, 1, 1, 2, 3, 3, 1, 1]
	if not _assert_equal(lines.size(), expected_signals.size(), "v3 expected signal count"):
		_done()
		return
	var decoded_events: Array[SFTypesScript.DecodedEvent] = []
	var failures_before_fixture_shape_checks := _failures.size()
	for index: int in lines.size():
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(lines[index])
		decoded_events.append(decoded)
		var expected_signal: String = expected_signals[index]
		if not _assert_decoded_signal(
			expected_signal, decoded, "%s line %d" % [V3_SERVER_FIXTURE, index + 1]
		):
			continue
		_assert_equal(
			expected_arg_counts[index],
			decoded.args.size(),
			"%s line %d arg count" % [V3_SERVER_FIXTURE, index + 1]
		)
	if _failures.size() != failures_before_fixture_shape_checks:
		_done()
		return

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

	var host_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[1].args[0]
	_assert_equal(SFSessionTypesScript.Topology.HOST, host_plan.topology, "host plan topology")
	_assert_equal(
		SFSessionTypesScript.TransportKind.DIRECT, host_plan.transport, "host plan transport"
	)
	_assert_equal("30000000-0000-0000-0000-000000000001", host_plan.host, "host plan host id")
	_assert_equal("10.0.0.5", host_plan.direct_endpoint.host, "host endpoint address")
	_assert_equal(7777, host_plan.direct_endpoint.port, "host endpoint port")
	_assert_equal(0, host_plan.ice_servers.size(), "direct plan has no ice servers")

	var relay_plan: SFSessionTypesScript.SessionPlanInfo = decoded_events[2].args[0]
	_assert_equal(SFSessionTypesScript.Topology.RELAY, relay_plan.topology, "relay reset topology")
	_assert_equal(
		SFSessionTypesScript.TransportKind.RELAY, relay_plan.transport, "relay reset transport"
	)
	_assert_equal(0, relay_plan.peers.size(), "relay reset has no peers")

	# Legacy server 0.4 wire shape.
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
	_done()


func _test_v3_validation_and_sentinels() -> void:
	# Issue #151: the to field is a PlayerId UUID, so placeholder text fails
	# the canonical-UUID gate ("peer-b" only fails under the shape gate; ""
	# additionally passed the old emptiness check).
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal(
				"peer-b", "40000000-0000-0000-0000-000000000001", {"Offer": "s"}
			)
		),
		"signal to must be canonical UUID text"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal("", "40000000-0000-0000-0000-000000000001", {"Offer": "s"})
		),
		"signal empty to is still refused"
	)
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal(
				"10000000-0000-0000-0000-000000000001", "40000000-0000-0000-0000-000000000001", null
			)
		),
		"signal payload is required"
	)
	_assert(
		SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal(
				"10000000-0000-0000-0000-000000000001", "40000000-0000-0000-0000-000000000001", []
			)
		),
		"empty array signal payload is still JSON data"
	)
	_assert(
		SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal("10000000-0000-0000-0000-000000000001", "", {"Offer": "s"})
		),
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

	var minimal_auth := SFMessagesScript.authenticate("app")
	_assert(
		not SFEnvelopeScript.encode(minimal_auth).contains("protocol_version"),
		"unset protocol_version omitted"
	)

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
				"peers":
				[
					{
						"player_id": "10000000-0000-0000-0000-000000000001",
						"player_name": "P",
						"is_authority": false
					}
				],
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
		SFEventsScript.decode_envelope(
			{"type": "Signal", "data": {"from": "10000000-0000-0000-0000-000000000001"}}
		),
		"Signal requires from and signal",
		"signal without payload"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{
				"type": "Signal",
				"data":
				{"from": "10000000-0000-0000-0000-000000000001", "generation": 7, "signal": {}}
			}
		),
		"Signal generation must be a string",
		"signal with non-string generation"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "NewPeer", "data": {"peer_id": "10000000-0000-0000-0000-000000000001"}}
		),
		"NewPeer requires peer_id and you_initiate",
		"new peer without you_initiate"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{
				"type": "PeerTransportStatus",
				"data":
				{
					"peer_id": "10000000-0000-0000-0000-000000000001",
					"transport": "smoke",
					"connected": true
				}
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

	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope({"type": "ProtocolInfo", "data": {"transports": ["smoke"]}}),
		"ProtocolInfo transports contains an unknown token",
		"info with unknown message transport"
	)
	var big_outbound: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"max_outbound_message_size": 8589934592}}
	)
	if _assert_decoded_signal("protocol_info", big_outbound, "large outbound cap decodes"):
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
	# Issue #73: an out-of-int-range cap must be rejected loudly, not
	# platform-dependently collapsed to 0 (which would disable the cap).
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "ProtocolInfo", "data": {"max_outbound_message_size": 1e30}}
		),
		"max_outbound_message_size must be a non-negative integer",
		"out-of-range outbound cap rejected"
	)
	# The exact platform ceiling is legitimate; the float 2^63 (I64_MAX rounds
	# up to it) is hostile and must not collapse either.
	var ceiling: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"max_outbound_message_size": SFTypesScript.I64_MAX}}
	)
	if _assert_decoded_signal("protocol_info", ceiling, "i64 ceiling decodes"):
		_assert_equal(
			SFTypesScript.I64_MAX, ceiling.args[0].max_outbound_message_size, "ceiling value kept"
		)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{"type": "ProtocolInfo", "data": {"max_outbound_message_size": 9223372036854775808.0}}
		),
		"max_outbound_message_size must be a non-negative integer",
		"2^63 float cap rejected"
	)
	# Issue #78: player_name_rules lengths obey the same reject-never-collapse
	# policy as the outbound cap (#73.4): a hostile float must not survive
	# validation and then collapse in the constructor's int().
	var length_cases := [
		{"label": "1e30 max_length rejected", "max_length": 1e30},
		{"label": "2^63 float max_length rejected", "max_length": 9223372036854775808.0},
		{"label": "1e30 min_length rejected", "min_length": 1e30, "max_length": 32},
	]
	for length_case: Dictionary in length_cases:
		var case_label: String = length_case["label"]
		var rules := {
			"max_length": 32,
			"min_length": 1,
			"allow_unicode_alphanumeric": true,
			"allow_spaces": true,
			"allow_leading_trailing_whitespace": false,
		}
		for key: String in ["max_length", "min_length"]:
			if length_case.has(key):
				rules[key] = length_case[key]
		_assert_protocol_error_contains(
			SFEventsScript.decode_envelope(
				{"type": "ProtocolInfo", "data": {"player_name_rules": rules}}
			),
			"player_name_rules requires nonnegative integer",
			case_label
		)
	var int_ceiling_rules := (
		SFTypesScript
		. ProtocolInfo
		. new(
			{
				"player_name_rules":
				{
					"max_length": SFTypesScript.I64_MAX,
					"min_length": 1,
					"allow_unicode_alphanumeric": true,
					"allow_spaces": true,
					"allow_leading_trailing_whitespace": false,
				}
			}
		)
	)
	_assert_equal(
		SFTypesScript.I64_MAX, int_ceiling_rules.player_name_rules.max_length, "i64 ceiling kept"
	)
	_assert_protocol_error_contains(
		SFEventsScript.decode_envelope(
			{
				"type": "RoomJoined",
				"data":
				{
					"room_id": "20000000-0000-0000-0000-000000000001",
					"room_code": "RC",
					"player_id": "10000000-0000-0000-0000-000000000001",
					"game_name": "g",
					"max_players": 4,
					"supports_authority": true,
					"current_players":
					[
						{
							"id": "10000000-0000-0000-0000-000000000001",
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
	# Null connected_at decodes to the "" sentinel without aborting the parse
	# (upstream rejects null; validator accepts it).
	var null_connected: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": _player_with_null_connected_at()}}
	)
	if _assert_decoded_signal("player_joined", null_connected, "null connected_at decodes"):
		_assert_equal("", null_connected.args[0].connected_at, "null connected_at sentinel")
		var info: SFTypesScript.ConnectionInfo = null_connected.args[0].connection_info
		_assert_equal("direct", info.type, "connection_info survives null connected_at")

	# JSON null signal payloads round-trip verbatim (upstream Value::Null).
	var null_signal: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "Signal",
			"data":
			{
				"from": "10000000-0000-0000-0000-000000000001",
				"generation": "40000000-0000-0000-0000-000000000001",
				"signal": null
			}
		}
	)
	if _assert_decoded_signal("signal_received", null_signal, "null signal payload decodes"):
		_assert_equal(null_signal.args[2], null, "null signal payload kept verbatim")

	# Engine-only Variants are refused locally instead of being stringified onto the wire.
	_assert(
		not SFMessagesScript.is_valid_message(
			SFMessagesScript.peer_signal(
				"10000000-0000-0000-0000-000000000001",
				"40000000-0000-0000-0000-000000000001",
				{"Offer": Vector2(1, 2)}
			)
		),
		"engine-only nested payload refused"
	)

	var reconnected: SFTypesScript.DecodedEvent = (
		SFEventsScript
		. decode_envelope(
			{
				"type": "Reconnected",
				"data":
				{
					"room_id": "20000000-0000-0000-0000-000000000001",
					"room_code": "RC",
					"player_id": "10000000-0000-0000-0000-000000000001",
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
								"generation": "40000000-0000-0000-0000-000000000001",
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
		var replayed: SFTypesScript.DecodedEvent = reconnected.args[1][0]
		_assert_decoded_signal("session_plan", replayed, "replayed v3 plan decodes")
	_done()


func _room_joined_with_bad_ice() -> Dictionary:
	return {
		"room_id": "20000000-0000-0000-0000-000000000001",
		"room_code": "RC",
		"player_id": "10000000-0000-0000-0000-000000000001",
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
	var event: SFTypesScript.DecodedEvent = decoded
	if String(event.signal_name) == expected:
		return true
	_failures.append(
		"%s: expected signal %s, got %s" % [label, expected, _decoded_summary(decoded)]
	)
	return false


func _assert_protocol_error(decoded: RefCounted, label: String) -> bool:
	if not _assert_decoded_signal("protocol_error", decoded, label):
		return false
	var event: SFTypesScript.DecodedEvent = decoded
	if not _assert_equal(1, event.args.size(), "%s protocol_error args" % label):
		return false
	return _assert(
		typeof(event.args[0]) == TYPE_STRING and not str(event.args[0]).is_empty(),
		"%s protocol_error message must be non-empty" % label
	)


func _assert_protocol_error_contains(
	decoded: RefCounted, expected_substring: String, label: String
) -> bool:
	if not _assert_protocol_error(decoded, label):
		return false
	var event: SFTypesScript.DecodedEvent = decoded
	return _assert_string_contains(str(event.args[0]), expected_substring, label)


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
	var event: SFTypesScript.DecodedEvent = decoded
	var signal_text := "<missing>"
	if event.get("signal_name") != null:
		signal_text = String(event.signal_name)
	var args_text := "<missing>"
	if event.get("args") != null:
		args_text = var_to_str(event.args)
	return "%s args=%s" % [signal_text, args_text]


func _player_with_null_connected_at() -> Dictionary:
	return {
		"id": "10000000-0000-0000-0000-000000000001",
		"name": "P",
		"is_authority": false,
		"is_ready": false,
		"connected_at": null,
		"connection_info": {"type": "direct", "host": "h", "port": 1},
	}


func _test_truncated_missed_events_keep_the_newest() -> void:
	# Issue #129: `replay: truncated` means missed_events is the most-recent
	# suffix, so a decode cap that overflows must drop the OLDEST entries and
	# keep the ones closest to now.
	var total := 260
	var missed: Array[Dictionary] = []
	for index: int in total:
		missed.append(
			{
				"type": "SessionPlan",
				"data":
				{
					"generation": "50000000-0000-0000-0000-%012d" % index,
					"topology": "relay",
					"transport": "relay",
					"peers": [],
					"fallback": "relay"
				}
			}
		)
	var reconnected: SFTypesScript.DecodedEvent = (
		SFEventsScript
		. decode_envelope(
			{
				"type": "Reconnected",
				"data":
				{
					"room_id": "20000000-0000-0000-0000-000000000001",
					"room_code": "RC",
					"player_id": "10000000-0000-0000-0000-000000000001",
					"game_name": "g",
					"max_players": 4,
					"supports_authority": true,
					"current_players": [],
					"is_authority": true,
					"lobby_state": "waiting",
					"ready_players": [],
					"relay_type": "websocket",
					"replay": "truncated",
					"missed_events": missed,
				}
			}
		)
	)
	if not _assert_decoded_signal("reconnected", reconnected, "truncated replay decodes"):
		_done()
		return
	var kept: Array[SFTypesScript.DecodedEvent] = reconnected.args[1]
	var cap := SFEventsScript.MAX_MISSED_EVENTS
	_assert_equal(cap + 1, kept.size(), "the cap keeps its entries plus the sentinel")
	var first: SFTypesScript.DecodedEvent = kept[0]
	if _assert_decoded_signal("session_plan", first, "the oldest kept entry decodes"):
		var plan: SFSessionTypesScript.SessionPlanInfo = first.args[0]
		_assert_equal(
			"50000000-0000-0000-0000-%012d" % (total - cap),
			plan.generation,
			"the kept window starts at the newest cap entries"
		)
	var last_real: SFTypesScript.DecodedEvent = kept[cap - 1]
	if _assert_decoded_signal("session_plan", last_real, "the newest entry decodes"):
		var newest: SFSessionTypesScript.SessionPlanInfo = last_real.args[0]
		_assert_equal(
			"50000000-0000-0000-0000-%012d" % (total - 1),
			newest.generation,
			"the newest event survives the cap"
		)
	var sentinel: SFTypesScript.DecodedEvent = kept[cap]
	if _assert_decoded_signal(
		"protocol_error", sentinel, "the overflow sentinel trails the kept events"
	):
		var sentinel_text: String = sentinel.args[0]
		_assert_string_contains(
			sentinel_text,
			"dropped %d" % (total - cap),
			"the sentinel counts the dropped oldest entries"
		)
	_done()
