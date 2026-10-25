extends "res://tests/smoke/webrtc_interop_drill.gd"
# gdlint: disable=max-returns

const ROSTER: Array[String] = [
	"10000000-0000-0000-0000-000000000001",
	"10000000-0000-0000-0000-000000000002",
	"10000000-0000-0000-0000-000000000003"
]
const CHUNKS := 64
const SAMPLES := 32
const WINDOW := 8

var _safe: MultiplayerPeer
var _targets: Array[int] = []
var _counts: Dictionary = {}
var _sent := 0
var _saved: Dictionary = {}
var _connections: Dictionary = {}
var _last_packet: Dictionary = {}


func _ready() -> void:
	_signal_players = ROSTER
	_safe_receive = true
	if OS.has_feature("web"):
		var seat_text: String = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('seat') || '1'"
		)
		_seat = seat_text.to_int()
		_url = JavaScriptBridge.eval("window.location.origin")
	else:
		_url = OS.get_cmdline_user_args()[0]
	_inbox = HTTPRequest.new()
	_outbox = HTTPRequest.new()
	add_child(_inbox)
	add_child(_outbox)
	_inbox.request_completed.connect(_on_inbox)
	_outbox.request_completed.connect(_on_outbox)
	var client := RoutedClient.new()
	client._player_id = ROSTER[_seat]
	client._room_id = "20000000-0000-0000-0000-000000000001"
	client._connection_state = ClientScript.ConnectionState.CONNECTED
	client._session_state = ClientScript.SessionState.IN_ROOM_FINALIZED
	client.routed_relay = func(to: String, generation: String, payload: Variant) -> void:
		_pending.append(
			{"to": ROSTER.find(to), "from": _seat, "generation": generation, "payload": payload}
		)
	_client = client
	_mesh = MeshScript.new()
	_mesh.attach(_client)
	if OS.has_feature("web") and not await _wait_web_start():
		return
	if not await _connect_generation(1):
		return
	_safe = _mesh.get_safe_multiplayer_peer()
	_safe.peer_connected.connect(func(id: int) -> void: _rpc_connected.append(id))
	_safe.peer_disconnected.connect(func(id: int) -> void: _rpc_disconnected.append(id))
	if not await _wait_until(
		"three-seat peer notifications",
		func() -> bool:
			_safe.poll()
			return _rpc_connected.size() == 2
	):
		return
	if not await _traffic(1, _others()):
		return
	if not await _select_survivor():
		return
	if not await _retire_one_link():
		return
	var survivors := _surviving_seats()
	if not await _traffic(2, survivors):
		return
	if not await _connect_generation(3):
		return
	if _mesh.get_safe_multiplayer_peer() != _safe:
		_fail("generation replaced the safe receiver")
		return
	if not await _wait_until(
		"fresh triangle notifications",
		func() -> bool:
			_safe.poll()
			return _rpc_connected.size() == 4 and _rpc_disconnected.size() == 2
	):
		return
	if not await _traffic(3, _others()):
		return
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	_mesh._apply_plan(relay)
	_safe.poll()
	if _safe.get_available_packet_count() != 0 or _rpc_disconnected.size() != 4:
		_fail("final teardown retained packets or missed disconnections")
		return
	if not await _barrier("teardown"):
		return
	_finished = true
	_inbox.cancel_request()
	_outbox.cancel_request()
	_mesh.detach()
	_mesh.free()
	_mesh = null
	_client.free()
	_client = null
	print("WEBRTC_INTEROP_PASS seat=%d" % _seat)
	get_tree().quit()


func _wait_web_start() -> bool:
	_start_stage("web engine startup")
	print("WEBRTC_MULTIPEER_LOADED seat=%d" % _seat)
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		if JavaScriptBridge.eval("window.sfMeshStart === true"):
			return true
		await get_tree().process_frame
	_fail("driver did not release engine startup")
	return false


func _others() -> Array[int]:
	var seats: Array[int] = []
	for seat: int in 3:
		if seat != _seat:
			seats.append(seat)
	return seats


func _surviving_seats() -> Array[int]:
	var seats: Array[int] = [0, 1]
	if _seat < 2:
		seats = [2]
	return seats


