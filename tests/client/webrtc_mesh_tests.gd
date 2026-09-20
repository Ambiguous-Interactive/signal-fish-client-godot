extends RefCounted

## WebRTC mesh glue tests (PLAN P3, issue #32). Deterministic: the mesh's
## peer-connection and multiplayer-peer factories are injected fakes, so no
## real WebRTC runs in fast gates (PLAN §8). Receives the client runner
## instance so connect/auth fakes stay defined in one place.

const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFWebRTCMeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_C := "10000000-0000-0000-0000-000000000003"
const PLAYER_D := "10000000-0000-0000-0000-000000000004"
# Pinned FNV-1a vectors: the UUID -> peer-id mapping must stay stable across
# versions and platforms (mesh members derive the same ids independently).
# Valid ids are 2..2^31-1: 0 is invalid, 1 is the reserved server id.
const PLAYER_A_PEER_ID := 1186410739
const PLAYER_B_PEER_ID := 1186411174

const STUN := {"urls": ["stun:stun.example:3478"]}
const TURN := {"urls": ["turn:turn.example:3478"], "username": "alice", "credential": "turn-secret"}

var _failures: Array = []
var _runner: Variant = null


static func run(runner) -> Array:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_engine_api_parity()
	_test_uuid_mapping_is_deterministic()
	_test_attach_and_detach_guards()
	_test_plan_opens_peers_and_reports_boundaries()
	_test_plan_replaces_fully()
	_test_ice_replace_and_clear()
	_test_signal_gates()
	_test_new_peer_event_obey_flag()
	_test_teardown_paths()
	_test_mesh_survives_engine_hostility()


func _test_engine_api_parity() -> void:
	# The fakes duck-type the engine classes, so a renamed engine method would
	# silently false-pass (this exact trap: create_mesh was once asserted as
	# initialize_mesh). Fail loudly if the API the mesh calls drifts.
	for method: String in ["create_mesh", "add_peer", "remove_peer", "close"]:
		_assert(
			ClassDB.class_has_method("WebRTCMultiplayerPeer", method),
			"WebRTCMultiplayerPeer.%s exists" % method
		)
	for method: String in [
		"initialize",
		"create_offer",
		"set_local_description",
		"set_remote_description",
		"add_ice_candidate",
		"poll",
		"close",
		"get_connection_state",
	]:
		_assert(
			ClassDB.class_has_method("WebRTCPeerConnection", method),
			"WebRTCPeerConnection.%s exists" % method
		)


func _make_mesh() -> SFWebRTCMeshScript:
	var mesh := SFWebRTCMeshScript.new()
	var created: Array = []
	mesh.peer_connection_factory = func():
		var pc := FakePeerConnection.new()
		created.append(pc)
		return pc
	var multiplayer := FakeMultiplayerPeer.new()
	mesh.multiplayer_peer_factory = func(): return multiplayer
	mesh.set_meta("created", created)
	mesh.set_meta("multiplayer", multiplayer)
	return mesh


func _mesh_peers(mesh: SFWebRTCMeshScript) -> Array:
	return mesh.get_meta("created")


func _mesh_multiplayer(mesh: SFWebRTCMeshScript):
	return mesh.get_meta("multiplayer")


func _attach(mesh: SFWebRTCMeshScript, client: SignalFishClientScript) -> void:
	_assert_equal(OK, mesh.attach(client), "mesh attach")


func _make_in_room_client() -> SignalFishClientScript:
	return _runner._make_in_room_client()


func _track_protocol_errors(client: SignalFishClientScript) -> Array:
	return _runner._track_protocol_errors(client)


func _inject_plan(
	client: SignalFishClientScript,
	peers: Array,
	generation: String = "gen-1",
	transport: String = "webrtc",
	ice_servers: Variant = null,
	topology: String = "mesh"
) -> void:
	var data: Dictionary = {
		"generation": generation,
		"topology": topology,
		"transport": transport,
		"peers": peers,
		"fallback": "relay",
	}
	if ice_servers != null:
		data["ice_servers"] = ice_servers
	client.transport.inject_server_message({"type": "SessionPlan", "data": data})


func _peer(player_id: String, initiate: bool) -> Dictionary:
	return {
		"player_id": player_id,
		"player_name": "P",
		"is_authority": false,
		"initiate": initiate,
	}


