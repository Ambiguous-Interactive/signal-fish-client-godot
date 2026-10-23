extends Node

## Opt-in real WebRTC loopback. Run this scene with a native WebRTC extension
## or export it to Web with the smoke files included in the export preset.

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const EventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const TypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const ROOM := "20000000-0000-0000-0000-000000000001"

var _clients: Array[LoopbackClient] = []
var _meshes: Array[MeshScript] = []
var _drive_multiplayer := true
var _failures: Array[String] = []
var _generation := 0
var _reference: WebRTCPeerConnection = null
var _reference_channels: Array[WebRTCDataChannel] = []


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
	for kind: String in ["PlayerJoined", "PlayerReconnected"]:
		for queued_in_multiplayer: bool in [true, false]:
			if not _phase_ok(
				await _check_membership_boundary(kind, queued_in_multiplayer), "membership " + kind
			):
				break
	for channel_index: int in 3:
		if not _phase_ok(await _check_channel_closure(channel_index), "channel closure"):
			break
	_phase_ok(await _check_reference_channel_contract(), "reference-style responder")
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


func _phase_ok(result: Variant, label: String) -> bool:
	if result == true:
		return true
	_failures.append(label + " phase did not complete")
	return false


func _process(_delta: float) -> void:
	if _reference != null:
		_reference.poll()
	for mesh: MeshScript in _meshes:
		mesh.poll()
		var multiplayer_peer: WebRTCMultiplayerPeer = mesh.get_multiplayer_peer()
		if _drive_multiplayer and multiplayer_peer != null:
			multiplayer_peer.poll()


func _check_membership_boundary(kind: String, queued_in_multiplayer: bool) -> bool:
	_clients[1]._player_epochs[PLAYER_A] = 1
	_announce_membership("PlayerJoined", 1)
	if not await _open_gameplay_link(_generation):
		return false
	var sender: WebRTCMultiplayerPeer = _meshes[0].get_multiplayer_peer()
	var receiver: WebRTCMultiplayerPeer = _meshes[1].get_multiplayer_peer()
	var remote_id := MeshScript.uuid_to_peer_id(PLAYER_A)
	var old_peer := receiver.get_peer(remote_id)
	var old_connection: WebRTCPeerConnection = old_peer["connection"]
	var channels: Array = old_peer["channels"]
	var channel: WebRTCDataChannel = channels[0]
	var prior_plan: SessionScript.SessionPlanInfo = _meshes[1]._plan
	_announce_membership(kind, 1)
	if _meshes[1].get_peer_count() != 1 or receiver.get_peer(remote_id) != old_peer:
		_failures.append(kind + ": duplicate epoch replaced a live peer")
		return false
	_drive_multiplayer = queued_in_multiplayer
	if not await _queue_old_packet(sender, receiver, channel, queued_in_multiplayer):
		return false
	_announce_membership(kind, 2)
	if _meshes[1].get_peer_count() != 0 or receiver.has_peer(remote_id):
		_failures.append(kind + ": fresh membership kept the prior peer")
		return false
	receiver.poll()
	if receiver.get_available_packet_count() != 0:
		_failures.append(kind + ": queued old packet crossed the membership boundary")
		return false
	var relay_count := _clients[1].relay_count
	old_connection.session_description_created.emit("offer", "stale-offer")
	old_connection.ice_candidate_created.emit("", 0, "stale-candidate")
	_clients[1].new_peer.emit(PLAYER_A, false)
	_clients[1].signal_received.emit(PLAYER_A, prior_plan.generation, {"Offer": "stale-offer"})
	_meshes[1]._apply_plan(prior_plan)
	if _meshes[1].get_peer_count() != 0 or _clients[1].relay_count != relay_count:
		_failures.append(kind + ": delayed old-generation work reopened or relayed the peer")
		return false
	_drive_multiplayer = true
	if not await _open_gameplay_link(_generation):
		return false
	print("membership boundary: %s multiplayer_queue=%s passed" % [kind, queued_in_multiplayer])
	return true


