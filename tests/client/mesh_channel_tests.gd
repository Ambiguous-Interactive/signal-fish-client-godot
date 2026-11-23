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
		_test_recovery_offer_requires_local_ready_link,
		_test_recovery_buffers_ice_before_remote_description,
		_test_answerer_recovers_after_dropped_offer,
		_test_recovery_budget_and_retirement,
		_test_answerer_requests_after_restored_attempt,
		_test_reentrant_clock_claims_sdp_once,
		_test_reentrant_clock_does_not_strand_ice,
		_test_malformed_offer_preserves_active_link,
		_test_replacement_waits_for_engine_offer_validation,
		_test_staged_offer_retires_with_pair,
		_test_superseding_offer_owns_reentrant_ice,
		_test_promoting_offer_keeps_ice_when_new_offer_arrives,
		_test_promotion_cannot_revive_retired_pair,
		_test_staged_offer_expires_during_engine_callbacks,
		_test_committed_offer_expires_during_installation,
		_test_probe_retirement_preserves_reentrant_plan,
		_test_probe_poll_resists_reentry,
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


func _ready_recovery_connection(mesh: MeshScript, connection: Object) -> void:
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()


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
	for observe_open: bool in [true, false]:
		_check_answerer_requests_after_restored_attempt(observe_open)
	_done()


func _check_answerer_requests_after_restored_attempt(observe_open: bool) -> void:
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
		if observe_open:
			mesh.poll()
		_close_unreliable(replacement)
		mesh.poll()
		mesh.poll()
		_assert_equal(
			4,
			_get_signals(client).size(),
			"reclosed pair renews requests (observed open: %s)" % observe_open
		)
	else:
		_assert_equal(2, created.size(), "one valid offer creates replacement")
	mesh.free()
	client.free()


func _test_reentrant_clock_claims_sdp_once() -> void:
	_check_reentrant_recovery_clock("session_description_created")
	_done()


func _test_reentrant_clock_does_not_strand_ice() -> void:
	_check_reentrant_recovery_clock("ice_candidate_created")
	_done()


func _check_reentrant_recovery_clock(signal_name: String) -> void:
	var fixture := _make_recovery_mesh(ClientFixtures.PLAYER_A, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var roster: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, true)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	original.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.poll()
	_close_unreliable(original)
	mesh.poll()
	mesh.poll()
	_assert_equal(2, created.size(), "clock test starts a recovery attempt")
	if created.size() == 2:
		var replacement: Object = created[1]
		var entered: Array[bool] = [false]
		mesh.pair_recovery_clock = func() -> int:
			if not entered[0]:
				entered[0] = true
				replacement.call("emit_session_description_created", "offer", "from-clock")
			return 0
		if signal_name == "session_description_created":
			replacement.call("emit_session_description_created", "offer", OFFER_SDP)
		else:
			replacement.call("emit_ice_candidate_created", "", 0, "clock-candidate")
		_assert_equal(true, entered[0], "clock reentered the local description callback")
		_assert_equal(
			1, replacement.get("local_description_calls"), "clock reentry reaches engine once"
		)
		var actual: Array[String] = []
		for outbound: Dictionary in _get_signals(client):
			actual.append(outbound["signal"]["MeshRecovery"]["kind"])
		var expected := (
			["Offer"] if signal_name == "session_description_created" else ["Offer", "IceCandidate"]
		)
		_assert_equal(expected, actual, "clock reentry preserves SDP and candidate ordering")
	mesh.free()
	client.free()


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