func _sent_after(client: SignalFishClientScript, before: int) -> Array:
	return client.transport.sent_text.slice(before)


func _test_uuid_mapping_is_deterministic() -> void:
	_assert_equal(
		PLAYER_A_PEER_ID, SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_A), "pinned player A vector"
	)
	_assert_equal(PLAYER_B_PEER_ID, SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_B), "pinned B vector")
	_assert_equal(
		SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_A),
		SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_A),
		"mapping is pure"
	)
	_assert_not_equal(
		SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_A),
		SFWebRTCMeshScript.uuid_to_peer_id(PLAYER_B),
		"distinct uuids map apart"
	)
	for uuid: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, ""]:
		var id: int = SFWebRTCMeshScript.uuid_to_peer_id(uuid)
		_assert(id >= 2 and id < 2147483648, "id in the valid non-server range for %s" % uuid)


func _test_attach_and_detach_guards() -> void:
	var mesh := _make_mesh()
	_assert_equal(ERR_INVALID_PARAMETER, mesh.attach(null), "null client rejected")
	var client := _make_in_room_client()
	var errors := _track_protocol_errors(client)
	_attach(mesh, client)
	_assert_equal(ERR_BUSY, mesh.attach(client), "double attach rejected")
	_assert_equal(0, errors.size(), "attach is silent")
	mesh.free()
	client.free()

	# Detach unwires events: later plans cannot touch the mesh, and a fresh
	# attach works.
	var second := _make_mesh()
	var second_client := _make_in_room_client()
	_attach(second, second_client)
	second.detach()
	_inject_plan(second_client, [_peer(PLAYER_B, true)])
	_assert_equal(0, second.get_peer_count(), "detached mesh ignores plans")
	_assert_equal(null, second.get_multiplayer_peer(), "detached mesh releases the peer")
	_attach(second, second_client)
	second.free()
	second_client.free()


func _test_plan_opens_peers_and_reports_boundaries() -> void:
	var client := _make_in_room_client()
	var errors := _track_protocol_errors(client)
	var mesh := _make_mesh()
	_attach(mesh, client)
	var multiplayer = _mesh_multiplayer(mesh)

	_inject_plan(client, [_peer(PLAYER_B, true)], "gen-1", "webrtc", [STUN, TURN])
	var peers := _mesh_peers(mesh)
	_assert_equal(1, peers.size(), "plan opens one peer connection")
	var pc = peers[0]
	_assert_equal(
		{"iceServers": [STUN, TURN]}, pc.initialize_config, "ice config carries the plan list"
	)
	_assert_equal([[pc, PLAYER_B_PEER_ID]], multiplayer.added, "mesh peer added with mapped id")
	_assert_equal(
		PLAYER_A_PEER_ID, multiplayer.mesh_id, "multiplayer id derives from the local uuid"
	)
	_assert_equal(1, pc.create_offer_calls, "initiate flag drives the offer")

	# Offer path: session_description_created -> set_local + Signal relayed.
	var before: int = client.transport.sent_text.size()
	pc.emit_session_description_created("offer", "v=0")
	_assert_equal(["offer", "v=0"], pc.local_description, "local description set")
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.peer_signal(PLAYER_B, "gen-1", {"Offer": "v=0"})
			)
		],
		_sent_after(client, before),
		"offer relayed to the peer"
	)

	# Trickle ICE out and in (the empty marker is not relayed).
	pc.emit_ice_candidate_created("", 0, "cand:1")
	pc.emit_ice_candidate_created("", 0, "")
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.peer_signal(PLAYER_B, "gen-1", {"IceCandidate": "cand:1"})
			)
		],
		_sent_after(client, before + 1),
		"candidate relayed, end marker skipped"
	)
	(
		client
		. transport
		. inject_server_message(
			{
				"type": "Signal",
				"data":
				{
					"from": PLAYER_B,
					"generation": "gen-1",
					"signal": {"IceCandidate": "cand:2"},
				}
			}
		)
	)
	_assert_equal([["", 0, "cand:2"]], pc.added_candidates, "inbound candidate applied")

	# Answer path.
	(
		client
		. transport
		. inject_server_message(
			{
				"type": "Signal",
				"data": {"from": PLAYER_B, "generation": "gen-1", "signal": {"Answer": "v=1"}},
			}
		)
	)
	_assert_equal(["answer", "v=1"], pc.remote_description, "answer applied")

	# Aggregate connected boundary: 0 -> 1 exactly once, 1 -> 0 exactly once.
	pc.state = 2  # WebRTCPeerConnection.STATE_CONNECTED
	mesh.poll()
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.transport_status(SFSessionTypesScript.TransportKind.WEBRTC, true)
			)
		],
		_sent_after(client, before + 2),
		"connected boundary reported once"
	)
	pc.poll_calls = 0
	mesh.poll()
	_assert_equal(1, pc.poll_calls, "poll pumps the connection")
	_assert_equal(before + 3, client.transport.sent_text.size(), "no duplicate status")
	pc.state = 4  # WebRTCPeerConnection.STATE_FAILED
	mesh.poll()
	_assert_equal(
		[
			SFMessagesScript.encode(
				SFMessagesScript.transport_status(SFSessionTypesScript.TransportKind.WEBRTC, false)
			)
		],
		_sent_after(client, before + 3),
		"disconnected boundary reported once"
	)
	_assert_equal(0, errors.size(), "happy path emits no protocol errors")
	mesh.free()
	client.free()


