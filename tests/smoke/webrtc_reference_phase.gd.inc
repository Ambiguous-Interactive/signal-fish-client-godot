# gdlint: disable=max-returns
var _reference_heartbeats := 0
var _reference_acknowledged := 0
var _reference_peak_outstanding := 0
var _reference_positions_sent := 0
var _reference_positions_received: Dictionary = {}
var _reference_credit_updated := 0
var _reference_transfer_started := 0
var _reference_transfer_ms := -1
var _reference_sent := false
var _reference_snapshot_sent := 0
var _reference_snapshot_received := 0
var _reference_partial_sent := 0
var _reference_partial_received := 0
var _reference_received: Dictionary = {}
var _reference_options: Dictionary = {}
var _reference_receive_pause: Dictionary = {}
var _reference_receiver: MultiplayerPeer


func _run_phase(phase: int) -> bool:
	if phase > 2:
		return true
	_phase = phase
	_reference_heartbeats = 0
	_reference_acknowledged = 0
	_reference_peak_outstanding = 0
	_reference_positions_sent = 0
	_reference_positions_received.clear()
	_reference_credit_updated = Time.get_ticks_msec()
	_reference_transfer_started = 0
	_reference_transfer_ms = -1
	_reference_sent = false
	_reference_snapshot_sent = 0
	_reference_snapshot_received = 0
	_reference_partial_sent = 0
	_reference_partial_received = 0
	_reference_received.clear()
	_reference_receive_pause.clear()
	_reference_options = JSON.parse_string(
		FileAccess.get_file_as_string("res://reference-options.json")
	)
	_safe_receive = _reference_options["safe_receive"]
	_channel_receive = not _safe_receive
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
	if _safe_receive:
		var receiver: MultiplayerPeer = _mesh.get_safe_multiplayer_peer()
		if phase == 1:
			_reference_receiver = receiver
		elif receiver != _reference_receiver:
			_fail("reference recovery replaced the safe receiver")
			return false
	if not await _wait_until(
		"reference observation",
		func() -> bool:
			_reference_packets()
			return (
				_markers.has("observed-%d" % phase)
				and (_reference_snapshot_received == 0 or _reference_gameplay_complete())
			)
	):
		return false
	_reference_packets()
	var channel_evidence: Array[Dictionary] = []
	var evidence := {
		"phase": phase,
		"same_receiver": _safe_receive and _mesh.get_safe_multiplayer_peer() == _reference_receiver,
		"connected": _mesh._count_connected_peers(),
		"retained": _mesh.get_peer_count(),
		"transport_reports": _client.statuses.duplicate(),
		"sent": _reference_sent,
		"snapshot_sent": _reference_snapshot_sent,
		"snapshot_received": _reference_snapshot_received,
		"partial_sent": _reference_partial_sent,
		"partial_received": _reference_partial_received,
		"received": _reference_received.keys(),
		"channels": channel_evidence
	}
	evidence.merge(_reference_evidence())
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
	var completed := _reference_gameplay_complete()
	var safe: MultiplayerPeer = _mesh.get_safe_multiplayer_peer() if _safe_receive else null
	evidence["remote_closed"] = false
	if completed:
		_pending.append({"marker": "close-ready-%d" % phase})
		if not await _wait_until(
			"reference queued retirement packet",
			func() -> bool:
				return (
					safe.get_available_packet_count() > 0
					if safe != null
					else peer.call("get_available_packet_count") > 0
				)
		):
			return false
		if safe != null:
			if (
				safe.get_packet_peer() != id
				or safe.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_RELIABLE
			):
				_fail("reference retirement metadata differs")
				return false
		_pending.append({"marker": "close-selected-%d" % phase})
		if not await _wait_until(
			"reference remote channel close", func() -> bool: return _mesh.get_peer_count() == 0
		):
			return false
		if (
			safe != null
			and (safe.get_available_packet_count() != 0 or not safe.get_packet().is_empty())
		):
			_fail("reference remote close retained selected bytes")
			return false
		if safe == null and _mesh.receive_packet() != null:
			_fail("reference remote close retained raw bytes")
			return false
		evidence["remote_closed"] = true
	print("WEBRTC_REFERENCE_PHASE " + JSON.stringify(evidence))
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	_mesh._apply_plan(relay)
	if _mesh.get_peer_count() != 0:
		_fail("reference phase teardown retained peers")
		return false
	_pending.append({"marker": "retired-%d" % phase})
	return await _wait_until(
		"reference teardown", func() -> bool: return _markers.has("retired-%d" % phase)
	)


