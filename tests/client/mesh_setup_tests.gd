extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const TransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_C := "10000000-0000-0000-0000-000000000003"
const GENERATION := "40000000-0000-0000-0000-000000000001"

var _failures: Array[String] = []
var _test_done := false
var _owner: Object


static func run(owner: Object) -> Array[String]:
	var tests := new()
	tests._owner = owner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_negotiation_failures_release_only_failed_peer,
		_test_candidate_refusal_keeps_link_usable,
		_test_candidate_wire_formats,
		_test_poll_failure_reports_down,
		_test_terminal_links_release_and_retry,
		_test_room_reset_during_status_refusal,
		_test_session_loss_releases_mesh,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)


func _test_negotiation_failures_release_only_failed_peer() -> void:
	for operation: String in [
		"create_offer", "local_offer", "local_answer", "remote_offer", "remote_answer", "poll"
	]:
		var client: ClientScript = _owner.call("_make_in_room_client")
		var mesh: MeshScript = _owner.call("_make_mesh")
		var factory := mesh.peer_connection_factory
		mesh.peer_connection_factory = func() -> Variant:
			var connection: Object = factory.call()
			var created: Array = _owner.call("_mesh_peers", mesh)
			if created.size() == 1:
				var refused := operation
				if operation.begins_with("local_"):
					refused = "set_local_description"
				elif operation.begins_with("remote_"):
					refused = "set_remote_description"
				connection.set("refused_operation", refused)
			return connection
		_owner.call("_attach", mesh, client)
		var peers: Array[Dictionary] = [
			_owner.call("_peer", PLAYER_B, true), _owner.call("_peer", PLAYER_C, false)
		]
		var lines: Array = _owner.call(
			"_captured_log_lines",
			func() -> void:
				_owner.call("_inject_plan", client, peers)
				var created: Array = _owner.call("_mesh_peers", mesh)
				var connection: Object = created[0]
				var transport: TransportScript = client.transport
				var before := transport.sent_text.size()
				if operation.begins_with("local_"):
					connection.call(
						"emit_session_description_created", operation.trim_prefix("local_"), "v=0"
					)
				elif operation.begins_with("remote_"):
					_inject_signal(
						client, {"Offer" if operation == "remote_offer" else "Answer": "v=0"}
					)
				elif operation == "poll":
					mesh.poll()
				_assert_equal(
					[PLAYER_C], mesh.get_peer_ids(), "%s releases only failed peer" % operation
				)
				_assert_equal(true, connection.get("closed"), "%s closes connection" % operation)
				_assert_equal(
					[],
					_owner.call("_sent_after", client, before),
					"%s relays no unusable signal" % operation
				)
				_assert_equal(
					0,
					connection.get_signal_connection_list("session_description_created").size(),
					"SDP callback released"
				)
				_assert_equal(
					0,
					connection.get_signal_connection_list("ice_candidate_created").size(),
					"ICE callback released"
				)
		)
		_assert_equal(1, lines.size(), "%s reports one diagnostic" % operation)
		_owner.call("_inject_plan", client, peers, "40000000-0000-0000-0000-000000000002")
		_assert_equal(2, mesh.get_peer_count(), "%s permits fresh link" % operation)
		mesh.free()
		client.free()
	_done()


func _test_candidate_refusal_keeps_link_usable() -> void:
	var client: ClientScript = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	_inject_single_peer(client)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var connection: Object = created[0]
	connection.set("refused_operation", "add_ice_candidate")
	var lines: Array = _owner.call(
		"_captured_log_lines",
		func() -> void: _inject_signal(client, {"IceCandidate": "cand:refused"})
	)
	_assert_equal(1, lines.size(), "candidate refusal is observable")
	_assert_equal(1, mesh.get_peer_count(), "one refused candidate keeps peer")
	connection.set("refused_operation", "")
	_inject_signal(client, {"IceCandidate": "cand:usable"})
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	var transport: TransportScript = client.transport
	var before := transport.sent_text.size()
	mesh.poll()
	var candidates: Array = connection.get("added_candidates")
	_assert_equal(2, candidates.size(), "later candidate reaches engine")
	_assert_equal(1, transport.sent_text.size() - before, "later candidate can establish transport")
	mesh.free()
	client.free()
	_done()


