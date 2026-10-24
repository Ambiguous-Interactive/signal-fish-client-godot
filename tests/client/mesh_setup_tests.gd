extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const TransportScript = preload("res://tests/transport/sf_fake_transport.gd")
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
		_test_poll_failure_reports_down,
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
