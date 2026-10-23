extends Node

## Opt-in real WebRTC loopback. Run this scene with a native WebRTC extension
## or export it to Web with the smoke files included in the export preset.

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const ROOM := "20000000-0000-0000-0000-000000000001"

var _clients: Array[LoopbackClient] = []
var _meshes: Array[MeshScript] = []
var _drive_multiplayer := true
var _failures: Array[String] = []
var _generation := 0


func _ready() -> void:
	for player: String in [PLAYER_A, PLAYER_B]:
		var client := LoopbackClient.new()
		client._player_id = player
		client._room_id = ROOM
		client._connection_state = ClientScript.ConnectionState.CONNECTED
		client._session_state = ClientScript.SessionState.IN_ROOM_FINALIZED
		_clients.append(client)
		var mesh := MeshScript.new()
		mesh.attach(client)
		_meshes.append(mesh)
	_clients[0].remote = _clients[1]
	_clients[1].remote = _clients[0]
	for channel_index: int in 3:
		if not await _check_channel_closure(channel_index):
			break
	for mesh: MeshScript in _meshes:
		mesh.free()
	for client: LoopbackClient in _clients:
		client.free()
	_meshes.clear()
	_clients.clear()
	for failure: String in _failures:
		push_error(failure)
	print("WEBRTC_CHANNEL_DRILL_PASS" if _failures.is_empty() else "WEBRTC_CHANNEL_DRILL_FAIL")
	get_tree().quit(0 if _failures.is_empty() else 1)


func _process(_delta: float) -> void:
	for mesh: MeshScript in _meshes:
		mesh.poll()
		var multiplayer_peer: WebRTCMultiplayerPeer = mesh.get_multiplayer_peer()
		if _drive_multiplayer and multiplayer_peer != null:
			multiplayer_peer.poll()


func _check_channel_closure(channel_index: int) -> bool:
	if not await _open_gameplay_link(channel_index):
		return false
	var sender: WebRTCMultiplayerPeer = _meshes[0].get_multiplayer_peer()
	var remote_id := MeshScript.uuid_to_peer_id(PLAYER_B)
	var peer := sender.get_peer(remote_id)
	var channels: Array = peer["channels"]
	if channels.size() != 3:
		_failures.append("default Godot mesh required-channel count changed")
		return false
	var channel: WebRTCDataChannel = channels[channel_index]
	print(
		(
			"required channel: %s id=%d negotiated=%s"
			% [channel.get_label(), channel.get_id(), channel.is_negotiated()]
		)
	)
	_drive_multiplayer = false
	channel.close()
	if not await _wait_until(
		func() -> bool: return channel.get_ready_state() == WebRTCDataChannel.STATE_CLOSED
	):
		_failures.append("required channel did not close")
		return false
	var connection: WebRTCPeerConnection = peer["connection"]
	if connection.get_connection_state() != WebRTCPeerConnection.STATE_CONNECTED:
		_failures.append("closed-channel control lost its connected peer connection")
		return false
	_meshes[0].poll()
	if _clients[0].statuses.back() != false:
		_failures.append("closed required channel still reported connected")
		return false
	var reports := _clients[0].statuses.size()
	sender.poll()
	_meshes[0].poll()
	if sender.has_peer(remote_id) or _clients[0].statuses.size() != reports:
		_failures.append("engine removal revived or duplicated a transport report")
		return false
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	for mesh: MeshScript in _meshes:
		mesh._apply_plan(relay)
		if mesh.get_peer_count() != 0:
			_failures.append("relay plan retained an old link")
			return false
	_drive_multiplayer = true
	return true


func _open_gameplay_link(channel_index: int) -> bool:
	_replace_plan()
	if not await _wait_until(_link_ready):
		_failures.append(
			"loopback link did not become ready; native builds need a WebRTC extension"
		)
		return false
	var sender: WebRTCMultiplayerPeer = _meshes[0].get_multiplayer_peer()
	var receiver: WebRTCMultiplayerPeer = _meshes[1].get_multiplayer_peer()
	var packet := "gameplay-%d" % channel_index
	if sender.put_packet(packet.to_utf8_buffer()) != OK:
		_failures.append("connected link refused gameplay packet")
		return false
	if not await _wait_until(func() -> bool: return receiver.get_available_packet_count() > 0):
		_failures.append("connected link did not deliver gameplay packet")
		return false
	if receiver.get_packet().get_string_from_utf8() != packet:
		_failures.append("connected link changed gameplay packet")
		return false
	return true


func _link_ready() -> bool:
	for mesh: MeshScript in _meshes:
		if mesh._count_connected_peers() != 1:
			return false
	for client: LoopbackClient in _clients:
		if client.statuses.is_empty() or client.statuses.back() != true:
			return false
	return true


func _wait_until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return false


func _replace_plan() -> void:
	_generation += 1
	for index: int in [1, 0]:
		var plan := SessionScript.SessionPlanInfo.new()
		plan.generation = "40000000-0000-0000-0000-%012d" % _generation
		plan.transport = SessionScript.TransportKind.WEBRTC
		var peer := SessionScript.SessionPeerInfo.new()
		peer.player_id = PLAYER_B if index == 0 else PLAYER_A
		peer.initiate = index == 0
		plan.peers.append(peer)
		_meshes[index]._apply_plan(plan)


class LoopbackClient:
	extends ClientScript
	var remote: LoopbackClient = null
	var statuses: Array[bool] = []

	func send_signal(_to: String, generation: String, payload: Variant) -> Error:
		remote.signal_received.emit(_player_id, generation, payload)
		return OK

	func send_transport_status(_kind: int, up: bool) -> Error:
		statuses.append(up)
		return OK