func _test_replacement_waits_for_engine_offer_validation() -> void:
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
	var multiplayer := mesh.get_multiplayer_peer()
	var peer_id := MeshScript.uuid_to_peer_id(offerer)
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP + "a=fingerprint:sha-256 invalid"))
	_assert_equal(2, created.size(), "one standalone offer verification begins")
	if created.size() == 2:
		var rejected: Object = created[1]
		_assert_equal(false, original.get("closed"), "pending validation preserves old link")
		var disabled_answer := OFFER_SDP.replace("m=application 9", "m=application 0")
		rejected.call("emit_session_description_created", "answer", disabled_answer)
		mesh.poll()
		_assert_equal(false, original.get("closed"), "rejected data section preserves old link")
		clock[0] = 5
		mesh.poll()
		_assert_equal(
			true, rejected.get("closed"), "no engine answer retires standalone verification"
		)
		var old_peer: Dictionary = {}
		if multiplayer.call("has_peer", peer_id):
			old_peer = multiplayer.call("get_peer", peer_id)
		_assert_equal(
			true,
			old_peer.get("connection") == original,
			"semantically rejected offer preserves the registered link"
		)
		rejected.call("emit_session_description_created", "answer", OFFER_SDP)
		_assert_equal(0, _get_signals(client).size(), "expired verification cannot send SDP")
		_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
		_assert_equal(2, created.size(), "expired offer cannot restart standalone verification")
		_deliver(client, offerer, _recovery_offer(2, OFFER_SDP))
		_assert_equal(3, created.size(), "higher offer starts one verification")
		if created.size() == 3:
			var accepted: Object = created[2]
			_deliver(client, offerer, _recovery_offer(2, OFFER_SDP))
			_deliver_ice(client, offerer, 2, "while-validating")
			_assert_equal(3, created.size(), "duplicate offer cannot restart verification")
			accepted.set(
				"close_hook", func() -> void: _deliver_ice(client, offerer, 2, "during-probe-close")
			)
			original.set(
				"close_hook", func() -> void: _deliver_ice(client, offerer, 2, "during-old-close")
			)
			accepted.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
			_assert_equal(true, accepted.get("closed"), "validated standalone connection retires")
			_assert_equal(
				true, original.get("closed"), "only validated offer retires old connection"
			)
			_assert_equal(4, created.size(), "validation promotes a distinct registered connection")
			if created.size() == 4:
				var replacement: Object = created[3]
				var new_peer: Dictionary = multiplayer.call("get_peer", peer_id)
				_assert_equal(
					replacement,
					new_peer.get("connection"),
					"validated replacement keeps the peer ID"
				)
				_assert_equal(
					["offer", OFFER_SDP],
					replacement.get("remote_description"),
					"replacement applies exactly the verified offer"
				)
				_assert_equal(
					[
						["", 0, "while-validating"],
						["", 0, "during-probe-close"],
						["", 0, "during-old-close"],
					],
					replacement.get("added_candidates"),
					"matching ICE through the handoff reaches replacement"
				)
	mesh.free()
	client.free()
	_done()


func _test_staged_offer_retires_with_pair() -> void:
	for retire_by_plan: bool in [true, false]:
		_check_staged_offer_retires_with_pair(retire_by_plan)
	_done()