func _queue_old_packet(
	sender: WebRTCMultiplayerPeer,
	receiver: WebRTCMultiplayerPeer,
	channel: WebRTCDataChannel,
	queued_in_multiplayer: bool
) -> bool:
	if sender.put_packet("old-incarnation".to_utf8_buffer()) != OK:
		_failures.append("old link refused the queued-packet control")
		return false
	if not await _wait_until(func() -> bool: return channel.get_available_packet_count() > 0):
		_failures.append("control packet never reached the real data channel")
		return false
	if queued_in_multiplayer:
		receiver.poll()
		if receiver.get_available_packet_count() != 1:
			_failures.append("multiplayer queue control was not observable")
			return false
	return true


func _announce_membership(kind: String, epoch: int) -> void:
	var data: Dictionary = {"player_id": PLAYER_A, "epoch": epoch}
	if kind == "PlayerJoined":
		data = {
			"player":
			{
				"id": PLAYER_A,
				"name": "A",
				"is_authority": false,
				"is_connected": true,
				"is_ready": false,
				"epoch": epoch,
			}
		}
	var event: TypesScript.DecodedEvent = EventsScript.decode_envelope({"type": kind, "data": data})
	if event.signal_name == &"protocol_error":
		_failures.append("membership fixture decode failed: " + str(event.args))
		return
	_clients[1]._handle_event(event)


func _check_reference_channel_contract() -> bool:
	for mesh: MeshScript in _meshes:
		mesh._reset_mesh()
	_generation += 1
	var generation := "40000000-0000-0000-0000-%012d" % _generation
	_reference = WebRTCPeerConnection.new()
	if _reference.initialize({"iceServers": []}) != OK:
		_failures.append("reference-style peer refused initialization")
		return false
	_reference.session_description_created.connect(
		func(type: String, sdp: String) -> void:
			_reference.set_local_description(type, sdp)
			_clients[0].signal_received.emit(PLAYER_B, generation, {"Answer": sdp})
	)
	_reference.ice_candidate_created.connect(
		func(_media: String, _index: int, candidate: String) -> void:
			_clients[0].signal_received.emit(PLAYER_B, generation, {"IceCandidate": candidate})
	)
	_reference.data_channel_received.connect(
		func(channel: WebRTCDataChannel) -> void: _reference_channels.append(channel)
	)
	_clients[0].reference = _reference
	var plan := SessionScript.SessionPlanInfo.new()
	plan.generation = generation
	plan.transport = SessionScript.TransportKind.WEBRTC
	var peer := SessionScript.SessionPeerInfo.new()
	peer.player_id = PLAYER_B
	peer.initiate = true
	plan.peers.append(peer)
	_meshes[0]._apply_plan(plan)
	var passed := await _wait_until(
		func() -> bool:
			return (
				_reference.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED
				and _meshes[0]._count_connected_peers() == 1
			)
	)
	if not passed:
		_failures.append("reference-style channel control did not establish SCTP")
	elif not _reference_channels.is_empty():
		passed = false
		_failures.append("negotiated Godot channels unexpectedly announced in-band labels")
	else:
		print("reference-style responder: SCTP connected, in-band channels=0; layout incompatible")
	_clients[0].reference = null
	_meshes[0]._reset_mesh()
	_reference.close()
	_reference = null
	_reference_channels.clear()

	return passed


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
	var relay_count := 0
	var reference: WebRTCPeerConnection = null

	func send_signal(_to: String, generation: String, payload: Variant) -> Error:
		relay_count += 1
		if reference != null:
			var message: Dictionary = payload
			if message.has("Offer"):
				reference.set_remote_description("offer", str(message["Offer"]))
			elif message.has("IceCandidate"):
				reference.add_ice_candidate("", 0, str(message["IceCandidate"]))
			return OK
		remote.signal_received.emit(_player_id, generation, payload)
		return OK

	func send_transport_status(_kind: int, up: bool) -> Error:
		statuses.append(up)
		return OK
