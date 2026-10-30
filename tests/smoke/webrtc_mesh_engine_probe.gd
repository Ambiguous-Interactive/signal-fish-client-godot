extends SceneTree

const MODES: Array[int] = [
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
]


class ProbeChannel:
	extends WebRTCDataChannelExtension

	var config: Dictionary = {}
	var channel_label := ""
	var queued := 0
	var reads := 0
	var state := WebRTCDataChannel.STATE_OPEN

	# gdscript-private-helper: allow _get_ready_state
	func _get_ready_state() -> WebRTCDataChannel.ChannelState:
		return state

	func _get_available_packet_count() -> int:
		return queued

	# gdscript-private-helper: allow _get_packet
	func _get_packet(_buffer: int, _size: int) -> int:
		reads += 1
		queued -= 1
		# Script callbacks cannot populate the native pointer arguments.
		return ERR_BUSY

	func _close() -> void:
		state = WebRTCDataChannel.STATE_CLOSED


class ProbeConnection:
	extends WebRTCPeerConnectionExtension

	var channels: Array[ProbeChannel] = []
	var state := WebRTCPeerConnection.STATE_NEW

	# gdscript-private-helper: allow _get_connection_state
	func _get_connection_state() -> WebRTCPeerConnection.ConnectionState:
		return state

	# gdscript-private-helper: allow _create_data_channel
	func _create_data_channel(label: String, config: Dictionary) -> WebRTCDataChannel:
		var channel := ProbeChannel.new()
		channel.channel_label = label
		channel.config = config.duplicate(true)
		channels.append(channel)
		return channel

	func _poll() -> int:
		return OK

	func _close() -> void:
		state = WebRTCPeerConnection.STATE_CLOSED
		for channel: ProbeChannel in channels:
			channel.close()


var _results: Array[Dictionary] = []
var _valid := true


func _initialize() -> void:
	for selected: int in range(1, 6):
		_dispatch_probe(selected)
	for kind: String in ["removed", "replaced", "forced", "connection-closed", "channel-closed"]:
		_retirement_probe(kind)
	_drained_probe()
	_lifetime_probe()
	var passed := _valid and _results.size() == 12
	var completed: Dictionary = {}
	for result: Dictionary in _results:
		completed[result["case"]] = true
		passed = passed and (result["passed"] == true)
	passed = passed and completed.size() == 12
	print(
		(
			"WEBRTC_MESH_ENGINE_RESULT "
			+ (
				JSON
				. stringify(
					{
						"engine": Engine.get_version_info(),
						"valid": _valid,
						"passed": passed,
						"scope":
						"engine channel dispatch and configuration; no packet bytes or transport",
						"cases": _results,
					}
				)
			)
		)
	)
	quit(0 if passed else 1)


func _setup(mesh: WebRTCMultiplayerPeer, ids: Array[int]) -> Array[ProbeConnection]:
	var connections: Array[ProbeConnection] = []
	if mesh.create_mesh(1, MODES) != OK:
		_valid = false
		return connections
	for id: int in ids:
		var connection := ProbeConnection.new()
		if mesh.add_peer(connection, id, 123) != OK:
			_valid = false
			return []
		connection.state = WebRTCPeerConnection.STATE_CONNECTED
		connections.append(connection)
	mesh.poll()
	return connections


func _metadata(mesh: WebRTCMultiplayerPeer) -> Dictionary:
	return {
		"peer": mesh.get_packet_peer(),
		"mode": mesh.get_packet_mode(),
		"channel": mesh.get_packet_channel(),
	}


func _dispatch_probe(selected: int) -> void:
	var mesh := WebRTCMultiplayerPeer.new()
	var connections := _setup(mesh, [2, 3])
	if connections.size() != 2:
		return
	var connection := connections[0]
	connection.channels[selected].queued = 1
	mesh.poll()
	var before := _metadata(mesh)
	var expected := {"peer": 2, "mode": MODES[selected % 3], "channel": maxi(0, selected - 2)}
	connection.channels[0].queued = 1
	connections[1].channels[0].queued = 1
	mesh.poll()
	var retained := _metadata(mesh)
	var packet := mesh.get_packet()
	var error := mesh.get_packet_error()
	var passed := (
		before == expected
		and retained == expected
		and error == ERR_BUSY
		and packet.is_empty()
		and connection.channels[selected].reads == 1
		and connection.channels[0].reads == 0
		and connections[1].channels[0].reads == 0
	)
	(
		_results
		. append(
			{
				"case": "late-arrival-%d" % selected,
				"passed": passed,
				"selected": before,
				"after_poll": retained,
				"read_error": error,
				"selected_reads": connection.channels[selected].reads,
				"late_reads": connection.channels[0].reads,
			}
		)
	)
	mesh.close()