func _check_staged_offer_retires_with_pair(retire_by_plan: bool) -> void:
	var fixture := _make_recovery_mesh(PLAYER_B, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	_ready_recovery_connection(mesh, original)
	for attempt: int in [1, 2]:
		_deliver(client, offerer, _recovery_offer(attempt, OFFER_SDP))
	_assert_equal(3, created.size(), "newer offer allocates one replacement verification")
	if created.size() == 3:
		var superseded: Object = created[1]
		var pending: Object = created[2]
		_assert_equal(true, superseded.get("closed"), "newer offer closes superseded verification")
		_assert_equal(false, pending.get("closed"), "newest offer waits for engine")
		var session_created: Signal = pending.get("session_description_created")
		var first_callback: Dictionary = session_created.get_connections()[0]
		var stale_callback: Callable = first_callback["callable"]
		var retained_probe := stale_callback.get_object()
		if retire_by_plan:
			_owner.call("_inject_plan", client, roster, NEXT_GENERATION)
		else:
			mesh.detach()
		_assert_equal(true, pending.get("closed"), "pair retirement closes pending verification")
		_assert_equal(
			true,
			session_created.get_connections().is_empty(),
			"retirement disconnects probe callback"
		)
		_assert_equal(true, is_instance_valid(retained_probe), "test retains retired probe")
		stale_callback.call("answer", OFFER_SDP)
		mesh.poll()
		_assert_equal(
			4 if retire_by_plan else 3, created.size(), "retired validation cannot replace peer"
		)
		_assert_equal(0, _get_signals(client).size(), "retired validation cannot send SDP")
	mesh.free()
	client.free()


func _deliver_ice(client: ClientScript, offerer: String, attempt: int, name: String) -> void:
	var candidate := _recovery_offer(attempt, name)
	candidate["signal"]["MeshRecovery"]["kind"] = "IceCandidate"
	_deliver(client, offerer, candidate)


func _test_staged_offer_expires_during_engine_callbacks() -> void:
	for boundary: String in ["poll_hook", "close_hook"]:
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
		_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
		_assert_equal(2, created.size(), "deadline test allocates validator")
		if created.size() == 2:
			var probe: Object = created[1]
			probe.set(
				boundary,
				func() -> void:
					clock[0] = 5
					if boundary == "poll_hook":
						probe.call("emit_session_description_created", "answer", OFFER_SDP)
			)
			if boundary == "close_hook":
				probe.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
			_assert_equal(5, clock[0], "%s reaches deadline" % boundary)
			_assert_equal(false, original.get("closed"), "%s expiry preserves old link" % boundary)
			_assert_equal(true, probe.get("closed"), "%s expiry closes validator" % boundary)
			_assert_equal(2, created.size(), "%s expiry cannot install replacement" % boundary)
		mesh.free()
		client.free()
	_done()


func _test_committed_offer_expires_during_installation() -> void:
	for boundary: String in ["close_hook", "initialize_hook", "remote_description_hook"]:
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
		_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
		_assert_equal(2, created.size(), "%s allocates a validator" % boundary)
		if created.size() == 2:
			var reach_deadline := func() -> void: clock[0] = 5
			if boundary == "close_hook":
				original.set(boundary, reach_deadline)
			else:
				var factory := mesh.peer_connection_factory
				mesh.peer_connection_factory = func() -> Object:
					var connection: Object = factory.call()
					connection.set(boundary, reach_deadline)
					return connection
			_deliver_ice(client, offerer, 1, "queued-before-deadline")
			var validator: Object = created[1]
			validator.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
			_assert_equal(5, clock[0], "%s reaches the committed deadline" % boundary)
			var peer_id := MeshScript.uuid_to_peer_id(offerer)
			var multiplayer: Object = _owner.call("_mesh_multiplayer", mesh)
			_assert_equal(
				false, multiplayer.call("has_peer", peer_id), "%s leaves no expired peer" % boundary
			)
			if boundary == "close_hook":
				_assert_equal(2, created.size(), "old close crossing deadline skips opening")
			elif created.size() == 3:
				var expired: Object = created[2]
				_assert_equal(
					true, expired.get("closed"), "%s closes the expired replacement" % boundary
				)
				_assert_equal(
					[], expired.get("added_candidates"), "%s drops expired ICE" % boundary
				)
		mesh.free()
		client.free()
	_done()


func _test_probe_retirement_preserves_reentrant_plan() -> void:
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
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	_assert_equal(2, created.size(), "plan retirement test allocates a validator")
	if created.size() == 2:
		var probe: Object = created[1]
		var third_generation := "40000000-0000-0000-0000-000000000003"
		probe.set(
			"close_hook",
			func() -> void:
				var empty_roster: Array[Dictionary] = []
				_owner.call("_inject_plan", client, empty_roster, third_generation, "relay")
		)
		_owner.call("_inject_plan", client, roster, NEXT_GENERATION)
		_assert_equal(true, probe.get("closed"), "new generation closes the validator")
		_assert_equal(2, created.size(), "older plan cannot reopen a peer after nested relay plan")
		var multiplayer: Object = _owner.call("_mesh_multiplayer", mesh)
		var peer_id := MeshScript.uuid_to_peer_id(offerer)
		_assert_equal(false, multiplayer.call("has_peer", peer_id), "nested relay plan has no peer")
	mesh.free()
	client.free()
	_done()


func _test_probe_poll_resists_reentry() -> void:
	var fixture := _make_recovery_mesh(PLAYER_B, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var initial_connections: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = initial_connections[0]
	_ready_recovery_connection(mesh, original)
	var factory := mesh.peer_connection_factory
	mesh.peer_connection_factory = func() -> Object:
		var connection: Object = factory.call()
		connection.set("initialize_hook", mesh.poll)
		connection.set("remote_description_hook", mesh.poll)
		connection.set("poll_hook", mesh.poll)
		return connection
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	var created: Array = _owner.call("_mesh_peers", mesh)
	_assert_equal(2, created.size(), "reentry test allocates validator")
	if created.size() == 2:
		var probe: Object = created[1]
		_assert_equal(0, probe.get("poll_calls"), "setup reentry cannot poll validator")
		mesh.poll()
		_assert_equal(1, probe.get("poll_calls"), "nested poll calls engine once")
	mesh.free()
	client.free()
	_done()


func _test_superseding_offer_owns_reentrant_ice() -> void:
	var fixture := _make_recovery_mesh(PLAYER_B, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	_ready_recovery_connection(mesh, original)
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	_assert_equal(2, created.size(), "first offer allocates validator")
	if created.size() == 2:
		var superseded: Object = created[1]
		superseded.set(
			"close_hook", func() -> void: _deliver_ice(client, offerer, 2, "during-supersession")
		)
		_deliver(client, offerer, _recovery_offer(2, OFFER_SDP))
		_assert_equal(3, created.size(), "second offer allocates validator")
		if created.size() == 3:
			_deliver_ice(client, offerer, 2, "after-supersession")
			var pending: Object = created[2]
			pending.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
			_assert_equal(4, created.size(), "validated superseding offer installs peer")
			if created.size() == 4:
				var new_peer: Object = created[3]
				_assert_equal(
					[["", 0, "during-supersession"], ["", 0, "after-supersession"]],
					new_peer.get("added_candidates"),
					"superseding probe owns matching ICE throughout old probe close"
				)
	mesh.free()
	client.free()
	_done()


func _test_promoting_offer_keeps_ice_when_new_offer_arrives() -> void:
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
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	_assert_equal(2, created.size(), "first offer allocates validator")
	if created.size() == 2:
		var first_probe: Object = created[1]
		original.set(
			"close_hook",
			func() -> void:
				_deliver(client, offerer, _recovery_offer(2, OFFER_SDP))
				_deliver_ice(client, offerer, 1, "committed-after-new-offer")
				_deliver_ice(client, offerer, 2, "new-validator")
				mesh.poll()
				var second_probe: Object = created[2]
				_assert_equal(
					0, second_probe.get("poll_calls"), "nested poll waits for committed install"
				)
		)
		_deliver_ice(client, offerer, 1, "committed-before-new-offer")
		first_probe.call("emit_session_description_created", "answer", OFFER_SDP)
		mesh.poll()
		_assert_equal(4, created.size(), "new offer and committed install allocate once")
		if created.size() == 4:
			var first_replacement: Object = created[3]
			_assert_equal(
				[
					["", 0, "committed-before-new-offer"],
					["", 0, "committed-after-new-offer"],
				],
				first_replacement.get("added_candidates"),
				"committed offer owns matching ICE even after newer offer starts validating"
			)
			var second_probe: Object = created[2]
			second_probe.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
			_assert_equal(5, created.size(), "second validation installs once")
			if created.size() == 5:
				var second_replacement: Object = created[4]
				_assert_equal(
					[["", 0, "new-validator"]],
					second_replacement.get("added_candidates"),
					"newer offer owns only its matching ICE"
				)
	mesh.free()
	client.free()
	_done()


func _test_promotion_cannot_revive_retired_pair() -> void:
	var fixture := _make_recovery_mesh(PLAYER_B, [0])
	var client: ClientScript = fixture[0]
	var mesh: MeshScript = fixture[1]
	var offerer := ClientFixtures.PLAYER_A
	var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
	_owner.call("_inject_plan", client, roster)
	var created: Array = _owner.call("_mesh_peers", mesh)
	var original: Object = created[0]
	_ready_recovery_connection(mesh, original)
	_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
	_assert_equal(2, created.size(), "first offer allocates validator")
	if created.size() == 2:
		var first_probe: Object = created[1]
		original.set(
			"close_hook",
			func() -> void:
				_deliver(client, offerer, _recovery_offer(2, OFFER_SDP))
				mesh.detach()
		)
		first_probe.call("emit_session_description_created", "answer", OFFER_SDP)
		mesh.poll()
		_assert_equal(
			3, created.size(), "detach closes new validator without installing either offer"
		)
		if created.size() == 3:
			var second_probe: Object = created[2]
			_assert_equal(true, second_probe.get("closed"), "detach closes new validator")
		_assert_equal(null, mesh.get_multiplayer_peer(), "detach leaves no registered connection")
	mesh.free()
	client.free()
	_done()


func _test_recovery_offer_requires_local_ready_link() -> void:
	for initial_state: int in [
		WebRTCPeerConnection.STATE_NEW,
		WebRTCPeerConnection.STATE_FAILED,
		WebRTCPeerConnection.STATE_CONNECTED,
	]:
		var fixture := _make_recovery_mesh(PLAYER_B, [0])
		var client: ClientScript = fixture[0]
		var mesh: MeshScript = fixture[1]
		var offerer := ClientFixtures.PLAYER_A
		var roster: Array[Dictionary] = [_owner.call("_peer", offerer, false)]
		_owner.call("_inject_plan", client, roster)
		var created: Array = _owner.call("_mesh_peers", mesh)
		var original: Object = created[0]
		original.set("state", initial_state)
		if initial_state == WebRTCPeerConnection.STATE_CONNECTED:
			# A signaling callback may run before mesh.poll records readiness.
			original.set(
				"poll_hook",
				func() -> void: _deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
			)
			mesh.poll()
			_assert_equal(2, created.size(), "reentrant offer sees an already connected link")
		else:
			mesh.poll()
			_deliver(client, offerer, _recovery_offer(1, OFFER_SDP))
			_assert_equal(
				1, created.size(), "unready initial state %d cannot recover" % initial_state
			)
			if initial_state == WebRTCPeerConnection.STATE_NEW:
				if created.size() == 2:
					var probe: Object = created[1]
					probe.call("emit_session_description_created", "answer", OFFER_SDP)
					mesh.poll()
				_deliver(
					client, offerer, {"generation": GENERATION, "signal": {"Offer": OFFER_SDP}}
				)
				_assert_equal(
					["offer", OFFER_SDP],
					original.get("remote_description"),
					"original negotiation is still available"
				)
		mesh.free()
		client.free()
	_done()


func _test_recovery_buffers_ice_before_remote_description() -> void:
	for initiate: bool in [false, true]:
		var local_player := ClientFixtures.PLAYER_A if initiate else PLAYER_B
		var sender := PLAYER_B if initiate else ClientFixtures.PLAYER_A
		var fixture := _make_recovery_mesh(local_player, [0])
		var client: ClientScript = fixture[0]
		var mesh: MeshScript = fixture[1]
		var roster: Array[Dictionary] = [_owner.call("_peer", sender, initiate)]
		_owner.call("_inject_plan", client, roster)
		var created: Array = _owner.call("_mesh_peers", mesh)
		var original: Object = created[0]
		original.set("state", WebRTCPeerConnection.STATE_CONNECTED)
		mesh.poll()
		if initiate:
			_close_unreliable(original)
			mesh.poll()
			mesh.poll()
		var expected_candidates: Array[Array] = []
		for index: int in 17:
			var candidate := "before-description-%d" % index
			_deliver_ice(client, sender, 1, candidate)
			if index < 16:
				expected_candidates.append(["", 0, candidate])
		_deliver_ice(client, sender, 2, "different-attempt")
		var description := _recovery_offer(1, OFFER_SDP)
		if initiate:
			description["signal"]["MeshRecovery"]["kind"] = "Answer"
		_deliver(client, sender, description)
		if not initiate and created.size() == 2:
			var probe: Object = created[1]
			probe.call("emit_session_description_created", "answer", OFFER_SDP)
			mesh.poll()
		_deliver_ice(client, sender, 1, "after-description")
		expected_candidates.append(["", 0, "after-description"])
		var expected_count := 2 if initiate else 3
		var kind := "answer" if initiate else "offer"
		_assert_equal(expected_count, created.size(), "one physical recovery after %s" % kind)
		if created.size() == expected_count:
			var replacement: Object = created[-1]
			_assert_equal([kind, OFFER_SDP], replacement.get("remote_description"), "remote SDP")
			_assert_equal(
				expected_candidates,
				replacement.get("added_candidates"),
				"ICE before and after %s stays bounded and in order" % kind
			)
		mesh.free()
		client.free()
	_done()
