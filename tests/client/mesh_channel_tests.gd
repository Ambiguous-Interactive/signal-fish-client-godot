extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const TransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const Messages = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const Session = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_C := "10000000-0000-0000-0000-000000000003"
const GENERATION := "40000000-0000-0000-0000-000000000001"
const OFFER_SDP := (
	"v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
	+ "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
)
const NEXT_GENERATION := "40000000-0000-0000-0000-000000000002"

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
		_test_required_channels_control_transport_reports,
		_test_closed_pair_is_rebuilt_in_room,
		_test_answerer_recovers_after_dropped_offer,
		_test_recovery_budget_and_retirement,
		_test_answerer_requests_after_restored_attempt,
		_test_malformed_offer_preserves_active_link,
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


func _test_required_channels_control_transport_reports() -> void:
	for channel_index: int in 3:
		for state: int in [WebRTCDataChannel.STATE_CLOSING, WebRTCDataChannel.STATE_CLOSED]:
			var client: ClientScript = _owner.call("_make_in_room_client")
			var mesh: MeshScript = _owner.call("_make_mesh")
			_owner.call("_attach", mesh, client)
			var peers: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, false)]
			_owner.call("_inject_plan", client, peers)
			var created: Array = _owner.call("_mesh_peers", mesh)
			var pc: Object = created[0]
			var channels: Array = pc.get("channels")
			var channel: Object = channels[channel_index]
			pc.set("state", WebRTCPeerConnection.STATE_CONNECTED)
			channel.set("state", WebRTCDataChannel.STATE_CONNECTING)
			var transport: TransportScript = client.transport
			var before: int = transport.sent_text.size()
			mesh.poll()
			_assert_equal(
				[],
				_owner.call("_sent_after", client, before),
				"pending required channel cannot report up"
			)
			channel.set("state", WebRTCDataChannel.STATE_OPEN)
			mesh.poll()
			_assert_equal(1, _sent_count(client, before), "all channels open reports up")
			channel.set("state", state)
			mesh.poll()
			_assert_equal(
				Messages.encode(Messages.transport_status(Session.TransportKind.WEBRTC, false)),
				transport.sent_text.back(),
				"closed required channel reports down while peer connection stays connected"
			)
			_assert_equal(
				WebRTCPeerConnection.STATE_CONNECTED,
				pc.get("state"),
				"physical connection is still connected"
			)
			var multiplayer: Object = _owner.call("_mesh_multiplayer", mesh)
			multiplayer.call("remove_peer", MeshScript.uuid_to_peer_id(PLAYER_B))
			channel.set("state", WebRTCDataChannel.STATE_OPEN)
			mesh.poll()
			_assert_equal(2, _sent_count(client, before), "engine removal cannot revive report")
			_owner.call("_inject_plan", client, peers, "40000000-0000-0000-0000-000000000002")
			var replacement: Object = created[1]
			replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
			mesh.poll()
			_assert_equal(3, _sent_count(client, before), "fresh link reports up again")
			mesh.free()
			client.free()
	_done()


func _sent_count(client: ClientScript, before: int) -> int:
	var sent: Array = _owner.call("_sent_after", client, before)
	return sent.size()


