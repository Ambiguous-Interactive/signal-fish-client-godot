extends RefCounted

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFWebRTCMeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const PLAYER_D := "10000000-0000-0000-0000-000000000004"
const PLAYER_C := "10000000-0000-0000-0000-000000000003"
const GENERATION := "40000000-0000-0000-0000-000000000001"
const NEXT_GENERATION := "40000000-0000-0000-0000-000000000002"

var _suite: Object
var _failures: Array[String] = []
var _test_done := false


static func run(suite: Object) -> Array[String]:
	var tests := new()
	tests._suite = suite
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_fresh_membership_retires_only_the_prior_link,
		_test_unknown_epoch_and_baseline_cleanup,
		_test_membership_fences_a_previously_removed_link,
		_test_zero_epoch_is_known,
		_test_new_additive_peer_and_departed_incarnation,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _closed(connection: Object) -> bool:
	var closed: bool = connection.get("closed")
	return closed


func _announce(fake: SFFakeTransportScript, kind: String, epoch: Variant) -> void:
	var data := {"player_id": PLAYER_B}
	if kind == "PlayerJoined":
		data = {"player": ClientFixtures.player(PLAYER_B, "B")}
		if epoch != null:
			data["player"]["epoch"] = epoch
	elif epoch != null:
		data["epoch"] = epoch
	fake.inject_server_message({"type": kind, "data": data})


func _inject_plan(
	client: SignalFishClientScript, peers: Array[Dictionary], generation: String
) -> void:
	_suite.call("_inject_plan", client, peers, generation)


func _make_history(initial_epoch := 1) -> Array:
	var client: SignalFishClientScript = _suite.call("_make_in_room_client")
	var fake: SFFakeTransportScript = client.transport
	var b := ClientFixtures.player(PLAYER_B, "B")
	b["epoch"] = initial_epoch
	var c := ClientFixtures.player(PLAYER_C, "C")
	c["epoch"] = 1
	(
		fake
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data": ClientFixtures.room_joined_data({"current_players": [b, c]}),
			}
		)
	)
	var mesh: SFWebRTCMeshScript = _suite.call("_make_mesh")
	mesh.attach(client)
	_inject_plan(
		client,
		[_suite.call("_peer", PLAYER_B, true), _suite.call("_peer", PLAYER_C, false)],
		GENERATION
	)
	return [client, fake, mesh]


