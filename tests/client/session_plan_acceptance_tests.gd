extends RefCounted

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFWebRTCMeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_C := "10000000-0000-0000-0000-000000000003"
const STUN := {"urls": ["stun:stun.example:3478"]}

var _failures: Array[String] = []
var _test_done := false
var _suite: Object


static func run(suite: Object) -> Array[String]:
	var tests := new()
	tests._suite = suite
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_direct_endpoint_refresh_and_relay_reset,
		_test_spectator_baseline_retires_mesh,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _make_in_room_client() -> SignalFishClientScript:
	return _suite.call("_make_in_room_client")


func _make_mesh() -> SFWebRTCMeshScript:
	return _suite.call("_make_mesh")


func _attach(mesh: SFWebRTCMeshScript, client: SignalFishClientScript) -> void:
	_suite.call("_attach", mesh, client)


func _track_protocol_errors(client: SignalFishClientScript) -> Array[String]:
	return _suite.call("_track_protocol_errors", client)


func _mesh_peers(mesh: SFWebRTCMeshScript) -> Array:
	return mesh.get_meta("created")


func _peer(player_id: String, initiate: bool) -> Dictionary:
	return _suite.call("_peer", player_id, initiate)


func _inject_plan(
	client: SignalFishClientScript,
	peers: Array[Dictionary],
	generation: String,
	transport: String,
	ice_servers: Array
) -> void:
	_suite.call("_inject_plan", client, peers, generation, transport, ice_servers)


func _assert(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)


