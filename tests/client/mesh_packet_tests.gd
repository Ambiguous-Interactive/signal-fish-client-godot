extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")
const PLAYERS: Array[String] = [
	"10000000-0000-0000-0000-000000000002",
	"10000000-0000-0000-0000-000000000003",
	"10000000-0000-0000-0000-000000000004"
]
const MODES: Array[int] = [2, 1, 0]

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
		_test_channel_bytes_and_modes,
		_test_round_robin_peers_and_channels,
		_test_receive_membership_changes,
		_test_engine_peer_replacement,
		_test_read_errors_and_link_lifecycle
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])


func _done() -> void:
	_test_done = true


func _setup(count: int) -> Array:
	var client: Object = _owner.call("_make_in_room_client")
	var mesh: MeshScript = _owner.call("_make_mesh")
	_owner.call("_attach", mesh, client)
	var peers: Array[Dictionary] = []
	for index: int in count:
		peers.append(_owner.call("_peer", PLAYERS[index], false))
	_owner.call("_inject_plan", client, peers)
	var connections: Array = _owner.call("_mesh_peers", mesh)
	for connection: Object in connections:
		connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	return [mesh, client, connections]


func _queue(connection: Object, channel: int, data: PackedByteArray) -> void:
	var channels: Array = connection.get("channels")
	var data_channel: Object = channels[channel]
	var packets: Array = data_channel.get("packets")
	packets.append(data)


func _test_channel_bytes_and_modes() -> void:
	var setup := _setup(1)
	var mesh: MeshScript = setup[0]
	var connection: Object = setup[2][0]
	_assert_equal(null, mesh.receive_packet(), "empty channel returns no packet")
	_queue(connection, 2, PackedByteArray([3]))
	_queue(connection, 0, PackedByteArray([1]))
	_queue(connection, 1, PackedByteArray([2]))
	for index: int in 3:
		var packet := mesh.receive_packet()
		_assert_equal(MeshScript.uuid_to_peer_id(PLAYERS[0]), packet.peer_id, "physical sender")
		_assert_equal(MODES[index], packet.transfer_mode, "physical transfer mode")
		_assert_equal(PackedByteArray([index + 1]), packet.data, "physical packet bytes")
		_assert_equal(OK, packet.error, "successful read")
	_assert_equal(null, mesh.receive_packet(), "all channels drained")
	_dispose(setup)
	_done()


func _test_round_robin_peers_and_channels() -> void:
	var setup := _setup(3)
	var mesh: MeshScript = setup[0]
	for connection: Object in setup[2]:
		for channel: int in 3:
			for _packet: int in 4:
				_queue(connection, channel, PackedByteArray([channel]))
	var counts: Dictionary = {}
	for _read: int in 36:
		var packet := mesh.receive_packet()
		var key := "%d-%d" % [packet.peer_id, packet.transfer_mode]
		counts[key] = counts.get(key, 0) + 1
		_assert_equal(packet.transfer_mode, MODES[packet.data[0]], "fair read metadata")
		var next_channel := MODES.find(packet.transfer_mode)
		var connection: Object = setup[2][0]
		# Keep the first peer busy while other peers and modes drain.
		_queue(connection, next_channel, PackedByteArray([next_channel]))
	for player: String in PLAYERS:
		for mode: int in MODES:
			_assert_equal(
				4,
				counts.get("%d-%d" % [MeshScript.uuid_to_peer_id(player), mode]),
				"fair read count"
			)
	_dispose(setup)
	_done()


func _test_receive_membership_changes() -> void:
	var setup := _setup(3)
	var mesh: MeshScript = setup[0]
	var client: Object = setup[1]
	var connections: Array = setup[2]
	for index: int in 3:
		var connection: Object = connections[index]
		_queue(connection, 0, PackedByteArray([index]))
	_assert_equal(PackedByteArray([0]), mesh.receive_packet().data, "initial receive order")
	mesh.call("_drop_peer", PLAYERS[1])
	var remaining := mesh.receive_packet()
	_assert_equal(PackedByteArray([2]), remaining.data, "removed peer cannot deliver cached id")
	mesh.call("_on_client_new_peer", PLAYERS[1], false)
	var added: Array = _owner.call("_mesh_peers", mesh)
	var added_connection: Object = added.back()
	added_connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	_queue(added_connection, 0, PackedByteArray([88]))
	_assert_equal(
		PackedByteArray([88]), mesh.receive_packet().data, "additive peer joins receive list"
	)
	var peers: Array[Dictionary] = [_owner.call("_peer", PLAYERS[1], false)]
	_owner.call("_inject_plan", client, peers, "40000000-0000-0000-0000-000000000002")
	var fresh: Array = _owner.call("_mesh_peers", mesh)
	var replacement: Object = fresh.back()
	replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	_assert_equal(null, mesh.receive_packet(), "replacement has no retired packets")
	_queue(replacement, 2, PackedByteArray([99]))
	var packet := mesh.receive_packet()
	_assert_equal(MeshScript.uuid_to_peer_id(PLAYERS[1]), packet.peer_id, "replacement sender")
	_assert_equal(PackedByteArray([99]), packet.data, "replacement delivers fresh bytes")
	_assert_equal(
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, packet.transfer_mode, "replacement mode"
	)
	_dispose(setup)
	_done()