func _test_closed_pair_is_rebuilt_in_room() -> void:
	var fixture := _make_recovery_mesh(ClientFixtures.PLAYER_A, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var roster: Array[Dictionary] = [
		_owner.call("_peer", PLAYER_B, true),
		_owner.call("_peer", PLAYER_C, false),
	]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var old_pair: Object = created[0]
	var healthy_pair: Object = created[1]
	old_pair.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	healthy_pair.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()
	var multiplayer: Object = mesh.get_multiplayer_peer()
	var pair_id := MeshScript.uuid_to_peer_id(PLAYER_B)
	var healthy_id := MeshScript.uuid_to_peer_id(PLAYER_C)
	var channels: Array = old_pair.get("channels")
	var unreliable_channel: Object = channels[2]
	unreliable_channel.set("state", WebRTCDataChannel.STATE_CLOSED)
	for iteration: int in 5:
		mesh.poll()
	_assert_equal(true, old_pair.get("closed"), "failed pair's old connection retired")
	_assert_equal(multiplayer, mesh.get_multiplayer_peer(), "multiplayer identity preserved")
	var healthy: Dictionary = multiplayer.call("get_peer", healthy_id)
	_assert_equal(healthy_pair, healthy["connection"], "unrelated link is preserved")
	_assert_equal(false, healthy_pair.get("closed"), "unrelated link remains active")
	_assert_equal(
		3,
		created.size(),
		"closed unreliable link rebuilds exactly one connection without a fresh plan"
	)
	if created.size() == 3:
		var rebuilt: Object = created[2]
		var target: Dictionary = multiplayer.call("get_peer", pair_id)
		_assert_equal(rebuilt, target["connection"], "replacement uses the original peer ID")
		_assert_equal(1, rebuilt.get("create_offer_calls"), "replacement uses the accepted offerer")
	else:
		_owner.call("_inject_plan", client, roster, NEXT_GENERATION)
		_assert_equal(
			true, multiplayer.call("has_peer", pair_id), "control: real plan can open the pair"
		)
		if multiplayer.call("has_peer", pair_id):
			var control: Dictionary = multiplayer.call("get_peer", pair_id)
			var control_connection: Object = control["connection"]
			_assert_equal(
				1,
				control_connection.get("create_offer_calls"),
				"control: plan starts accepted offerer"
			)
	mesh.free()
	client.free()
	_done()


func _make_recovery_mesh(local_player: String, clock: Array[int]) -> Array:
	var client: ClientScript = _owner.call("_make_in_room_client")
	var transport: TransportScript = client.transport
	var players: Array[Dictionary] = [
		ClientFixtures.player(ClientFixtures.PLAYER_A, "A"),
		ClientFixtures.player(PLAYER_B, "B"),
		ClientFixtures.player(PLAYER_C, "C"),
	]
	for player: Dictionary in players:
		player["epoch"] = 1
		player["seq"] = 0
	(
		transport
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data":
				ClientFixtures.room_joined_data(
					{
						"current_players": players,
						"current_spectators": [],
						"player_id": local_player
					}
				),
			}
		)
	)
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	mesh.pair_recovery_enabled = true
	mesh.pair_recovery_retry_msec = 0
	mesh.pair_recovery_timeout_msec = 5
	mesh.pair_recovery_clock = func() -> int: return clock[0]
	return [client, mesh]


func _get_signals(client: ClientScript) -> Array[Dictionary]:
	var transport: TransportScript = client.transport
	var signals: Array[Dictionary] = []
	for frame: String in transport.sent_text:
		var parsed: Variant = JSON.parse_string(frame)
		if parsed is Dictionary:
			var event: Dictionary = parsed
			if event.get("type") == "Signal":
				signals.append(event["data"])
	return signals


func _deliver(client: ClientScript, sender: String, outbound: Dictionary) -> void:
	var transport: TransportScript = client.transport
	(
		transport
		. inject_server_message(
			{
				"type": "Signal",
				"data":
				{
					"from": sender,
					"generation": outbound["generation"],
					"signal": outbound["signal"]
				},
			}
		)
	)


func _close_unreliable(connection: Object) -> void:
	var channels: Array = connection.get("channels")
	var channel: Object = channels[2]
	channel.set("state", WebRTCDataChannel.STATE_CLOSED)