func _test_fresh_membership_retires_only_the_prior_link() -> void:
	for kind: String in ["PlayerJoined", "PlayerReconnected"]:
		var history := _make_history()
		var client: SignalFishClientScript = history[0]
		var fake: SFFakeTransportScript = history[1]
		var mesh: SFWebRTCMeshScript = history[2]
		var created: Array = mesh.get_meta("created")
		var old: Object = created[0]
		var unrelated: Object = created[1]
		var entries: Dictionary = mesh.get("_peers")
		var entry: Object = entries[PLAYER_B]
		var queued_session: Callable = entry.get("session_cb")
		var queued_candidate: Callable = entry.get("ice_cb")
		_announce(fake, kind, 1)
		_assert(not _closed(old), kind + ": duplicate epoch keeps the link")
		_announce(fake, kind, 2)
		_assert(_closed(old), kind + ": fresh epoch closes prior connection")
		_assert(not _closed(unrelated), kind + ": unrelated connection survives")
		_assert(mesh.get_peer_count() == 1, kind + ": old peer removed before plan")
		var before := fake.sent_text.size()
		queued_session.call("offer", "old-offer")
		queued_candidate.call("", 0, "old-candidate")
		_assert(fake.sent_text.size() == before, kind + ": retained callbacks stay silent")
		(
			fake
			. inject_server_message(
				{
					"type": "Signal",
					"data":
					{"from": PLAYER_B, "generation": GENERATION, "signal": {"Offer": "old"}},
				}
			)
		)
		fake.inject_server_message(
			{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": true}}
		)
		_inject_plan(client, [_suite.call("_peer", PLAYER_B, true)], GENERATION)
		_assert(created.size() == 2, kind + ": stale signals and duplicate plan cannot reopen")
		_inject_plan(client, [_suite.call("_peer", PLAYER_B, true)], NEXT_GENERATION)
		_assert(created.size() == 3, kind + ": replacement plan opens a fresh connection")
		var replacement: Object = created[2]
		_announce(fake, kind, 2)
		_announce(fake, kind, 1)
		_assert(not _closed(replacement), kind + ": duplicate and older epochs keep replacement")
		before = fake.sent_text.size()
		replacement.call("emit_session_description_created", "offer", "fresh")
		_assert(fake.sent_text.size() == before + 1, kind + ": fresh link can signal")
		mesh.free()
		client.free()
	_done()


func _test_unknown_epoch_and_baseline_cleanup() -> void:
	for kind: String in ["PlayerJoined", "PlayerReconnected"]:
		var history := _make_history()
		var client: SignalFishClientScript = history[0]
		var fake: SFFakeTransportScript = history[1]
		var mesh: SFWebRTCMeshScript = history[2]
		var created: Array = mesh.get_meta("created")
		var old: Object = created[0]
		_announce(fake, kind, null)
		_assert(_closed(old), kind + ": missing epoch retires conservatively")
		fake.inject_server_message({"type": "RoomLeft"})
		_assert(client._get_player_epoch(PLAYER_B) == -1, "room leave clears retained epoch")
		var b := ClientFixtures.player(PLAYER_B, "B")
		b["epoch"] = 1
		fake.inject_server_message(
			{
				"type": "RoomJoined",
				"data": ClientFixtures.room_joined_data({"current_players": [b]})
			}
		)
		_inject_plan(client, [_suite.call("_peer", PLAYER_B, true)], GENERATION)
		_assert(mesh.get_peer_count() == 1, "fresh baseline clears old generation fence")
		mesh.free()
		client.free()
	_done()


func _test_membership_fences_a_previously_removed_link() -> void:
	for kind: String in ["PlayerJoined", "PlayerReconnected"]:
		var history := _make_history()
		var client: SignalFishClientScript = history[0]
		var fake: SFFakeTransportScript = history[1]
		var mesh: SFWebRTCMeshScript = history[2]
		var created: Array = mesh.get_meta("created")
		mesh.call("_drop_peer", PLAYER_B)
		_announce(fake, kind, 2)
		fake.inject_server_message(
			{"type": "NewPeer", "data": {"peer_id": PLAYER_B, "you_initiate": true}}
		)
		_inject_plan(client, [_suite.call("_peer", PLAYER_B, true)], GENERATION)
		_assert(created.size() == 2, kind + ": missing old link still fences obsolete plans")
		_inject_plan(client, [_suite.call("_peer", PLAYER_B, true)], NEXT_GENERATION)
		_assert(created.size() == 3, kind + ": fresh plan releases missing-link fence")
		mesh.free()
		client.free()
	_done()


func _test_zero_epoch_is_known() -> void:
	var history := _make_history(0)
	var client: SignalFishClientScript = history[0]
	var fake: SFFakeTransportScript = history[1]
	var mesh: SFWebRTCMeshScript = history[2]
	var created: Array = mesh.get_meta("created")
	var old: Object = created[0]
	_announce(fake, "PlayerReconnected", 0)
	_assert(not _closed(old), "zero is a known u32 epoch")
	_announce(fake, "PlayerReconnected", 1)
	_assert(_closed(old), "epoch after zero retires the old link")
	mesh.free()
	client.free()
	_done()


func _test_new_additive_peer_and_departed_incarnation() -> void:
	var history := _make_history()
	var client: SignalFishClientScript = history[0]
	var fake: SFFakeTransportScript = history[1]
	var mesh: SFWebRTCMeshScript = history[2]
	var created: Array = mesh.get_meta("created")
	var newcomer := ClientFixtures.player(PLAYER_D, "D")
	newcomer["epoch"] = 1
	fake.inject_server_message({"type": "PlayerJoined", "data": {"player": newcomer}})
	var new_peer := {"type": "NewPeer", "data": {"peer_id": PLAYER_D, "you_initiate": true}}
	fake.inject_server_message(new_peer)
	_assert(created.size() == 3, "first-ever member keeps additive NewPeer support")
	fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": PLAYER_D}})
	newcomer["epoch"] = 2
	fake.inject_server_message({"type": "PlayerJoined", "data": {"player": newcomer}})
	fake.inject_server_message(new_peer)
	_assert(created.size() == 3, "departed additive peer waits for replacement plan")
	_inject_plan(client, [_suite.call("_peer", PLAYER_D, true)], NEXT_GENERATION)
	_assert(created.size() == 4, "replacement plan releases departed additive peer")
	mesh.free()
	client.free()
	_done()