## Issue #358: server PR #950, merge 154e5805c66beeb9b367f66382be40b543a3ef35.
## Direct sockets belong to the game; each plan signal must replace its endpoint.
func _test_direct_endpoint_refresh_and_relay_reset() -> void:
	var client := _make_in_room_client()
	var errors := _track_protocol_errors(client)
	var mesh := _make_mesh()
	_attach(mesh, client)
	var fake: SFFakeTransportScript = client.transport
	for player_id: String in [PLAYER_B, PLAYER_C]:
		fake.inject_server_message(
			{"type": "PlayerJoined", "data": {"player": ClientFixtures.player(player_id, "Peer")}}
		)
	var plans: Array[SFSessionTypesScript.SessionPlanInfo] = []
	client.session_plan.connect(
		func(plan: SFSessionTypesScript.SessionPlanInfo) -> void: plans.append(plan)
	)
	var received: Array[Array] = []
	client.game_data_received.connect(
		func(sender: String, data: Variant) -> void: received.append([sender, data])
	)
	_inject_plan(
		client, [_peer(PLAYER_B, false)], "40000000-0000-0000-0000-000000000001", "webrtc", [STUN]
	)
	var old_peer: Object = _mesh_peers(mesh)[0]
	var old_entries: Dictionary = mesh.get("_peers")
	var old_entry: Object = old_entries[PLAYER_B]
	var queued_session: Callable = old_entry.get("session_cb")
	var queued_candidate: Callable = old_entry.get("ice_cb")
	old_peer.set("state", 2)
	mesh.poll()
	var before := fake.sent_text.size()
	var rows: Array[Array] = [
		["40000000-0000-0000-0000-000000000002", PLAYER_B, "192.0.2.10", 7000],
		["40000000-0000-0000-0000-000000000003", PLAYER_B, "192.0.2.20", 8000],
		["40000000-0000-0000-0000-000000000004", PLAYER_C, "192.0.2.30", 9000],
		["40000000-0000-0000-0000-000000000005", "", "", 0],
		["40000000-0000-0000-0000-000000000005", "", "", 0],
	]
	for row: Array in rows:
		var relay: bool = row[1] == ""
		var data: Dictionary = {
			"generation": row[0],
			"topology": "relay" if relay else "host",
			"transport": "relay" if relay else "direct",
			"peers": [] if relay else [_peer(PLAYER_B, true), _peer(PLAYER_C, false)],
			"ice_servers": [],
			"fallback": "relay",
		}
		if not relay:
			data["host"] = row[1]
			data["direct_endpoint"] = {"host": row[2], "port": row[3]}
		if row[1] == PLAYER_C:
			fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_B}})
			data["peers"] = [_peer(PLAYER_C, false)]
		var plan_count := plans.size()
		fake.inject_server_message({"type": "SessionPlan", "data": data})
		_assert_equal(plan_count + 1, plans.size(), "every endpoint change and reset emits a plan")
		var latest: SFSessionTypesScript.SessionPlanInfo = plans.back()
		_assert_equal(row[0], latest.generation, "fresh generation reaches the game")
		_assert_equal(row[1], latest.host, "selected host replaces the old host")
		if row[1] == PLAYER_C:
			_assert_equal(1, latest.peers.size(), "successor plan excludes the departed host")
			_assert_equal(
				PLAYER_C, latest.peers[0].player_id, "successor plan matches the current roster"
			)
		_assert_equal(0, latest.ice_servers.size(), "empty ICE list clears the old plan")
		_assert_equal(
			SFSessionTypesScript.TransportKind.RELAY, latest.fallback, "relay fallback stays"
		)
		if relay:
			_assert(latest.direct_endpoint == null, "relay reset clears the endpoint")
			_assert_equal(0, latest.peers.size(), "relay reset clears peer obligations")
			_assert_equal(SFSessionTypesScript.Topology.RELAY, latest.topology, "relay topology")
			_assert_equal(
				SFSessionTypesScript.TransportKind.RELAY, latest.transport, "relay transport"
			)
		else:
			_assert(latest.direct_endpoint != null, "Direct plan has an endpoint")
			if latest.direct_endpoint != null:
				_assert_equal(
					row[2], latest.direct_endpoint.host, "host endpoint replaced immediately"
				)
				_assert_equal(row[3], latest.direct_endpoint.port, "host port replaced immediately")
			_assert_equal(SFSessionTypesScript.Topology.HOST, latest.topology, "host topology")
			_assert_equal(
				SFSessionTypesScript.TransportKind.DIRECT, latest.transport, "Direct transport"
			)
		_assert_equal(true, old_peer.get("closed"), "previous WebRTC connection is closed")
		_assert_equal(0, mesh.get_peer_count(), "Direct and relay never create WebRTC links")
		_assert_equal(latest, mesh.get("_plan"), "mesh replaces its whole plan")
		_assert_equal([], mesh.get("_ice_servers"), "mesh clears cached ICE servers")
		mesh.poll()
		_assert_equal(false, mesh.get("_reported_connected"), "old connected status clears")
		var stale_before := fake.sent_text.size()
		old_peer.call("emit_session_description_created", "offer", "old-offer")
		old_peer.call("emit_ice_candidate_created", "", 0, "old-candidate")
		for generation: String in ["40000000-0000-0000-0000-000000000001", row[0]]:
			fake.inject_server_message(
				{
					"type": "Signal",
					"data":
					{"from": PLAYER_B, "generation": generation, "signal": {"Offer": "stale"}}
				}
			)
		fake.inject_server_message(
			{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": true}}
		)
		mesh.poll()
		_assert_equal(stale_before, fake.sent_text.size(), "stale callbacks send no signaling")
		_assert_equal(0, mesh.get_peer_count(), "signals cannot revive a Direct or relay mesh")
		_assert_equal(
			[], old_peer.get("remote_description"), "old peer accepts no remote description"
		)
		_assert_equal(
			OK, client.send_game_data({"generation": row[0]}), "relay send remains usable"
		)
		_assert_equal(
			SFMessagesScript.encode(SFMessagesScript.game_data({"generation": row[0]})),
			fake.sent_text.back(),
			"game data stays on the WebSocket relay"
		)
		fake.inject_server_message(
			{"type": "GameData", "data": {"from_player": PLAYER_B, "data": {"generation": row[0]}}}
		)
		_assert_equal(
			[PLAYER_B, {"generation": row[0]}], received.back(), "relay receive stays usable"
		)
	var remaining_ids: Array[String] = []
	for player: Variant in client.get_players():
		remaining_ids.append(player.id)
	_assert_equal(
		[ClientFixtures.PLAYER_A, PLAYER_C],
		remaining_ids,
		"plan churn preserves ordered membership changes"
	)
	_assert_equal(rows.size(), received.size(), "each relay frame emits once")
	_assert_equal(
		SFMessagesScript.encode(
			SFMessagesScript.transport_status(SFSessionTypesScript.TransportKind.WEBRTC, false)
		),
		fake.sent_text[before],
		"leaving the live WebRTC plan reports its disconnected boundary"
	)
	_assert_equal(
		"192.0.2.10", plans[1].direct_endpoint.host, "later plans leave prior payloads intact"
	)
	var player_id := client.get_player_id()
	var room_id := client.get_room_id()
	fake.inject_close(4999, "reset link lost")
	_assert(mesh.get("_plan") == null, "disconnect clears the Relay reset plan")
	fake = SFFakeTransportScript.new()
	client.transport = fake
	_assert_equal(
		OK, client.reconnect(player_id, room_id, "reset-test-token"), "reconnect after reset"
	)
	fake.inject_open()
	fake.inject_server_message(
		{"type": "Authenticated", "data": ClientFixtures.authenticated_data()}
	)
	var baseline := ClientFixtures.room_joined_data()
	baseline["missed_events"] = [{"type": "SessionPlan", "data": plans[1].raw.duplicate(true)}]
	fake.inject_server_message({"type": "Reconnected", "data": baseline})
	_assert(mesh.get("_plan") == null, "historical Direct plan in replay stays inert")
	_inject_plan(client, [], "40000000-0000-0000-0000-000000000007", "relay", [])
	var reconnect_sends := fake.sent_text.size()
	queued_session.call("offer", "old-after-reconnect")
	queued_candidate.call("", 0, "old-after-reconnect")
	for generation: String in [
		"40000000-0000-0000-0000-000000000001",
		"40000000-0000-0000-0000-000000000005",
		"40000000-0000-0000-0000-000000000007",
	]:
		fake.inject_server_message(
			{
				"type": "Signal",
				"data": {"from": PLAYER_B, "generation": generation, "signal": {"Offer": "stale"}}
			}
		)
	fake.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": true}}
	)
	mesh.poll()
	_assert_equal(
		reconnect_sends, fake.sent_text.size(), "reset reconnect ignores old callbacks and signals"
	)
	_assert_equal(0, mesh.get_peer_count(), "reset reconnect cannot revive a peer")
	_assert_equal(1, _mesh_peers(mesh).size(), "reset reconnect creates no physical connection")
	_assert_equal(
		OK, client.send_game_data({"after_reset_reconnect": true}), "reset reconnect relay send"
	)
	fake.inject_server_message({"type": "RoomLeft"})
	_assert_equal(0, mesh.get_peer_count(), "leaving after reset remains clean")
	_assert(mesh.get("_plan") == null, "room exit clears reset identity")
	fake.inject_server_message({"type": "RoomJoined", "data": ClientFixtures.room_joined_data()})
	_inject_plan(
		client, [_peer(PLAYER_B, false)], "40000000-0000-0000-0000-000000000006", "webrtc", [STUN]
	)
	_assert_equal(1, mesh.get_peer_count(), "fresh room can establish a new mesh")
	var fresh_peer: Object = _mesh_peers(mesh).back()
	var fresh_sends := fake.sent_text.size()
	queued_session.call("offer", "old-room-offer")
	queued_candidate.call("", 0, "old-room-candidate")
	fake.inject_server_message(
		{
			"type": "Signal",
			"data":
			{
				"from": PLAYER_B,
				"generation": "40000000-0000-0000-0000-000000000001",
				"signal": {"Offer": "old-room-offer"}
			}
		}
	)
	_assert_equal(fresh_sends, fake.sent_text.size(), "old callbacks stay inert in a new room")
	_assert_equal(
		[], fresh_peer.get("remote_description"), "old-generation signal cannot reach fresh peer"
	)
	_assert(fresh_peer != old_peer, "fresh room gets a new physical connection")
	_assert_equal(
		{"iceServers": [STUN]}, fresh_peer.get("initialize_config"), "fresh plan supplies ICE"
	)
	_assert_equal([], errors, "plan refresh and relay reset produce no protocol errors")
	mesh.free()
	client.free()
	_done()