func _test_candidate_wire_formats() -> void:
	var client: ClientScript = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	_inject_single_peer(client)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var connection: Object = created[0]
	var candidate := "candidate:1 1 UDP 2122260223 192.0.2.1 5000 typ host"
	var cases: Array[Array] = [
		[candidate, ["", 0, candidate]],
		[" " + candidate + " ", ["", 0, " " + candidate + " "]],
		[
			JSON.stringify(
				{
					"candidate": candidate,
					"sdpMid": "data",
					"sdpMLineIndex": 2,
					"usernameFragment": null
				}
			),
			["data", 2, candidate]
		],
		[
			JSON.stringify({"candidate": candidate, "sdpMid": null, "sdpMLineIndex": null}),
			["", 0, candidate]
		],
		[JSON.stringify({"candidate": candidate}), ["", 0, candidate]],
		[JSON.stringify({"candidate": "", "sdpMid": "0", "sdpMLineIndex": 0}), ["0", 0, ""]],
	]
	var applied_count := 0
	for sample: Array in cases:
		_inject_signal(client, {"IceCandidate": sample[0]})
		var applied: Array = connection.get("added_candidates")
		applied_count += 1
		_assert_equal(applied_count, applied.size(), "each candidate reaches the engine once")
		_assert_equal(sample[1], applied.back(), "candidate media, index and line reach engine")
	var candidates: Array = connection.get("added_candidates")
	var before := candidates.size()
	for malformed: Variant in [
		42,
		{},
		"{",
		"{}",
		'{"candidate":null}',
		'{"candidate":false}',
		'{"candidate":"line","sdpMid":3}',
		'{"candidate":"line","sdpMLineIndex":false}',
		'{"candidate":"line","sdpMLineIndex":-1}',
		'{"candidate":"line","sdpMLineIndex":0.5}',
		'{"candidate":"line","sdpMLineIndex":65536}',
	]:
		var lines: Array = _owner.call(
			"_captured_log_lines",
			func() -> void: _inject_signal(client, {"IceCandidate": malformed})
		)
		_assert_equal(1, lines.size(), "invalid envelope reports one diagnostic")
	_assert_equal(before, candidates.size(), "invalid envelopes skip engine")
	_assert_equal(1, mesh.get_peer_count(), "invalid envelope keeps negotiation available")
	_inject_signal(client, {"IceCandidate": candidate})
	_assert_equal(before + 1, candidates.size(), "later raw candidate works")
	mesh.free()
	client.free()
	_done()


func _test_poll_failure_reports_down() -> void:
	var client: ClientScript = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	_inject_single_peer(client)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var connection: Object = created[0]
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()
	connection.set("refused_operation", "poll")
	var transport: TransportScript = client.transport
	var before := transport.sent_text.size()
	mesh.poll()
	var sent: String = transport.sent_text.back()
	var message: Dictionary = JSON.parse_string(sent)
	_assert_equal(1, transport.sent_text.size() - before, "last failed peer reports down")
	_assert_equal(false, message["data"]["connected"], "transport report is disconnected")
	mesh.poll()
	_assert_equal(1, transport.sent_text.size() - before, "down report stays once")
	mesh.free()
	client.free()
	_done()


func _inject_signal(client: ClientScript, payload: Dictionary) -> void:
	var transport: TransportScript = client.transport
	transport.inject_server_message(
		{"type": "Signal", "data": {"from": PLAYER_B, "generation": GENERATION, "signal": payload}}
	)


func _inject_single_peer(client: ClientScript) -> void:
	var peers: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, false)]
	_owner.call("_inject_plan", client, peers)