func _retirement_probe(kind: String) -> void:
	var mesh := WebRTCMultiplayerPeer.new()
	var connections := _setup(mesh, [2, 3])
	if connections.size() != 2:
		return
	connections[0].channels[5].queued = 1
	mesh.poll()
	var before := _metadata(mesh)
	connections[1].channels[4].queued = 1
	var replacement := ProbeConnection.new()
	match kind:
		"removed":
			mesh.remove_peer(2)
		"replaced":
			if mesh.add_peer(replacement, 2, 123) != OK:
				_valid = false
		"forced":
			mesh.disconnect_peer(2, true)
		"connection-closed":
			mesh.disconnect_peer(2)
		"channel-closed":
			connections[0].channels[1].state = WebRTCDataChannel.STATE_CLOSED
	mesh.poll()
	var after := _metadata(mesh)
	var error := ERR_UNAVAILABLE
	if after == {"peer": 3, "mode": MODES[1], "channel": 2}:
		mesh.get_packet()
		error = mesh.get_packet_error()
	(
		_results
		. append(
			{
				"case": "selected-peer-%s" % kind,
				"passed":
				(
					before == {"peer": 2, "mode": MODES[2], "channel": 3}
					and after == {"peer": 3, "mode": MODES[1], "channel": 2}
					and error == ERR_BUSY
					and connections[0].channels[5].reads == 0
					and connections[1].channels[4].reads == 1
				),
				"before": before,
				"after": after,
			}
		)
	)
	mesh.close()


func _drained_probe() -> void:
	var mesh := WebRTCMultiplayerPeer.new()
	var connections := _setup(mesh, [2, 3])
	if connections.size() != 2:
		return
	connections[0].channels[5].queued = 1
	mesh.poll()
	var before := _metadata(mesh)
	connections[0].channels[5].queued = 0
	connections[0].channels[0].queued = 1
	connections[1].channels[4].queued = 1
	mesh.get_packet()
	var error := mesh.get_packet_error()
	var after := _metadata(mesh)
	(
		_results
		. append(
			{
				"case": "selected-channel-drained",
				"passed":
				(
					before == {"peer": 2, "mode": MODES[2], "channel": 3}
					and error == ERR_UNAVAILABLE
					and connections[0].channels[5].reads == 0
					and connections[0].channels[0].reads == 0
					and connections[1].channels[4].reads == 0
					and connections[0].channels[0].queued == 1
					and connections[1].channels[4].queued == 1
					and after == {"peer": 3, "mode": MODES[1], "channel": 2}
				),
				"before": before,
				"after": after,
				"read_error": error,
			}
		)
	)
	mesh.close()


func _lifetime_probe() -> void:
	var mesh := WebRTCMultiplayerPeer.new()
	var connections := _setup(mesh, [2])
	if connections.size() != 1:
		return
	var passed := true
	var configs: Array[Dictionary] = []
	for index: int in range(6):
		var config := connections[0].channels[index].config
		var mode := MODES[index % 3]
		var expected_lifetime := 123 if index < 3 else 1
		passed = passed and not config.has("maxPacketLifetime")
		if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			passed = passed and not config.has("maxPacketLifeTime")
		else:
			passed = passed and config.get("maxPacketLifeTime", -1) == expected_lifetime
		passed = (
			passed
			and config.get("id", -1) == index + 1
			and (config.get("negotiated", false) == true)
			and (config.get("ordered", false) == true) == (mode != MODES[2])
		)
		configs.append(config)
	_results.append({"case": "channel-configuration", "passed": passed, "configs": configs})
	mesh.close()
