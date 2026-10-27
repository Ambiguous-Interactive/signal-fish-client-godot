# gdlint: disable=max-returns
var _reference_startup_sent := 0
var _reference_startup_received := 0
var _reference_binary_sent: Array[int] = [0, 0, 0]
var _reference_binary_sequences: Array = [[], [], []]
var _reference_ordered_received: Array[int] = []
var _reference_ordered_sent := 0
var _reference_heartbeats := 0
var _reference_acknowledged := 0
var _reference_credit_stride := 8
var _reference_peak_outstanding := 0
var _reference_positions_sent := 0
var _reference_positions_received: Dictionary = {}
var _reference_credit_updated := 0
var _reference_transfer_started := 0
var _reference_transfer_ms := -1
var _reference_sent := false
var _reference_outstanding_bytes := 0
var _reference_peak_outstanding_bytes := 0
var _reference_heartbeat_timings: Array[Dictionary] = []
var _reference_receive_timings: Array[Dictionary] = []
var _reference_receive_timings_dropped := 0
var _reference_snapshot_sent := 0
var _reference_snapshot_received := 0
var _reference_partial_sent := 0
var _reference_partial_received := 0
var _reference_received: Dictionary = {}
var _reference_options: Dictionary = {}
var _reference_receive_pause: Dictionary = {}
var _reference_retirement: Dictionary = {}
var _reference_receiver: MultiplayerPeer