func _barrier(marker: String) -> bool:
	for seat: int in _others():
		_pending.append({"to": seat, "from": _seat, "marker": "%s-%d" % [marker, _seat]})
	return await _wait_until(
		marker,
		func() -> bool:
			for seat: int in _others():
				if not _markers.has("%s-%d" % [marker, seat]):
					return false
			return _pending.is_empty() and not _sending
	)


func _connect_generation(phase: int) -> bool:
	_phase = phase
	var plan := SessionScript.SessionPlanInfo.new()
	plan.generation = "40000000-0000-0000-0000-%012d" % phase
	plan.transport = SessionScript.TransportKind.WEBRTC
	for seat: int in _others():
		var remote := SessionScript.SessionPeerInfo.new()
		remote.player_id = ROSTER[seat]
		remote.initiate = _seat < seat
		plan.peers.append(remote)
	# Install responders before any seat sends an offer.
	var responders := SessionScript.SessionPlanInfo.new()
	responders.generation = plan.generation
	responders.transport = plan.transport
	for remote: SessionScript.SessionPeerInfo in plan.peers:
		if not remote.initiate:
			responders.peers.append(remote)
	_mesh._apply_plan(responders)
	if not await _barrier("responders-%d" % phase):
		return false
	_mesh._apply_plan(plan)
	return await _wait_until(
		"triangle channels open", func() -> bool: return _mesh._count_connected_peers() == 2
	)


func _traffic(phase: int, targets: Array[int]) -> bool:
	_phase = phase
	if _mesh.get_safe_multiplayer_peer() != _safe:
		_fail("traffic replaced the safe receiver")
		return false
	_targets = targets
	_counts.clear()
	_sent = 0
	for seat: int in targets:
		_counts[seat] = [0, 0, 0]
	if not await _barrier("traffic-ready-%d" % phase):
		return false
	if not await _wait_until(
		"directed concurrent snapshots and positions",
		func() -> bool:
			_safe.poll()
			while _safe.get_available_packet_count() > 0:
				var sender := _safe.get_packet_peer()
				var mode := _safe.get_packet_mode()
				var channel := _safe.get_packet_channel()
				var data := _safe.get_packet()
				var seat := _seat_for_id(sender)
				if (
					_safe.get_packet_error() != OK
					or not targets.has(seat)
					or channel != 0
					or mode < 0
					or mode > 2
				):
					_fail("multi-peer packet sender, mode, channel or read error differs")
					return false
				_last_packet = {
					"sender": sender,
					"seat": seat,
					"mode": mode,
					"channel": channel,
					"bytes": data.size(),
					"sequence": data.decode_u32(0) if data.size() >= 4 else -1
				}
				var counts: Array = _counts[seat]
				var sequence := int(data.decode_u32(0)) if data.size() >= 4 else -1
				var limit := CHUNKS if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE else SAMPLES
				if (
					sequence != counts[mode]
					or sequence >= limit
					or data != _sample_bytes(phase, seat, _seat, mode, sequence)
				):
					_fail("multi-peer packet bytes or sequence differ")
					return false
				counts[mode] += 1
			var received_floor := CHUNKS
			for counts: Array in _counts.values():
				var received: int = counts[2]
				received_floor = mini(received_floor, received)
			if _sent < CHUNKS and _sent < received_floor + WINDOW:
				for seat: int in targets:
					_safe.set_target_peer(MeshScript.uuid_to_peer_id(ROSTER[seat]))
					for mode: int in 3:
						if mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE and _sent >= SAMPLES:
							continue
						_safe.transfer_mode = mode as MultiplayerPeer.TransferMode
						if _safe.put_packet(_sample_bytes(phase, _seat, seat, mode, _sent)) != OK:
							_fail("multi-peer directed send failed")
							return false
				_sent += 1
			if _sent != CHUNKS:
				return false
			for counts: Array in _counts.values():
				if counts != [SAMPLES, SAMPLES, CHUNKS]:
					return false
			return true
	):
		return false
	if not await _barrier("traffic-done-%d" % phase):
		return false
	print("WEBRTC_MULTIPEER_PHASE " + JSON.stringify(_snapshot()))
	return true