func _test_plan_replaces_fully() -> void:
	var client := _make_in_room_client()
	var mesh := _make_mesh()
	_attach(mesh, client)
	var multiplayer = _mesh_multiplayer(mesh)

	_inject_plan(client, [_peer(PLAYER_B, true), _peer(PLAYER_C, false)])
	var peers := _mesh_peers(mesh)
	_assert_equal(2, peers.size(), "two peers opened")
	_assert_equal(1, peers[0].create_offer_calls, "B offers (server flag)")
	_assert_equal(0, peers[1].create_offer_calls, "C answers, never offers")
	var b_pc = peers[0]
	var c_pc = peers[1]
	_assert_equal(
		[[b_pc, PLAYER_B_PEER_ID]], multiplayer.added.slice(0, 1), "mesh peers added in plan order"
	)

	# The identical plan again: nothing rebuilds.
	_inject_plan(client, [_peer(PLAYER_B, true), _peer(PLAYER_C, false)])
	_assert_equal(2, _mesh_peers(mesh).size(), "no extra connections")
	_assert(_mesh_peers(mesh)[0] == b_pc, "B retained verbatim")
	_assert(not b_pc.closed, "retained peer untouched")

	# Generation change rebuilds retained peers; D joins.
	_inject_plan(
		client, [_peer(PLAYER_B, true), _peer(PLAYER_C, true), _peer(PLAYER_D, false)], "gen-2"
	)
	_assert_equal(5, _mesh_peers(mesh).size(), "both retained peers rebuilt, D added")
	_assert(b_pc.closed, "B rebuilt on generation change")
	_assert(c_pc.closed, "C rebuilt on role flip")
	var rebuilt := _mesh_peers(mesh).slice(2)
	_assert_equal(1, rebuilt[0].create_offer_calls, "rebuilt B offers again")
	_assert_equal(1, rebuilt[1].create_offer_calls, "rebuilt C now offers")
	_assert_equal(0, rebuilt[2].create_offer_calls, "D still answers")
	_assert_equal(5, multiplayer.added.size(), "3 opens + 2 rebuilds added")
	_assert_equal(2, multiplayer.removed.size(), "both stale peers removed on rebuild")

	# Latest plan wins: peers absent from the new plan are disconnected.
	_inject_plan(client, [_peer(PLAYER_B, true)], "gen-2")
	_assert_equal(1, mesh.get_peer_count(), "absent peers dropped")
	_assert(rebuilt[1].closed, "C closed when dropped")
	_assert(rebuilt[2].closed, "D closed when dropped")
	_assert_equal(4, multiplayer.removed.size(), "C and D removed from the mesh roster")

	# Relay-floor reset: the transport is not webrtc, so the mesh empties.
	_inject_plan(client, [], "gen-3", "relay")
	_assert_equal(0, mesh.get_peer_count(), "relay plan empties the mesh")
	_assert(rebuilt[0].closed, "B closed on relay reset")
	_assert(not multiplayer.closed, "multiplayer peer survives plan churn until teardown")

	# A host+direct plan carries peers but no WebRTC data path for this mesh:
	# it must not open connections whose signals would be gated away.
	_inject_plan(client, [_peer(PLAYER_C, true)], "gen-4", "direct", null, "host")
	_assert_equal(0, mesh.get_peer_count(), "non-webrtc plan with peers stays empty")
	_assert_equal(5, multiplayer.added.size(), "no peer opened for the direct plan")
	mesh.free()
	client.free()