func _test_terminal_links_release_and_retry() -> void:
	for terminal: String in [
		"disconnected", "failed", "closed", "removed", "channel_closing", "channel_closed"
	]:
		var client: ClientScript = _owner.call("_make_in_room_client")
		var mesh: MeshScript = _owner.call("_make_mesh")
		_owner.call("_attach", mesh, client)
		var plan_peers: Array[Dictionary] = [
			_owner.call("_peer", PLAYER_B, false), _owner.call("_peer", PLAYER_C, false)
		]
		_owner.call("_inject_plan", client, plan_peers)
		var created: Array = _owner.call("_mesh_peers", mesh)
		var pc: Object = created[0]
		var unrelated: Object = created[1]
		unrelated.set("state", WebRTCPeerConnection.STATE_CONNECTING)
		var transport: TransportScript = client.transport
		var before := transport.sent_text.size()
		pc.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		mesh.poll()
		if terminal == "removed":
			var multiplayer: Object = _owner.call("_mesh_multiplayer", mesh)
			multiplayer.call("remove_peer", MeshScript.uuid_to_peer_id(PLAYER_B))
		elif terminal.begins_with("channel_"):
			var channels: Array = pc.get("channels")
			var channel: Object = channels[0]
			channel.set(
				"state",
				(
					WebRTCDataChannel.STATE_CLOSING
					if terminal == "channel_closing"
					else WebRTCDataChannel.STATE_CLOSED
				)
			)
		else:
			pc.set(
				"state",
				(
					WebRTCPeerConnection.STATE_FAILED
					if terminal == "failed"
					else (
						WebRTCPeerConnection.STATE_DISCONNECTED
						if terminal == "disconnected"
						else WebRTCPeerConnection.STATE_CLOSED
					)
				)
			)
		mesh.poll()
		_assert_equal(1, mesh.get_peer_count(), terminal + ": terminal link released")
		_assert_equal(true, pc.get("closed"), terminal + ": connection closed")
		_assert_equal(
			0,
			pc.get_signal_connection_list("ice_candidate_created").size(),
			terminal + ": callbacks released"
		)
		_assert_equal(false, unrelated.get("closed"), terminal + ": connecting peer survives")
		mesh.poll()
		_assert_equal(
			2, transport.sent_text.size() - before, terminal + ": up and down report once"
		)
		_owner.call("_inject_plan", client, plan_peers)
		_assert_equal(3, created.size(), terminal + ": repeated plan replaces dead link")
		var replacement: Object = created.back()
		replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		mesh.poll()
		_assert_equal(3, transport.sent_text.size() - before, terminal + ": replacement reports up")
		mesh.free()
		client.free()
	_done()


func _test_room_reset_during_status_refusal() -> void:
	for reset_kind: String in ["room", "plan", "duplicate"]:
		var client: ClientScript = _owner.call("_make_in_room_client")
		var mesh: MeshScript = _owner.call("_make_mesh")
		mesh.transport_status_retry_msec = 60000
		_owner.call("_attach", mesh, client)
		_inject_single_peer(client)
		var created: Array = _owner.call("_mesh_peers", mesh)
		var pc: Object = created[0]
		pc.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		var transport: TransportScript = client.transport
		transport.buffered_amount = 262145
		client.protocol_error.connect(
			func(_message: String) -> void:
				transport.buffered_amount = 0
				if reset_kind == "room":
					transport.inject_server_message(
						{"type": "RoomJoined", "data": ClientFixtures.room_joined_data()}
					)
				var plan_peers: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, false)]
				_owner.call(
					"_inject_plan",
					client,
					plan_peers,
					(
						GENERATION
						if reset_kind == "duplicate"
						else "40000000-0000-0000-0000-000000000002"
					)
				),
			CONNECT_ONE_SHOT
		)
		mesh.poll()
		_assert_equal(
			1 if reset_kind == "duplicate" else 2,
			created.size(),
			"status refusal handler applies plan"
		)
		var replacement: Object = created.back()
		replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		var before := transport.sent_text.size()
		mesh.poll()
		_assert_equal(
			0 if reset_kind == "duplicate" else 1,
			transport.sent_text.size() - before,
			"fresh status reports immediately; duplicate plans keep the throttle"
		)
		mesh.free()
		client.free()
	_done()


func _test_session_loss_releases_mesh() -> void:
	var client: ClientScript = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	_inject_single_peer(client)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var pc: Object = created[0]
	var transport: TransportScript = client.transport
	transport.inject_server_message(
		{
			"type": "AuthenticationError",
			"data": {"error": "session ended", "error_code": "UNAUTHORIZED"}
		}
	)
	_assert_equal("", client.get_room_id(), "session loss clears room")
	_assert_equal(0, mesh.get_peer_count(), "session loss releases mesh immediately")
	_assert_equal(true, pc.get("closed"), "session loss closes connection")
	_assert_equal(null, mesh.get_multiplayer_peer(), "session loss releases multiplayer peer")
	mesh.detach()
	_assert_equal(
		0,
		client.get_signal_connection_list("authentication_error").size(),
		"detach releases session listener"
	)
	client.free()
	client = _owner.call("_make_in_room_client")
	_owner.call("_attach", mesh, client)
	_inject_single_peer(client)
	_assert_equal(1, mesh.get_peer_count(), "fresh room restores mesh after session loss")
	mesh.free()
	client.free()
	_done()
