extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")
const PLAYER := "10000000-0000-0000-0000-000000000002"

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
		_test_cached_channel_selection,
		_test_multi_peer_selection,
		_test_packet_count,
		_test_peer_lifecycle_and_settings,
		_test_failed_and_empty_reads,
		_test_cached_packet_lifecycle
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])


func _done() -> void:
	_test_done = true


func _setup(count: int = 1) -> Array:
	var client: Object = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	var peers: Array[Dictionary] = []
	for index: int in count:
		peers.append(
			_owner.call("_peer", "10000000-0000-0000-0000-00000000000%d" % [index + 2], false)
		)
	_owner.call("_inject_plan", client, peers)
	var connections: Array = _owner.call("_mesh_peers", mesh)
	var connection: Object = connections[0]
	for item: Object in connections:
		item.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	return [mesh, client, connection, mesh.get_safe_multiplayer_peer(), connections]


func _queue(connection: Object, channel: int, data: PackedByteArray) -> void:
	var channels: Array = connection.get("channels")
	var data_channel: Object = channels[channel]
	var packets: Array = data_channel.get("packets")
	packets.append(data)


func _test_cached_channel_selection() -> void:
	var setup := _setup()
	var connection: Object = setup[2]
	var peer: MultiplayerPeer = setup[3]
	_assert_equal(0, peer.get_available_packet_count(), "initial queue empty")
	_queue(connection, 2, PackedByteArray([2]))
	_assert_equal(1, peer.get_available_packet_count(), "queued packet ready")
	_assert_equal(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, peer.get_packet_mode(), "cached mode")
	_queue(connection, 0, PackedByteArray([0]))
	peer.poll()
	_assert_equal(
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, peer.get_packet_mode(), "arrival keeps mode"
	)
	_assert_equal(MeshScript.uuid_to_peer_id(PLAYER), peer.get_packet_peer(), "physical sender")
	_assert_equal(0, peer.get_packet_channel(), "default channel")
	_assert_equal(PackedByteArray([2]), peer.get_packet(), "arrival keeps selected bytes")
	_assert_equal(OK, peer.get_packet_error(), "script packet hook success")
	_assert_equal(
		MultiplayerPeer.TRANSFER_MODE_RELIABLE, peer.get_packet_mode(), "next selection mode"
	)
	_assert_equal(PackedByteArray([0]), peer.get_packet(), "next selection bytes")
	_assert_equal(0, peer.get_available_packet_count(), "queue drained")
	_dispose(setup)
	_done()


func _test_multi_peer_selection() -> void:
	var setup := _setup(2)
	var connections: Array = setup[4]
	var peer: MultiplayerPeer = setup[3]
	var first_connection: Object = connections[0]
	var second_connection: Object = connections[1]
	_queue(first_connection, 2, PackedByteArray([1]))
	var first := peer.get_packet_peer()
	_queue(second_connection, 0, PackedByteArray([2]))
	peer.poll()
	_assert_equal(first, peer.get_packet_peer(), "new peer arrival keeps cached sender")
	_assert_equal(
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, peer.get_packet_mode(), "cached sender mode"
	)
	_assert_equal(PackedByteArray([1]), peer.get_packet(), "cached sender payload")
	_assert_equal(false, first == peer.get_packet_peer(), "next packet selects second peer")
	_assert_equal(
		MultiplayerPeer.TRANSFER_MODE_RELIABLE, peer.get_packet_mode(), "second peer mode"
	)
	_assert_equal(PackedByteArray([2]), peer.get_packet(), "second peer payload")
	_dispose(setup)
	_done()


func _test_packet_count() -> void:
	var setup := _setup(2)
	var connections: Array = setup[4]
	var peer: MultiplayerPeer = setup[3]
	for connection: Object in connections:
		for channel: int in 3:
			for _packet: int in 4:
				_queue(connection, channel, PackedByteArray([channel + 1]))
	_assert_equal(24, peer.get_available_packet_count(), "all peers and channels counted")
	_assert_equal(24, peer.get_available_packet_count(), "cached packet counted exactly once")
	var second: Object = connections[1]
	var channels: Array = second.get("channels")
	var channel: Object = channels[2]
	channel.set("state", WebRTCDataChannel.STATE_CLOSED)
	_assert_equal(12, peer.get_available_packet_count(), "incomplete peer queues excluded")
	channel.set("state", WebRTCDataChannel.STATE_OPEN)
	_assert_equal(24, peer.get_available_packet_count(), "restored peer queues counted")
	second.set("state", WebRTCPeerConnection.STATE_CONNECTING)
	_assert_equal(12, peer.get_available_packet_count(), "connecting peer queues excluded")
	second.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	for remaining: int in range(24, 0, -1):
		_assert_equal(remaining, peer.get_available_packet_count(), "exact remaining packet count")
		peer.get_packet()
	_assert_equal(0, peer.get_available_packet_count(), "drained packet count")
	_dispose(setup)
	_done()