func _test_ice_replace_and_clear() -> void:
	var client := _make_in_room_client()
	var mesh := _make_mesh()
	_attach(mesh, client)
	# RoomJoined pre-gather seeds ICE until the first plan lands.
	client.transport.inject_server_message(
		{"type": "RoomJoined", "data": _runner._room_joined_data({"ice_servers": [TURN]})}
	)
	_inject_plan(client, [_peer(PLAYER_B, false)], "gen-1", "webrtc", [])
	_assert_equal([], _mesh_peers(mesh)[0].initialize_config["iceServers"], "empty plan clears ICE")
	var clear_pc = _mesh_peers(mesh)[0]

	# The next plan replaces (never merges) the list for new connections.
	_inject_plan(client, [_peer(PLAYER_C, false)], "gen-2", "webrtc", [STUN])
	_assert_equal([STUN], _mesh_peers(mesh)[1].initialize_config["iceServers"], "plan ICE applied")
	_assert(clear_pc.closed, "previous-generation peer rebuilt")
	mesh.free()
	client.free()


func _test_signal_gates() -> void:
	var client := _make_in_room_client()
	var errors := _track_protocol_errors(client)
	var mesh := _make_mesh()
	_attach(mesh, client)

	# No plan yet: signals are discarded.
	client.transport.inject_server_message(
		{"type": "Signal", "data": {"from": PLAYER_B, "generation": "gen-1", "signal": {}}}
	)
	_assert_equal(0, mesh.get_peer_count(), "no peers without a plan")

	# Peer B answers under gen-1.
	_inject_plan(client, [_peer(PLAYER_B, false)])
	var pc = _mesh_peers(mesh)[0]
	var discards := [
		["wrong generation", {"from": PLAYER_B, "generation": "gen-9", "signal": {"Answer": "x"}}],
		["unknown sender", {"from": PLAYER_C, "generation": "gen-1", "signal": {"Answer": "x"}}],
		["non-dictionary payload", {"from": PLAYER_B, "generation": "gen-1", "signal": "x"}],
		["opaque payload", {"from": PLAYER_B, "generation": "gen-1", "signal": {"Zorp": 1}}],
	]
	for discard: Array in discards:
		client.transport.inject_server_message({"type": "Signal", "data": discard[1]})
		_assert_equal([], pc.remote_description, "%s discarded" % discard[0])
	_assert_equal(0, errors.size(), "discards stay silent")
	_assert_equal(1, mesh.get_peer_count(), "signals never invent or remove peers")

	# A relay-transport plan closes the gate entirely.
	_inject_plan(client, [], "gen-2", "relay")
	(
		client
		. transport
		. inject_server_message(
			{
				"type": "Signal",
				"data": {"from": PLAYER_B, "generation": "gen-2", "signal": {"Answer": "x"}},
			}
		)
	)
	_assert_equal(0, mesh.get_peer_count(), "relay gate holds")
	mesh.free()
	client.free()


func _test_new_peer_event_obey_flag() -> void:
	var client := _make_in_room_client()
	var mesh := _make_mesh()
	_attach(mesh, client)
	_inject_plan(client, [], "gen-1")

	client.transport.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": true}}
	)
	_assert_equal(1, mesh.get_peer_count(), "new peer opened")
	_assert_equal(1, _mesh_peers(mesh)[0].create_offer_calls, "you_initiate drives the offer")

	# Duplicate directive: already known, ignored.
	client.transport.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": false}}
	)
	_assert_equal(1, mesh.get_peer_count(), "duplicate new_peer ignored")
	_assert_equal(1, _mesh_peers(mesh)[0].create_offer_calls, "role never flipped locally")

	# Without a webrtc plan the directive is inert.
	_inject_plan(client, [], "gen-2", "relay")
	client.transport.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_C, "you_initiate": true}}
	)
	_assert_equal(0, mesh.get_peer_count(), "relay plan gates new_peer")
	mesh.free()
	client.free()


