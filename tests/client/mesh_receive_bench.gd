extends SceneTree

const Tests = preload("res://tests/client/webrtc_mesh_tests.gd")
const Client = preload("res://addons/signal_fish/signal_fish_client.gd")
const Session = preload("res://addons/signal_fish/protocol/sf_session_types.gd")


func _initialize() -> void:
	var tests := Tests.new()
	var safe := OS.get_cmdline_user_args().has("--safe")
	for count: int in [1, 16, 64, 256]:
		for workload: String in ["dense", "sparse", "idle"]:
			if not _measure(tests, count, workload, safe):
				quit(1)
				return
	quit()


func _measure(tests: Tests, count: int, workload: String, safe: bool) -> bool:
	var client := Client.new()
	client._player_id = "10000000-0000-0000-0000-000000000001"
	client._room_id = "20000000-0000-0000-0000-000000000001"
	var mesh := tests._make_mesh()
	mesh.attach(client)
	var plan := Session.SessionPlanInfo.new()
	plan.generation = "bench"
	plan.transport = Session.TransportKind.WEBRTC
	for i: int in count:
		var peer := Session.SessionPeerInfo.new()
		peer.player_id = "10000000-0000-0000-0000-%012d" % (i + 2)
		plan.peers.append(peer)
	mesh._apply_plan(plan)
	var packets_per_channel := 4 if safe and workload == "dense" else 200
	var pcs := tests._mesh_peers(mesh)
	for index: int in pcs.size():
		var pc: Tests.FakePeerConnection = pcs[index]
		pc.state = WebRTCPeerConnection.STATE_CONNECTED
		if workload == "idle" or (workload == "sparse" and index != count - 1):
			continue
		for ch: Tests.FakeDataChannel in pc.channels:
			for i: int in packets_per_channel:
				ch.packets.append(PackedByteArray([i]))
	var reads := packets_per_channel * 3 * (count if workload == "dense" else 1)
	var receiver := mesh.get_safe_multiplayer_peer() if safe else null
	var start := Time.get_ticks_usec()
	for i: int in reads:
		var ready := false
		if safe:
			ready = receiver.get_available_packet_count() > 0
			if ready:
				receiver.get_packet_peer()
				receiver.get_packet_mode()
				receiver.get_packet_channel()
				if receiver.get_packet().is_empty():
					push_error("missing safe packet bytes")
					mesh.free()
					client.free()
					return false
		else:
			ready = mesh.receive_packet() != null
		if ready != (workload != "idle"):
			push_error("unexpected packet availability")
			mesh.free()
			client.free()
			return false
	var elapsed := Time.get_ticks_usec() - start
	print(
		(
			"BENCH path=%s workload=%s peers=%d reads=%d us_per_read=%.3f"
			% ["safe" if safe else "raw", workload, count, reads, float(elapsed) / reads]
		)
	)
	mesh.free()
	client.free()
	return true