func _test_answerer_recovers_after_dropped_offer() -> void:
	var clock: Array[int] = [0]
	var a_id := ClientFixtures.PLAYER_A
	var a := _make_recovery_mesh(a_id, clock)
	var b := _make_recovery_mesh(PLAYER_B, clock)
	var offerer: ClientScript = a[0]
	var answerer: ClientScript = b[0]
	var offer_mesh: MeshScript = a[1]
	var answer_mesh: MeshScript = b[1]
	var offer_plan: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, true)]
	var answer_plan: Array[Dictionary] = [_owner.call("_peer", a_id, false)]
	_owner.call("_inject_plan", offerer, offer_plan)
	_owner.call("_inject_plan", answerer, answer_plan)
	var offers: Array = _owner.call("_mesh_peers", offer_mesh)
	var answers: Array = _owner.call("_mesh_peers", answer_mesh)
	var original_offer: Object = offers[0]
	var original_answer: Object = answers[0]
	var initial_entries: Dictionary = offer_mesh.get("_peers")
	var initial_entry: Object = initial_entries[PLAYER_B]
	var stale_description: Callable = initial_entry.get("session_cb")
	var stale_candidate: Callable = initial_entry.get("ice_cb")
	original_offer.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	original_answer.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	offer_mesh.poll()
	answer_mesh.poll()
	_close_unreliable(original_answer)
	answer_mesh.poll()
	answer_mesh.poll()
	var requests := _get_signals(answerer)
	_assert_equal(1, requests.size(), "only answerer sends one request before retry deadline")
	if requests.size() == 1:
		_deliver(offerer, PLAYER_B, requests[0])
		_deliver(offerer, PLAYER_B, requests[0])
	offer_mesh.poll()
	_assert_equal(2, offers.size(), "answerer request causes one offerer rebuild")
	if offers.size() == 2:
		var first: Object = offers[1]
		first.set(
			"local_description_hook",
			func() -> void: first.call("emit_session_description_created", "offer", "reentered")
		)
		first.call("emit_session_description_created", "offer", OFFER_SDP)
		var first_signals := _get_signals(offerer)
		_assert_equal(1, first_signals.size(), "reentrant local SDP only sends one offer")
		_assert_equal(
			["offer", OFFER_SDP],
			first.get("local_description"),
			"reentrant SDP cannot reach engine"
		)
	clock[0] = 4
	offer_mesh.poll()
	_assert_equal(2, offers.size(), "an unanswered offer retains its attempt before deadline")
	clock[0] = 5
	offer_mesh.poll()
	_assert_equal(3, offers.size(), "lost offer expires exactly at its deadline")
	if offers.size() == 3:
		var second: Object = offers[2]
		second.call("emit_ice_candidate_created", "", 0, "early")
		second.call("emit_session_description_created", "offer", OFFER_SDP)
		stale_description.call("offer", "retired")
		stale_candidate.call("", 0, "retired")
		var signals := _get_signals(offerer)
		_assert_equal(3, signals.size(), "replacement SDP precedes early ICE")
		if signals.size() == 3:
			var malformed: Dictionary = signals[1].duplicate(true)
			malformed["signal"]["MeshRecovery"]["to_epoch"] = 2
			_deliver(answerer, a_id, malformed)
			_assert_equal(1, answers.size(), "wrong endpoint epoch cannot allocate a pair")
			_deliver(answerer, a_id, signals[1])
			_deliver(answerer, a_id, signals[2])
			_deliver(answerer, a_id, signals[0])
			var conflicting: Dictionary = signals[1].duplicate(true)
			conflicting["signal"]["MeshRecovery"]["body"] = "conflicting-duplicate"
			_deliver(answerer, a_id, conflicting)
			_assert_equal(
				2, answers.size(), "answerer adopts one newer offer and rejects stale offers"
			)
			if answers.size() == 2:
				var reply: Object = answers[1]
				_assert_equal(0, reply.get("create_offer_calls"), "answerer never creates an offer")
				_assert_equal(
					["offer", OFFER_SDP], reply.get("remote_description"), "active offer applied"
				)
				_assert_equal(
					[["", 0, "early"]],
					reply.get("added_candidates"),
					"queued ICE applied after offer"
				)
				reply.call("emit_session_description_created", "answer", "second-reply")
				var sent_answers := _get_signals(answerer)
				var reply_envelope: Dictionary = sent_answers.back()
				var stale_reply: Dictionary = reply_envelope.duplicate(true)
				stale_reply["signal"]["MeshRecovery"]["attempt"] = 1
				_deliver(offerer, PLAYER_B, stale_reply)
				_deliver(
					offerer, PLAYER_B, {"generation": GENERATION, "signal": {"Answer": "legacy"}}
				)
				_assert_equal(
					[], second.get("remote_description"), "stale and legacy answers stay inert"
				)
				_deliver(offerer, PLAYER_B, reply_envelope)
				_assert_equal(
					["answer", "second-reply"],
					second.get("remote_description"),
					"matching answer applied"
				)
				reply.set("state", WebRTCPeerConnection.STATE_CONNECTED)
				second.set("state", WebRTCPeerConnection.STATE_CONNECTED)
				offer_mesh.poll()
				answer_mesh.poll()
				_deliver(offerer, PLAYER_B, requests[0])
				clock[0] = 20
				offer_mesh.poll()
				answer_mesh.poll()
				_assert_equal(3, offers.size(), "retired request and negotiation timer stay inert")
				_assert_equal(2, answers.size(), "established answer keeps its physical connection")
	offer_mesh.free()
	answer_mesh.free()
	offerer.free()
	answerer.free()
	_done()