func _test_teardown_paths() -> void:
	# player_left drops only that peer.
	var client := _make_in_room_client()
	var mesh := _make_mesh()
	_attach(mesh, client)
	_inject_plan(client, [_peer(PLAYER_B, true), _peer(PLAYER_C, false)])
	var peers := _mesh_peers(mesh)
	client.transport.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_C}})
	_assert_equal(1, mesh.get_peer_count(), "only the leaver dropped")
	_assert(peers[1].closed, "leaver connection closed")
	_assert(not peers[0].closed, "other peers untouched")
	mesh.free()
	client.free()

	for teardown: String in [
		"room_left",
		"disconnected",
		"connection_failed",
		"reconnected",
		"fresh room_joined",
	]:
		var teardown_client := _make_in_room_client()
		var teardown_mesh := _make_mesh()
		_attach(teardown_mesh, teardown_client)
		var multiplayer = _mesh_multiplayer(teardown_mesh)
		_inject_plan(teardown_client, [_peer(PLAYER_B, true)])
		var pc = _mesh_peers(teardown_mesh)[0]
		pc.state = 2  # WebRTCPeerConnection.STATE_CONNECTED
		teardown_mesh.poll()
		match teardown:
			"room_left":
				teardown_client.transport.inject_server_message({"type": "RoomLeft"})
			"disconnected":
				teardown_client.transport.inject_close(1000, "bye")
			"connection_failed":
				teardown_client.transport.inject_failure("socket dropped")
			"reconnected":
				var reconnected_data: Dictionary = _runner._room_joined_data()
				# The real replay shape carries full events, including plans:
				# none of them may revive the torn-down mesh.
				reconnected_data["missed_events"] = [
					{
						"type": "SessionPlan",
						"data":
						{
							"generation": "stale",
							"topology": "mesh",
							"transport": "webrtc",
							"peers": [_peer(PLAYER_C, true)],
							"fallback": "relay",
						},
					},
				]
				teardown_client.transport.inject_server_message(
					{"type": "Reconnected", "data": reconnected_data}
				)
			"fresh room_joined":
				teardown_client.transport.inject_server_message(
					{"type": "RoomJoined", "data": _runner._room_joined_data()}
				)
		_assert_equal(0, teardown_mesh.get_peer_count(), "%s empties the mesh" % teardown)
		_assert(pc.closed, "%s closes connections" % teardown)
		_assert(multiplayer.closed, "%s closes the multiplayer peer" % teardown)
		_assert_equal(null, teardown_mesh.get_multiplayer_peer(), "%s releases the peer" % teardown)
		# Stale signaling after teardown must stay inert (only teardowns that
		# keep the link, e.g. room_left, still have a transport).
		if teardown_client.transport != null:
			(
				teardown_client
				. transport
				. inject_server_message(
					{
						"type": "Signal",
						"data":
						{"from": PLAYER_B, "generation": "gen-1", "signal": {"Answer": "late"}},
					}
				)
			)
		_assert_equal(0, teardown_mesh.get_peer_count(), "%s keeps the gate shut" % teardown)
		teardown_mesh.free()
		teardown_client.free()

	# _exit_tree detaches and tears down; events after removal are ignored.
	var exit_client := _make_in_room_client()
	var exit_mesh := _make_mesh()
	_attach(exit_mesh, exit_client)
	_inject_plan(exit_client, [_peer(PLAYER_B, false)])
	exit_mesh._exit_tree()
	_assert_equal(0, exit_mesh.get_peer_count(), "exit tree tears down")
	_inject_plan(exit_client, [_peer(PLAYER_C, false)])
	_assert_equal(0, exit_mesh.get_peer_count(), "detached mesh ignores later plans")
	exit_mesh.free()
	exit_client.free()


