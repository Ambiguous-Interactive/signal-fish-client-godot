var _reference_sent := false
var _reference_received: Dictionary = {}
var _reference_options: Dictionary = {}


func _run_phase(phase: int) -> bool:
	if phase > 2:
		return true
	_phase = phase
	_reference_sent = false
	_reference_received.clear()
	_reference_options = JSON.parse_string(
		FileAccess.get_file_as_string("res://reference-options.json")
	)
	var plan := SessionScript.SessionPlanInfo.new()
	plan.generation = "40000000-0000-0000-0000-%012d" % phase
	plan.transport = SessionScript.TransportKind.WEBRTC
	var remote := SessionScript.SessionPeerInfo.new()
	remote.player_id = PLAYERS[1 - _seat]
	remote.initiate = _reference_options["godot_offer"]
	plan.peers.append(remote)
	if not remote.initiate:
		_mesh._apply_plan(plan)
	_pending.append({"marker": "ready-%d" % phase})
	if not await _wait_until(
		"reference ready", func() -> bool: return _markers.has("ready-%d" % phase)
	):
		return false
	if remote.initiate:
		_mesh._apply_plan(plan)
	if not await _wait_until(
		"reference observation",
		func() -> bool:
			_reference_packets()
			return _markers.has("observed-%d" % phase)
	):
		return false
	_reference_packets()
	var channel_evidence: Array[Dictionary] = []
	var evidence := {
		"phase": phase,
		"connected": _mesh._count_connected_peers(),
		"retained": _mesh.get_peer_count(),
		"transport_reports": _client.statuses.duplicate(),
		"sent": _reference_sent,
		"received": _reference_received.keys(),
		"channels": channel_evidence
	}
	var peer: Object = _mesh.get_multiplayer_peer()
	var id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	if peer != null and peer.call("has_peer", id):
		var info: Dictionary = peer.call("get_peer", id)
		var channels: Array = info["channels"]
		for channel: Object in channels:
			channel_evidence.append(
				{
					"label": channel.call("get_label"),
					"id": channel.call("get_id"),
					"negotiated": channel.call("is_negotiated"),
					"state": channel.call("get_ready_state")
				}
			)
	print("WEBRTC_REFERENCE_PHASE " + JSON.stringify(evidence))
	_mesh._reset_mesh()
	if _mesh.get_peer_count() != 0 or _mesh.get_multiplayer_peer() != null:
		_fail("reference phase teardown retained peers")
		return false
	_pending.append({"marker": "retired-%d" % phase})
	return await _wait_until(
		"reference teardown", func() -> bool: return _markers.has("retired-%d" % phase)
	)


func _reference_packets() -> void:
	var peer: Object = _mesh.get_multiplayer_peer()
	if peer == null:
		return
	peer.call("poll")
	if not _reference_sent and _mesh._count_connected_peers() == 1:
		_reference_sent = true
		peer.call("set_target_peer", MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat]))
		for label: String in ["reliable", "unreliable"]:
			peer.set(
				"transfer_mode",
				(
					MultiplayerPeer.TRANSFER_MODE_RELIABLE
					if label == "reliable"
					else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
				)
			)
			if peer.call("put_packet", ("godot:%d:%s" % [_phase, label]).to_utf8_buffer()) != OK:
				_fail("reference probe send failed")
	for _read: int in 32:
		var packet := _mesh.receive_packet()
		if packet == null:
			break
		var label := (
			"reliable"
			if packet.transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
			else "unreliable"
		)
		if (
			packet.error != OK
			or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
			or packet.channel != 0
			or packet.transfer_mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
			or packet.data != ("reference:%d:%s" % [_phase, label]).to_utf8_buffer()
			or _reference_received.has(label)
		):
			_fail("reference probe bytes or metadata differ")
			return
		_reference_received[label] = true
