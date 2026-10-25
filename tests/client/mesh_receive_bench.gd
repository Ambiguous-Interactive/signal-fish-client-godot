extends SceneTree

const Tests = preload("res://tests/client/webrtc_mesh_tests.gd")
const Client = preload("res://addons/signal_fish/signal_fish_client.gd")
const Session = preload("res://addons/signal_fish/protocol/sf_session_types.gd")


func _initialize() -> void:
	var tests := Tests.new()
	for count: int in [1, 16, 64, 256]:
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
		var pcs := tests._mesh_peers(mesh)
		for pc: Tests.FakePeerConnection in pcs:
			pc.state = WebRTCPeerConnection.STATE_CONNECTED
			for ch: Tests.FakeDataChannel in pc.channels:
				for i: int in 200:
					ch.packets.append(PackedByteArray([i]))
		var start := Time.get_ticks_usec()
		for i: int in count * 600:
			if mesh.receive_packet() == null:
				push_error("missing packet")
				mesh.free()
				client.free()
				quit(1)
				return
		var elapsed := Time.get_ticks_usec() - start
		print(
			(
				"BENCH peers=%d packets=%d us_per_packet=%.3f"
				% [count, count * 600, float(elapsed) / (count * 600)]
			)
		)
		mesh.free()
		client.free()
	quit()