func _test_mesh_survives_engine_hostility() -> void:
	# A freed client (legal: independent nodes) must not leave the mesh poking
	# a dangling reference from _process.
	var client := _make_in_room_client()
	var mesh := _make_mesh()
	_attach(mesh, client)
	_inject_plan(client, [_peer(PLAYER_B, false)])
	_assert_equal(1, mesh.get_peer_count(), "peer opened before client free")
	client.free()
	mesh._process(0.016)
	_assert_equal(0, mesh.get_peer_count(), "freed client tears the mesh down")
	_assert_equal(null, mesh.get_multiplayer_peer(), "freed client releases the peer")
	mesh.free()

	# A refused create_mesh leaves no half-built mesh: peers stay closed.
	var refused := _make_mesh()
	(_mesh_multiplayer(refused) as FakeMultiplayerPeer).create_mesh_result = ERR_UNAVAILABLE
	var refused_client := _make_in_room_client()
	var refused_errors := _track_protocol_errors(refused_client)
	_attach(refused, refused_client)
	_inject_plan(refused_client, [_peer(PLAYER_B, true)])
	_assert_equal(0, refused.get_peer_count(), "refused mesh opens no peers")
	_assert_equal(null, refused.get_multiplayer_peer(), "refused mesh releases the peer")
	_assert_equal(1, _mesh_peers(refused).size(), "one connection was attempted")
	_assert(_mesh_peers(refused)[0].closed, "attempted connection closed")
	_assert_equal(0, refused_errors.size(), "refusal is quiet, not a protocol error")
	refused.free()
	refused_client.free()

	# A zombie mesh (client freed without a poll since) resolves on re-attach
	# instead of carrying stale peers onto the fresh client.
	var zombie_client := _make_in_room_client()
	var zombie_mesh := _make_mesh()
	_attach(zombie_mesh, zombie_client)
	_inject_plan(zombie_client, [_peer(PLAYER_B, false)])
	zombie_client.free()
	var fresh_client := _make_in_room_client()
	_attach(zombie_mesh, fresh_client)
	_assert_equal(0, zombie_mesh.get_peer_count(), "re-attach starts clean")
	_inject_plan(fresh_client, [_peer(PLAYER_C, true)])
	_assert_equal(1, zombie_mesh.get_peer_count(), "fresh client drives the mesh")
	zombie_mesh.free()
	fresh_client.free()


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


func _assert_not_equal(unexpected: Variant, actual: Variant, label: String) -> bool:
	if unexpected == actual:
		_failures.append(
			"%s: expected values to differ, both were %s" % [label, var_to_str(actual)]
		)
		return false
	return true


class FakePeerConnection:
	extends RefCounted
	## Duck-typed WebRTCPeerConnection double: records calls, never networks.

	signal session_description_created(type: String, sdp: String)
	signal ice_candidate_created(media: String, index: int, name: String)

	var state: int = 0  # WebRTCPeerConnection.STATE_NEW
	var initialize_config = null
	var initialize_result: Error = OK
	var create_offer_calls := 0
	var local_description: Array = []
	var remote_description: Array = []
	var added_candidates: Array = []
	var poll_calls := 0
	var closed := false

	func initialize(configuration) -> Error:
		initialize_config = configuration
		return initialize_result

	func create_offer() -> Error:
		create_offer_calls += 1
		return OK

	func set_local_description(type: String, sdp: String) -> void:
		local_description = [type, sdp]

	func set_remote_description(type: String, sdp: String) -> void:
		remote_description = [type, sdp]

	func add_ice_candidate(media: String, index: int, name: String) -> Error:
		added_candidates.append([media, index, name])
		return OK

	func get_connection_state() -> int:
		return state

	func poll() -> void:
		poll_calls += 1

	func close() -> void:
		closed = true

	func emit_session_description_created(type: String, sdp: String) -> void:
		session_description_created.emit(type, sdp)

	func emit_ice_candidate_created(media: String, index: int, name: String) -> void:
		ice_candidate_created.emit(media, index, name)


class FakeMultiplayerPeer:
	extends RefCounted
	## Duck-typed WebRTCMultiplayerPeer double.

	var mesh_id := 0
	var create_mesh_result: Error = OK
	var added: Array = []
	var removed: Array = []
	var closed := false

	func create_mesh(unique_id: int) -> Error:
		if create_mesh_result == OK:
			mesh_id = unique_id
		return create_mesh_result

	func add_peer(connection, unique_id: int) -> Error:
		added.append([connection, unique_id])
		return OK

	func remove_peer(unique_id: int) -> void:
		removed.append(unique_id)

	func close() -> void:
		closed = true