func _test_recovery_budget_and_retirement() -> void:
	for retirement: String in ["exhausted", "left", "detach", "reused generation", "role change"]:
		var clock: Array[int] = [0]
		var fixture := _make_recovery_mesh(ClientFixtures.PLAYER_A, clock)
		var client: ClientScript = fixture[0]
		var mesh: MeshScript = fixture[1]
		var roster: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, true)]
		_owner.call("_inject_plan", client, roster)
		var created: Array = _owner.call("_mesh_peers", mesh)
		var old: Object = created[0]
		old.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		mesh.poll()
		_close_unreliable(old)
		mesh.poll()
		mesh.poll()
		if retirement == "left":
			var transport: TransportScript = client.transport
			transport.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_B}})
			_owner.call("_inject_plan", client, roster, GENERATION)
		elif retirement == "detach":
			mesh.detach()
		elif retirement == "role change":
			var changed_role: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, false)]
			_owner.call("_inject_plan", client, changed_role, GENERATION)
		elif retirement == "reused generation":
			_owner.call("_inject_plan", client, roster, NEXT_GENERATION)
			_owner.call("_inject_plan", client, roster, GENERATION)
		for next_time: int in [5, 10, 15, 100]:
			clock[0] = next_time
			mesh.poll()
		var expected: int = {"exhausted": 4, "reused generation": 3}.get(retirement, 2)
		_assert_equal(expected, created.size(), retirement + " bounds replacement allocations")
		for connection: Object in created:
			_assert_equal(
				true, connection.get("closed"), retirement + " closes the retired connection"
			)
		_assert_equal(0, mesh.get_peer_count(), retirement + " leaves no active connection")
		mesh.free()
		client.free()
	_done()


func _recovery_offer(attempt: int, sdp: String) -> Dictionary:
	return {
		"generation": GENERATION,
		"signal":
		{
			"MeshRecovery":
			{
				"v": 1,
				"room": ClientFixtures.ROOM_ID,
				"from_epoch": 1,
				"to_epoch": 1,
				"attempt": attempt,
				"kind": "Offer",
				"body": sdp,
			},
		},
	}


func _test_answerer_requests_after_restored_attempt() -> void:
	var clock: Array[int] = [0]
	var fixture := _make_recovery_mesh(PLAYER_B, clock)
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	original.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()
	_close_unreliable(original)
	mesh.poll()
	for time: int in [0, 1, 2, 3, 4]:
		clock[0] = time
		mesh.poll()
	_assert_equal(3, _get_signals(client).size(), "one failed physical attempt caps requests")
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	if created.size() == 2:
		var replacement: Object = created[1]
		replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		mesh.poll()
		_close_unreliable(replacement)
		mesh.poll()
		mesh.poll()
		_assert_equal(
			4, _get_signals(client).size(), "restored and reclosed pair gets a new request budget"
		)
	else:
		_assert_equal(2, created.size(), "one valid offer creates replacement")
	mesh.free()
	client.free()
	_done()


func _test_malformed_offer_preserves_active_link() -> void:
	var fixture := _make_recovery_mesh(PLAYER_B, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	original.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()
	_deliver(client, offerer, _recovery_offer(1, "not-an-sdp"))
	_assert_equal(1, created.size(), "malformed higher offer cannot allocate a replacement")
	_assert_equal(false, original.get("closed"), "malformed higher offer preserves the active link")
	mesh.free()
	client.free()
	_done()