func _reference_gameplay_complete() -> bool:
	return (
		_reference_snapshot_received == 128
		and _reference_snapshot_sent == 128
		and _reference_partial_sent == 4
		and _reference_partial_received == 4
		and _reference_received.size() == 2
		and _reference_acknowledged == 128
		and (
			_reference_positions_received.size()
			== (32 if _reference_options["mixed_traffic"] else 0)
		)
	)


func _reference_packets() -> void:
	var peer: Object = _mesh.get_multiplayer_peer()
	if peer == null:
		return
	peer.call("poll")
	if not _reference_sent and _mesh._count_connected_peers() == 1:
		_reference_sent = true
		_reference_transfer_started = Time.get_ticks_msec()
		_reference_credit_updated = _reference_transfer_started
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
	if _reference_sent and _mesh._count_connected_peers() == 1:
		if _reference_options["credit_transport"] == "http":
			for count: int in range(8, 129, 8):
				if _markers.has("snapshot-ack-%d-%d" % [_phase, count]):
					_reference_accept_credit(count)
		var acknowledged := _reference_acknowledged
		peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		for _batch: int in 4:
			if _reference_snapshot_sent >= 128 or _reference_snapshot_sent - acknowledged >= 32:
				break
			var bytes := _reference_chunk("godot", _reference_snapshot_sent, false)
			if peer.call("put_packet", bytes) != OK:
				_fail("reference snapshot send failed")
				return
			_reference_snapshot_sent += 1
			_reference_peak_outstanding = maxi(
				_reference_peak_outstanding, _reference_snapshot_sent - acknowledged
			)
			if _reference_options["mixed_traffic"] and _reference_snapshot_sent % 4 == 0:
				peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
				var position := _reference_position("godot", _reference_positions_sent)
				if peer.call("put_packet", position) != OK:
					_fail("reference position send failed")
					return
				_reference_positions_sent += 1
				peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		if (
			acknowledged == 128
			and _reference_snapshot_received == 128
			and _reference_partial_sent == 0
		):
			_reference_transfer_ms = Time.get_ticks_msec() - _reference_transfer_started
			for sequence: int in 4:
				if peer.call("put_packet", _reference_chunk("godot", sequence, true)) != OK:
					_fail("reference partial snapshot send failed")
					return
				_reference_partial_sent += 1
	for _read: int in 32:
		if _reference_pause_reads(peer):
			return
		if _safe_receive and _mesh.get_safe_multiplayer_peer().get_available_packet_count() == 0:
			break
		var packet := (
			_read_packet(peer as WebRTCMultiplayerPeer) if _safe_receive else _mesh.receive_packet()
		)
		if packet == null:
			break
		var text := packet.data.get_string_from_utf8()
		if text.begins_with("heartbeat:"):
			var expected := (
				(
					"heartbeat:%d:reference:%d:" % [_phase, _reference_heartbeats]
					+ "0123456789abcdef".repeat(4)
				)
				. to_utf8_buffer()
			)
			if (
				not _reference_options["mixed_traffic"]
				or packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
				or _reference_heartbeats >= 128
				or packet.data != expected
			):
				_fail("reference heartbeat bytes or metadata differ")
				return
			_reference_heartbeats += 1
			peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			if peer.call("put_packet", packet.data) != OK:
				_fail("reference heartbeat echo failed")
				return
			continue
		if text.begins_with("credit:"):
			var fields := text.split(":")
			var count := int(fields[4]) if fields.size() == 5 else -1
			if (
				_reference_options["credit_transport"] != "webrtc"
				or packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
				or text != "credit:%d:reference:godot:%d" % [_phase, count]
				or count <= _reference_acknowledged
				or count > _reference_snapshot_sent
				or count % 8 != 0
			):
				_fail("reference consumption credit differs")
				return
			_reference_accept_credit(count)
			continue
		if text.begins_with("position:"):
			var fields := text.split(":")
			var sequence := int(fields[3]) if fields.size() == 5 else -1
			if (
				not _reference_options["mixed_traffic"]
				or packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
				or sequence < 0
				or sequence >= 32
				or _reference_positions_received.has(sequence)
				or packet.data != _reference_position("reference", sequence)
			):
				_fail("reference position bytes or metadata differ")
				return
			_reference_positions_received[sequence] = true
			continue
		if text.begins_with("snapshot:") or text.begins_with("partial:"):
			var partial := text.begins_with("partial:")
			var sequence := _reference_partial_received if partial else _reference_snapshot_received
			if (
				packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
				or sequence >= (4 if partial else 128)
				or packet.data != _reference_chunk("reference", sequence, partial)
			):
				_fail("reference snapshot bytes or metadata differ")
				return
			if partial:
				_reference_partial_received += 1
			else:
				_reference_snapshot_received += 1
				if _reference_snapshot_received % 8 == 0:
					if _reference_options["credit_transport"] == "http":
						_pending.append(
							{
								"marker":
								"snapshot-ack-%d-%d" % [_phase, _reference_snapshot_received]
							}
						)
					else:
						peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
						var credit := (
							(
								"credit:%d:godot:reference:%d"
								% [_phase, _reference_snapshot_received]
							)
							. to_utf8_buffer()
						)
						if peer.call("put_packet", credit) != OK:
							_fail("reference credit send failed")
							return
			continue
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