func _sample_bytes(
	phase: int, sender: int, target: int, mode: int, sequence: int
) -> PackedByteArray:
	var data := _burst_packet(
		phase, sender * 3 + target, sequence * 3 + mode, 1200 if mode == 2 else 32
	)
	data.encode_u32(0, sequence)
	return data


func _seat_for_id(id: int) -> int:
	for seat: int in 3:
		if MeshScript.uuid_to_peer_id(ROSTER[seat]) == id:
			return seat
	return -1


func _select_survivor() -> bool:
	_connections.clear()
	var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
	for id: int in peer.get_peers():
		_connections[id] = peer.get_peer(id)["connection"]
	var recipients := _surviving_seats()
	for seat: int in recipients:
		_safe.set_target_peer(MeshScript.uuid_to_peer_id(ROSTER[seat]))
		_safe.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
		if _safe.put_packet(_sample_bytes(2, _seat, seat, 2, 0)) != OK:
			_fail("survivor marker send failed")
			return false
	if not await _wait_until(
		"select surviving packet",
		func() -> bool: return _safe.get_available_packet_count() >= (1 if _seat < 2 else 2)
	):
		return false
	_saved = {
		"peer": _safe.get_packet_peer(),
		"mode": _safe.get_packet_mode(),
		"channel": _safe.get_packet_channel()
	}
	return await _barrier("survivor-selected")


func _retire_one_link() -> bool:
	if _seat == 0:
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		var channels: Array = peer.get_peer(MeshScript.uuid_to_peer_id(ROSTER[1]))["channels"]
		var channel: WebRTCDataChannel = channels[0]
		channel.close()
	if not await _wait_until(
		"selective retirement notifications",
		func() -> bool:
			_safe.poll()
			return (
				_mesh.get_peer_count() == (1 if _seat < 2 else 2)
				and _rpc_disconnected.size() == (1 if _seat < 2 else 0)
			)
	):
		return false
	if not await _barrier("selective-retirement"):
		return false
	for seat: int in [2] if _seat < 2 else [0, 1]:
		var id := MeshScript.uuid_to_peer_id(ROSTER[seat])
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if not peer.has_peer(id) or peer.get_peer(id)["connection"] != _connections[id]:
			_fail("selective retirement replaced an unrelated connection")
			return false
	if (
		_saved
		!= {
			"peer": _safe.get_packet_peer(),
			"mode": _safe.get_packet_mode(),
			"channel": _safe.get_packet_channel()
		}
	):
		_fail("selective retirement changed the surviving selected metadata")
		return false
	var seen: Dictionary = {}
	var remaining := 1 if _seat < 2 else 2
	for _index: int in remaining:
		var seat := _seat_for_id(_safe.get_packet_peer())
		if not _surviving_seats().has(seat) or seen.has(seat):
			_fail("survivor sender is missing or repeated")
			return false
		seen[seat] = true
		if _safe.get_packet_mode() != 2 or _safe.get_packet_channel() != 0:
			_fail("survivor metadata differs")
			return false
		var data := _safe.get_packet()
		if _safe.get_packet_error() != OK or data != _sample_bytes(2, seat, _seat, 2, 0):
			_fail("survivor bytes differ after unrelated retirement")
			return false
	return true


func _snapshot() -> Dictionary:
	var snapshot := super._snapshot()
	snapshot["multi_peer"] = true
	snapshot["same_safe_receiver"] = (
		_mesh != null and _safe != null and _mesh.get_safe_multiplayer_peer() == _safe
	)
	snapshot["directed_targets"] = _targets
	snapshot["received_by_seat_and_mode"] = _counts
	snapshot["sent_per_target"] = _sent
	snapshot["selected_survivor"] = _saved
	snapshot["last_directed_packet"] = _last_packet
	return snapshot


class RoutedClient:
	extends DrillClient
	var routed_relay: Callable

	func send_signal(to: String, generation: String, payload: Variant) -> Error:
		routed_relay.call(to, generation, payload)
		return OK