func _run_phase(phase: int) -> bool:
	if phase > 2:
		return true
	_phase = phase
	_reference_startup_sent = 0
	_reference_startup_received = 0
	_reference_binary_sent.assign([0, 0, 0])
	_reference_binary_sequences = [[], [], []]
	_reference_ordered_received.clear()
	_reference_ordered_sent = 0
	_reference_heartbeats = 0
	_reference_acknowledged = 0
	_reference_peak_outstanding = 0
	_reference_positions_sent = 0
	_reference_positions_received.clear()
	_reference_credit_updated = Time.get_ticks_msec()
	_reference_transfer_started = 0
	_reference_transfer_ms = -1
	_reference_sent = false
	_reference_outstanding_bytes = 0
	_reference_peak_outstanding_bytes = 0
	_reference_heartbeat_timings.clear()
	_reference_receive_timings.clear()
	_reference_receive_timings_dropped = 0
	_reference_snapshot_sent = 0
	_reference_snapshot_received = 0
	_reference_partial_sent = 0
	_reference_partial_received = 0
	_reference_received.clear()
	_reference_receive_pause.clear()
	_reference_retirement.clear()
	_reference_options = JSON.parse_string(
		FileAccess.get_file_as_string("res://reference-options.json")
	)
	var window_bytes: int = _reference_options.get("snapshot_window_bytes", 0)
	var body_bytes: int = _reference_options.get("snapshot_body_bytes", 1024)
	_reference_credit_stride = 8
	if window_bytes:
		for count: int in [8, 4, 2, 1]:
			if count * (body_bytes + 32) <= window_bytes:
				_reference_credit_stride = count
				break
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
					"ordered": channel.call("is_ordered"),
					"lifetime": channel.call("get_max_packet_life_time"),
					"retransmits": channel.call("get_max_retransmits"),
					"state": channel.call("get_ready_state")
				}
			)
	var completed := _reference_gameplay_complete()
	var safe: MultiplayerPeer = _mesh.get_safe_multiplayer_peer() if _safe_receive else null
	evidence["remote_closed"] = false
	var closing_channel: Object = null
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
		var queued_proof: Dictionary = {}
		if _reference_options["queued_retirement"]:
			queued_proof = await _reference_queued_retirement(safe, peer, id, phase)
			if queued_proof.is_empty():
				return false
		if safe != null:
			if (
				safe.get_packet_peer() != id
				or safe.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_RELIABLE
			):
				_fail("reference retirement metadata differs")
				return false
		_reference_retirement = {
			"queued_arrival": queued_proof,
			"channel": _reference_options["closing_channel"],
			"seat": _reference_options["closing_seat"],
			"selected": safe != null,
			"queued":
			(
				safe.get_available_packet_count()
				if safe != null
				else peer.call("get_available_packet_count")
			),
			"discarded": false,
			"peer_removed": false,
		}
		_pending.append({"marker": "close-selected-%d" % phase})
		if _reference_options["closing_seat"] == "godot":
			if not await _wait_until(
				"reference armed channel close",
				func() -> bool: return _markers.has("close-armed-%d" % phase)
			):
				return false
			var info: Dictionary = peer.call("get_peer", id)
			var channels: Array = info["channels"]
			var index: int = ["reliable", "ordered", "unreliable"].find(
				_reference_options["closing_channel"]
			)
			closing_channel = channels[index]
			closing_channel.call("close")
		if not await _wait_until(
			"reference required channel close",
			func() -> bool:
				return (
					_mesh.get_peer_count() == 0
					and (
						closing_channel == null
						or closing_channel.call("get_ready_state") == WebRTCDataChannel.STATE_CLOSED
					)
				)
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
		if closing_channel != null:
			_reference_retirement["channel_closed"] = (
				closing_channel.call("get_ready_state") == WebRTCDataChannel.STATE_CLOSED
			)
		_reference_retirement["discarded"] = true
		_reference_retirement["peer_removed"] = true
		evidence["retirement"] = _reference_retirement.duplicate()
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
		(
			not _reference_options.get("startup_burst", false)
			or (_reference_startup_sent == 32 and _reference_startup_received == 32)
		)
		and _reference_snapshot_received == 128
		and _reference_snapshot_sent == 128
		and _reference_partial_sent == 4
		and _reference_partial_received == 4
		and (
			_reference_received.has("reliable")
			if _reference_options.get("native_profile", false)
			else _reference_received.size() == 2
		)
		and (
			not _reference_options.get("native_profile", false)
			or not _reference_ordered_received.is_empty()
		)
		and _reference_binary_complete()
		and _reference_acknowledged == 128
		and (
			_reference_positions_received.size() > 0
			if (
				_reference_options.get("native_profile", false)
				and _reference_options["mixed_traffic"]
			)
			else (
				_reference_positions_received.size()
				== (32 if _reference_options["mixed_traffic"] else 0)
			)
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
		if _reference_options.get("startup_burst", false):
			peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			for sequence: int in 32:
				var data := (
					("startup:%d:godot:%d:" % [_phase, sequence] + "0123456789abcdef".repeat(64))
					. to_utf8_buffer()
				)
				if peer.call("put_packet", data) != OK:
					_fail("reference startup send failed")
					return
				_reference_startup_sent += 1
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
			for count: int in range(_reference_credit_stride, 129, _reference_credit_stride):
				if _markers.has("snapshot-ack-%d-%d" % [_phase, count]):
					_reference_accept_credit(count)
		var acknowledged := _reference_acknowledged
		peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		for _batch: int in 4:
			if _reference_snapshot_sent >= 128 or _reference_snapshot_sent - acknowledged >= 32:
				break
			var bytes := _reference_chunk("godot", _reference_snapshot_sent, false)
			var byte_limit: int = _reference_options.get("snapshot_window_bytes", 0)
			if byte_limit > 0 and _reference_outstanding_bytes + bytes.size() > byte_limit:
				break
			if peer.call("put_packet", bytes) != OK:
				_fail("reference snapshot send failed")
				return
			_reference_snapshot_sent += 1
			_reference_outstanding_bytes += bytes.size()
			_reference_peak_outstanding_bytes = maxi(
				_reference_peak_outstanding_bytes, _reference_outstanding_bytes
			)
			if (
				_reference_options.get("binary_traffic", false)
				and _reference_snapshot_sent % 16 == 0
			):
				if not _reference_send_binary(peer):
					return
			if (
				_reference_options.get("native_profile", false)
				and _reference_snapshot_sent % 16 == 0
			):
				peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
				var ordered := (
					("ordered:%d:godot:%d" % [_phase, _reference_ordered_sent]).to_utf8_buffer()
				)
				if peer.call("put_packet", ordered) != OK:
					_fail("reference ordered send failed")
					return
				_reference_ordered_sent += 1
				peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
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
		if _reference_receive_timings.size() < 1024:
			(
				_reference_receive_timings
				. append(
					{
						"ms": Time.get_ticks_msec(),
						"bytes": packet.data.size(),
						"mode": packet.transfer_mode,
					}
				)
			)
		else:
			_reference_receive_timings_dropped += 1
		if _reference_options.get("binary_traffic", false):
			var binary_result := _reference_accept_binary(packet)
			if binary_result < 0:
				return
			if binary_result > 0:
				continue
		var text := packet.data.get_string_from_utf8()
		if text.begins_with("startup:"):
			var expected := (
				(
					"startup:%d:reference:%d:" % [_phase, _reference_startup_received]
					+ "0123456789abcdef".repeat(64)
				)
				. to_utf8_buffer()
			)
			if (
				not _reference_options.get("startup_burst", false)
				or packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
				or _reference_startup_received >= 32
				or packet.data != expected
			):
				_fail(
					(
						"reference startup bytes or metadata differ: expected_sequence=%d"
						% _reference_startup_received
					)
				)
				return
			_reference_startup_received += 1
			continue
		if text.begins_with("ordered:"):
			var fields := text.split(":")
			var sequence := int(fields[3]) if fields.size() == 4 else -1
			if (
				not _reference_options.get("native_profile", false)
				or packet.error != OK
				or packet.peer_id != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
				or packet.channel != 0
				or packet.transfer_mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
				or sequence < 0
				or sequence >= 8
				or (
					not _reference_ordered_received.is_empty()
					and sequence <= _reference_ordered_received[-1]
				)
				or packet.data != ("ordered:%d:reference:%d" % [_phase, sequence]).to_utf8_buffer()
			):
				_fail("reference ordered bytes or metadata differ")
				return
			_reference_ordered_received.append(sequence)
			continue
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
			(
				_reference_heartbeat_timings
				. append(
					{
						"sequence": _reference_heartbeats,
						"receive_ms": Time.get_ticks_msec(),
					}
				)
			)
			_reference_heartbeats += 1
			peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			if peer.call("put_packet", packet.data) != OK:
				_fail("reference heartbeat echo failed")
				return
			_reference_heartbeat_timings[-1]["echo_ms"] = Time.get_ticks_msec()
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
				or (count != 128 and count % _reference_credit_stride != 0)
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
				_fail(
					(
						"reference snapshot differs: expected_sequence=%d received_sequence=%s bytes=%d mode=%d"
						% [
							sequence,
							text.get_slice(":", 3),
							packet.data.size(),
							packet.transfer_mode
						]
					)
				)
				return
			if partial:
				_reference_partial_received += 1
			else:
				_reference_snapshot_received += 1
				if (
					_reference_snapshot_received == 128
					or _reference_snapshot_received % _reference_credit_stride == 0
				):
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
	_reference_receive_pause["queued_reliable"] = _channel_packet_count(
		reliable, MultiplayerPeer.TRANSFER_MODE_RELIABLE, id
	)
	_reference_receive_pause["queued_unreliable"] = _channel_packet_count(
		unreliable, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, id
	)
	if _reference_receive_pause["elapsed_ms"] < 1500:
		return true
	_reference_receive_pause["received_at_resume"] = _reference_snapshot_received
	_reference_receive_pause["resumed"] = true
	print("WEBRTC_REFERENCE_RECEIVE_RESUME " + JSON.stringify(_reference_receive_pause))
	return false


func _reference_chunk(sender: String, sequence: int, partial: bool) -> PackedByteArray:
	var body_bytes: int = _reference_options.get("snapshot_body_bytes", 1024)
	return (
		(
			("%s:%d:%s:%d:" % ["partial" if partial else "snapshot", _phase, sender, sequence])
			+ "0123456789abcdef".repeat(body_bytes >> 4)
		)
		. to_utf8_buffer()
	)


func _reference_accept_credit(count: int) -> void:
	if count > _reference_acknowledged:
		for sequence: int in range(_reference_acknowledged, count):
			_reference_outstanding_bytes -= _reference_chunk("godot", sequence, false).size()
		_reference_acknowledged = count
		_reference_credit_updated = Time.get_ticks_msec()


func _reference_binary_packet(sender: String, mode: int, sequence: int) -> PackedByteArray:
	var payloads: Dictionary = _reference_options["binary_payloads"][str(_phase)]
	var modes: Array = payloads[sender]
	var packets: Array = modes[mode]
	var data: Array = packets[sequence]
	return PackedByteArray(data)


func _reference_binary_complete() -> bool:
	if not _reference_options.get("binary_traffic", false):
		return true
	var ordered: Array = _reference_binary_sequences[1]
	var unordered: Array = _reference_binary_sequences[2]
	return (
		_reference_binary_sent == [8, 8, 8]
		and _reference_binary_sequences[0] == [0, 1, 2, 3, 4, 5, 6, 7]
		and not ordered.is_empty()
		and ordered[-1] > 0
		and not unordered.is_empty()
		and (unordered.size() > 1 or unordered[0] > 0)
	)


func _reference_send_binary(peer: Object) -> bool:
	var modes := [
		MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
	]
	for index: int in 3:
		var data := _reference_binary_packet("godot", index, _reference_binary_sent[index])
		peer.set("transfer_mode", modes[index])
		if peer.call("put_packet", data) != OK:
			_fail(
				(
					"reference binary send failed: mode=%d sequence=%d"
					% [index, _reference_binary_sent[index]]
				)
			)
			return false
		_reference_binary_sent[index] += 1
	peer.set("transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	return true


func _reference_accept_binary(packet: RefCounted) -> int:
	var modes := [
		MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
	]
	var index := modes.find(packet.get("transfer_mode"))
	if index < 0:
		_fail("reference binary transfer mode differs")
		return -1
	var data: PackedByteArray = packet.get("data")
	for sequence: int in 8:
		if data != _reference_binary_packet("reference", index, sequence):
			continue
		var received: Array = _reference_binary_sequences[index]
		if (
			packet.get("error") != OK
			or packet.get("peer_id") != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
			or packet.get("channel") != 0
			or received.has(sequence)
			or (index != 2 and not received.is_empty() and sequence <= received[-1])
			or (index == 0 and sequence != received.size())
		):
			_fail("reference binary bytes, order or metadata differ")
			return -1
		received.append(sequence)
		return 1
	return 0


func _reference_position(sender: String, sequence: int) -> PackedByteArray:
	return (
		("position:%d:%s:%d:" % [_phase, sender, sequence] + "0123456789abcdef".repeat(4))
		. to_utf8_buffer()
	)


func _reference_evidence() -> Dictionary:
	var body_bytes: int = _reference_options.get("snapshot_body_bytes", 1024)
	var window_bytes: int = _reference_options.get("snapshot_window_bytes", 0)
	var channel_queues: Array[Dictionary] = []
	var peer: Object = _mesh.get_multiplayer_peer() if _mesh != null else null
	var id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	if peer != null and peer.call("has_peer", id):
		var info: Dictionary = peer.call("get_peer", id)
		var channels: Array = info["channels"]
		for index: int in channels.size():
			var channel: WebRTCDataChannel = channels[index]
			var mode: int = [2, 1, 0][index]
			(
				channel_queues
				. append(
					{
						"label": channel.get_label(),
						"available_packets": _channel_packet_count(channel, mode, id),
						"buffered_amount": channel.get_buffered_amount(),
					}
				)
			)
	return {
		"channel_queues": channel_queues,
		"channel_in_buffer_kb":
		ProjectSettings.get_setting("network/limits/webrtc/max_channel_in_buffer_kb"),
		"startup_burst": _reference_options.get("startup_burst", false),
		"startup_sent": _reference_startup_sent,
		"startup_received": _reference_startup_received,
		"native_profile": _reference_options.get("native_profile", false),
		"binary_traffic": _reference_options.get("binary_traffic", false),
		"binary_sent": _reference_binary_sent.duplicate(),
		"binary_sequences": _reference_binary_sequences.duplicate(true),
		"ordered_sent": _reference_ordered_sent,
		"ordered_sequences": _reference_ordered_received.duplicate(),
		"position_sequences": _reference_positions_received.keys(),
		"heartbeat_received": _reference_heartbeats,
		"mixed_traffic": _reference_options.get("mixed_traffic", false),
		"credit_transport": _reference_options.get("credit_transport", "http"),
		"snapshot_body_bytes": body_bytes,
		"snapshot_window_bytes": window_bytes,
		"outstanding_snapshot_bytes": _reference_outstanding_bytes,
		"peak_outstanding_snapshot_bytes": _reference_peak_outstanding_bytes,
		"heartbeat_timings": _reference_heartbeat_timings.duplicate(true),
		"receive_timings": _reference_receive_timings.duplicate(true),
		"receive_timings_dropped": _reference_receive_timings_dropped,
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
		"retirement": _reference_retirement.duplicate(),
	}


func _reference_queued_retirement(
	safe: MultiplayerPeer, peer: Object, id: int, phase: int
) -> Dictionary:
	if (
		safe.get_packet_peer() != id
		or safe.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		or safe.get_packet_channel() != 0
	):
		_fail("reference initial retirement selection differs")
		return {}
	var proof := {"preserved": false, "arrival_wait_ms": 0}
	_reference_retirement["queued_arrival"] = proof
	var started := Time.get_ticks_msec()
	_pending.append({"marker": "close-cached-%d" % phase})
	var info: Dictionary = peer.call("get_peer", id)
	var channels: Array = info["channels"]
	var reliable: WebRTCDataChannel = channels[0]
	var unreliable: WebRTCDataChannel = channels[2]
	if not await _wait_until(
		"reference late retirement arrivals",
		func() -> bool:
			proof["arrival_wait_ms"] = Time.get_ticks_msec() - started
			return (
				reliable.get_available_packet_count() == 1
				and unreliable.get_available_packet_count() == 1
			)
	):
		return {}
	proof["queued_before_read"] = safe.get_available_packet_count()
	if (
		proof["queued_before_read"] != 3
		or safe.get_packet_peer() != id
		or safe.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		or safe.get_packet_channel() != 0
		or safe.get_packet() != ("retirement:%d:unreliable" % phase).to_utf8_buffer()
	):
		_fail("reference late arrival changed selected bytes or metadata")
		return {}
	proof["queued_after_read"] = safe.get_available_packet_count()
	if (
		proof["queued_after_read"] != 2
		or safe.get_packet_peer() != id
		or safe.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_RELIABLE
		or safe.get_packet_channel() != 0
	):
		_fail("reference late reliable selection differs")
		return {}
	proof["preserved"] = true
	return proof