func _reference_pause_reads(peer: Object) -> bool:
	if not _reference_options.get("slow_receiver", false) or _reference_snapshot_received < 8:
		return false
	if _reference_receive_pause.is_empty():
		_reference_receive_pause = {
			"started_ms": Time.get_ticks_msec(),
			"received": _reference_snapshot_received,
			"resumed": false,
		}
	if _reference_receive_pause["resumed"]:
		return false
	var id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	if not peer.call("has_peer", id):
		return true
	var info: Dictionary = peer.call("get_peer", id)
	var channels: Array = info["channels"]
	_reference_receive_pause["elapsed_ms"] = (
		Time.get_ticks_msec() - _reference_receive_pause["started_ms"]
	)
	var reliable: Object = channels[0]
	var unreliable: Object = channels[2]
	_reference_receive_pause["queued_reliable"] = reliable.call("get_available_packet_count")
	_reference_receive_pause["queued_unreliable"] = unreliable.call("get_available_packet_count")
	if _reference_receive_pause["elapsed_ms"] < 1500:
		return true
	_reference_receive_pause["received_at_resume"] = _reference_snapshot_received
	_reference_receive_pause["resumed"] = true
	print("WEBRTC_REFERENCE_RECEIVE_RESUME " + JSON.stringify(_reference_receive_pause))
	return false


func _reference_chunk(sender: String, sequence: int, partial: bool) -> PackedByteArray:
	return (
		(
			("%s:%d:%s:%d:" % ["partial" if partial else "snapshot", _phase, sender, sequence])
			+ "0123456789abcdef".repeat(64)
		)
		. to_utf8_buffer()
	)


func _reference_accept_credit(count: int) -> void:
	if count > _reference_acknowledged:
		_reference_acknowledged = count
		_reference_credit_updated = Time.get_ticks_msec()


func _reference_position(sender: String, sequence: int) -> PackedByteArray:
	return (
		("position:%d:%s:%d:" % [_phase, sender, sequence] + "0123456789abcdef".repeat(4))
		. to_utf8_buffer()
	)


func _reference_evidence() -> Dictionary:
	return {
		"heartbeat_received": _reference_heartbeats,
		"mixed_traffic": _reference_options.get("mixed_traffic", false),
		"credit_transport": _reference_options.get("credit_transport", "http"),
		"snapshot_sent": _reference_snapshot_sent,
		"snapshot_received": _reference_snapshot_received,
		"snapshot_acknowledged": _reference_acknowledged,
		"positions_sent": _reference_positions_sent,
		"positions_received": _reference_positions_received.size(),
		"peak_outstanding": _reference_peak_outstanding,
		"credit_wait_age_ms":
		(
			Time.get_ticks_msec() - _reference_credit_updated
			if _reference_snapshot_sent > _reference_acknowledged
			else 0
		),
		"transfer_ms": _reference_transfer_ms,
		"receive_pause": _reference_receive_pause.duplicate(),
	}