func _test_engine_peer_replacement() -> void:
	var setup := _setup(2)
	var mesh: MeshScript = setup[0]
	var connections: Array = setup[2]
	var original: Object = connections[0]
	var replacement: Object = connections[1]
	var engine := mesh.get_multiplayer_peer()
	var sender := MeshScript.uuid_to_peer_id(PLAYERS[0])
	engine.call("remove_peer", MeshScript.uuid_to_peer_id("10000000-0000-0000-0000-000000000003"))
	_queue(original, 2, PackedByteArray([17]))
	engine.call("remove_peer", sender)
	_assert_equal(null, mesh.receive_packet(), "engine removal excludes old queued bytes")
	engine.call("add_peer", replacement, sender)
	_queue(replacement, 0, PackedByteArray([29]))
	var packet := mesh.receive_packet()
	_assert_equal(sender, packet.peer_id, "replacement engine sender")
	_assert_equal(MultiplayerPeer.TRANSFER_MODE_RELIABLE, packet.transfer_mode, "replacement mode")
	_assert_equal(PackedByteArray([29]), packet.data, "replacement channels supply fresh bytes")
	_assert_equal(null, mesh.receive_packet(), "old engine channels stay excluded")
	_dispose(setup)
	_done()


func _test_read_errors_and_link_lifecycle() -> void:
	var setup := _setup(1)
	var mesh: MeshScript = setup[0]
	var connection: Object = setup[2][0]
	var channels: Array = connection.get("channels")
	_queue(connection, 0, PackedByteArray())
	var reliable: Object = channels[0]
	reliable.set("packet_error", ERR_BUSY)
	var packet := mesh.receive_packet()
	_assert_equal(ERR_BUSY, packet.error, "read error surfaced")
	_assert_equal(PackedByteArray(), packet.data, "empty packet retained")
	reliable.set("packet_error", OK)
	_queue(connection, 0, PackedByteArray())
	packet = mesh.receive_packet()
	_assert_equal(OK, packet.error, "empty packet can succeed")
	_assert_equal(PackedByteArray(), packet.data, "successful empty packet retained")
	_queue(connection, 0, PackedByteArray([42]))
	for state: int in [WebRTCDataChannel.STATE_CONNECTING, WebRTCDataChannel.STATE_CLOSED]:
		var channel: Object = channels[2]
		channel.set("state", state)
		_assert_equal(null, mesh.receive_packet(), "incomplete link cannot deliver")
	var unreliable: Object = channels[2]
	unreliable.set("state", WebRTCDataChannel.STATE_OPEN)
	_assert_equal(
		PackedByteArray([42]), mesh.receive_packet().data, "closed channel kept its queue"
	)
	_queue(connection, 0, PackedByteArray([43]))
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTING)
	_assert_equal(null, mesh.receive_packet(), "pending connection cannot deliver")
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	mesh.detach()
	_assert_equal(null, mesh.receive_packet(), "detach discards queued gameplay")
	_owner.call("_attach", mesh, setup[1])
	var peers: Array[Dictionary] = [_owner.call("_peer", PLAYERS[0], false)]
	_owner.call("_inject_plan", setup[1], peers)
	var connections: Array = _owner.call("_mesh_peers", mesh)
	var replacement: Object = connections.back()
	replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	_assert_equal(null, mesh.receive_packet(), "fresh link has no old packets")
	_queue(replacement, 0, PackedByteArray([99]))
	packet = mesh.receive_packet()
	_assert_equal(PackedByteArray([99]), packet.data, "fresh link restores delivery")
	_dispose(setup)
	_done()


func _dispose(setup: Array) -> void:
	var mesh: MeshScript = setup[0]
	var client: Object = setup[1]
	mesh.free()
	client.free()