func _test_spectator_baseline_retires_mesh() -> void:
	var client := _make_in_room_client()
	var errors := _track_protocol_errors(client)
	var mesh := _make_mesh()
	_attach(mesh, client)
	_inject_plan(
		client, [_peer(PLAYER_B, false)], "40000000-0000-0000-0000-000000000001", "webrtc", [STUN]
	)
	var old_peer: Object = _mesh_peers(mesh)[0]
	old_peer.set("state", 2)
	mesh.poll()
	var fake: SFFakeTransportScript = client.transport
	var before := fake.sent_text.size()
	fake.inject_server_message(
		{"type": "SpectatorJoined", "data": ClientFixtures.spectator_joined_data()}
	)
	_assert_equal(
		true, old_peer.get("closed"), "spectator baseline closes the previous player mesh"
	)
	_assert_equal(0, mesh.get_peer_count(), "spectators retain no player links")
	_assert(mesh.get("_plan") == null, "spectator baseline clears the player plan")
	old_peer.call("emit_session_description_created", "offer", "old-offer")
	old_peer.call("emit_ice_candidate_created", "", 0, "old-candidate")
	fake.inject_server_message(
		{"type": "GameStarting", "data": {"peer_connections": [ClientFixtures.peer_connection()]}}
	)
	_inject_plan(
		client, [_peer(PLAYER_B, true)], "40000000-0000-0000-0000-000000000002", "webrtc", [STUN]
	)
	fake.inject_server_message(
		{"type": "NewPeer", "data": {"peer_id": PLAYER_C, "you_initiate": true}}
	)
	fake.inject_server_message(
		{
			"type": "Signal",
			"data":
			{
				"from": PLAYER_B,
				"generation": "40000000-0000-0000-0000-000000000002",
				"signal": {"Offer": "old-offer"}
			}
		}
	)
	mesh.poll()
	_assert_equal(
		0, mesh.get_peer_count(), "public lifecycle and stray plan cannot give a spectator peers"
	)
	_assert_equal(
		1, _mesh_peers(mesh).size(), "spectating opens no replacement physical connection"
	)
	_assert_equal(before, fake.sent_text.size(), "spectator sends no offers or transport reports")
	_assert_equal([], errors, "spectator transition emits no signaling errors")
	mesh.free()
	client.free()
	_done()