func _test_peer_lifecycle_and_settings() -> void:
	var setup := _setup()
	var mesh: MeshScript = setup[0]
	var peer: MultiplayerPeer = setup[3]
	var engine: Object = mesh.get_multiplayer_peer()
	var connected: Array[int] = []
	var disconnected: Array[int] = []
	peer.peer_connected.connect(func(event_id: int) -> void: connected.append(event_id))
	peer.peer_disconnected.connect(func(event_id: int) -> void: disconnected.append(event_id))
	peer.poll()
	peer.poll()
	var id := MeshScript.uuid_to_peer_id(PLAYER)
	_assert_equal([id], connected, "already-connected peer announced once")
	_assert_equal(engine.call("get_unique_id"), peer.get_unique_id(), "local peer id preserved")
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	peer.transfer_channel = 0
	peer.refuse_new_connections = true
	peer.set_target_peer(-id)
	_assert_equal(1, engine.get("transfer_mode"), "send mode delegated")
	_assert_equal(1, peer.transfer_mode, "send mode getter delegated")
	_assert_equal(true, peer.refuse_new_connections, "refusal setting delegated")
	_assert_equal(-id, engine.get("target"), "target exclusion preserved")
	_assert_equal(OK, peer.put_packet(PackedByteArray([5])), "send delegated")
	_assert_equal([PackedByteArray([5])], engine.get("sent"), "exact sent bytes")
	peer.disconnect_peer(id)
	peer.poll()
	_assert_equal([id], disconnected, "removed peer announced once")
	_assert_equal(0, mesh.get_peer_count(), "disconnect retires mesh entry")
	peer.close()
	_assert_equal(
		MultiplayerPeer.CONNECTION_DISCONNECTED, peer.get_connection_status(), "close status"
	)
	_assert_equal(null, mesh.get_safe_multiplayer_peer(), "close resets mesh")
	_assert_equal(ERR_UNCONFIGURED, peer.put_packet(PackedByteArray([6])), "closed sends refused")
	_dispose(setup)
	_done()


func _test_failed_and_empty_reads() -> void:
	var setup := _setup()
	var connection: Object = setup[2]
	var peer: MultiplayerPeer = setup[3]
	var channels: Array = connection.get("channels")
	var channel: Object = channels[0]
	for error: Error in [OK, ERR_BUSY]:
		channel.set("packet_error", error)
		_queue(connection, 0, PackedByteArray() if error == OK else PackedByteArray([9]))
		_assert_equal(1, peer.get_available_packet_count(), "failed or empty datagram ready")
		_assert_equal(PackedByteArray(), peer.get_packet(), "failed read does not expose bytes")
		_assert_equal(ERR_UNAVAILABLE, peer.get_packet_error(), "script hook empty read error")
		_assert_equal(0, peer.get_available_packet_count(), "failed read consumed once")
	channel.set("packet_error", OK)
	_queue(connection, 0, PackedByteArray([8]))
	_assert_equal(PackedByteArray([8]), peer.get_packet(), "valid read after failure")
	_assert_equal(OK, peer.get_packet_error(), "valid read clears hook error")
	_dispose(setup)
	_done()


func _test_cached_packet_lifecycle() -> void:
	for operation: String in [
		"remove", "generation", "channel-close", "client-free", "detach", "free"
	]:
		var setup := _setup()
		var mesh: MeshScript = setup[0]
		var client: Object = setup[1]
		var connection: Object = setup[2]
		var peer: MultiplayerPeer = setup[3]
		_queue(connection, 0, PackedByteArray([7]))
		_assert_equal(1, peer.get_available_packet_count(), "lifecycle cached packet")
		match operation:
			"remove":
				mesh.call("_drop_peer", PLAYER)
			"generation":
				var peers: Array[Dictionary] = [_owner.call("_peer", PLAYER, false)]
				_owner.call("_inject_plan", client, peers, "40000000-0000-0000-0000-000000000002")
			"channel-close":
				var channels: Array = connection.get("channels")
				var channel: Object = channels[2]
				channel.set("state", WebRTCDataChannel.STATE_CLOSED)
			"client-free":
				client.free()
			"detach":
				mesh.detach()
			"free":
				mesh.free()
		_assert_equal(
			0, peer.get_available_packet_count(), "lifecycle discards cached packet: " + operation
		)
		_assert_equal(
			PackedByteArray(), peer.get_packet(), "lifecycle discards cached bytes: " + operation
		)
		if is_instance_valid(mesh):
			mesh.free()
		if is_instance_valid(client):
			client.free()
	_done()


func _dispose(setup: Array) -> void:
	var mesh: MeshScript = setup[0]
	var client: Object = setup[1]
	mesh.free()
	client.free()
