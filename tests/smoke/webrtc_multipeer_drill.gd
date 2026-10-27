extends "res://tests/smoke/webrtc_interop_drill.gd"
# gdlint: disable=max-returns

const MultiRpcProbeScript = preload("res://tests/smoke/webrtc_multipeer_rpc_probe.gd")

const ROSTER: Array[String] = [
	"10000000-0000-0000-0000-000000000001",
	"10000000-0000-0000-0000-000000000002",
	"10000000-0000-0000-0000-000000000003"
]
const CHUNKS := 64
const SAMPLES := 32
const WINDOW := 8

var _http_credit_hold_proof: Dictionary = {}
var _credit_transport := "http"
var _credits_sent: Dictionary = {}
var _credits_received: Dictionary = {}
var _credit_events: Array[Dictionary] = []
var _rpc_multi_proof: Dictionary = {}
var _rpc_multi_reader_paused := false
var _rpc_multi_reader_resumed := false
var _rpc_multi_fast_pair := false
var _rpc_multi_poll_us := 0
var _rpc_multi_max_poll_us := 0
var _rpc_multi_poll_count := 0
var _retirement_case := 0
var _closing_seat := 0
var _remote_seat := 1
var _closing_channel := 0
var _hub_seat := 2
var _delay_reader := false
var _safe: MultiplayerPeer
var _targets: Array[int] = []
var _counts: Dictionary = {}
var _sent: Dictionary = {}
var _acked: Dictionary = {}
var _peak_outstanding: Dictionary = {}
var _slow_receiver := false
var _reader_paused := false
var _reader_resumed := false
var _fast_pair_announced := false
var _paused_proof: Dictionary = {}
var _credit_updated: Dictionary = {}
var _saved: Dictionary = {}
var _interruption: Dictionary = {}
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
		_credit_transport = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('credit_transport') || 'http'"
		)
		_slow_receiver = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).has('slow_receiver')"
		)
		var case_text: String = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('retirement_case') || '0'"
		)
		_retirement_case = case_text.to_int()
		_rpc_traffic = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).has('rpc_traffic')"
		)
		_url = JavaScriptBridge.eval("window.location.origin")
	else:
		_url = OS.get_cmdline_user_args()[0]
		_slow_receiver = OS.get_cmdline_user_args().has("--slow-receiver")
		_rpc_traffic = OS.get_cmdline_user_args().has("--rpc-traffic")
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--credit-transport="):
				_credit_transport = arg.trim_prefix("--credit-transport=")
			if arg.begins_with("--retirement-case="):
				_retirement_case = arg.trim_prefix("--retirement-case=").to_int()
	if _credit_transport not in ["http", "webrtc"]:
		_fail("unknown consumption credit transport")
		return
	_closing_seat = int(float(_retirement_case) / 6)
	_remote_seat = (_closing_seat + 1 + int(float(_retirement_case % 6) / 3)) % 3
	_closing_channel = _retirement_case % 3
	_hub_seat = 3 - _closing_seat - _remote_seat
	if not _check_lifetime_controls():
		return
	_setup_http()
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
	if _rpc_traffic:
		_setup_multi_rpc()
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
	if not await _queue_interruption():
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
	_release_rpc_recovery()
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
	if _seat == _hub_seat:
		return _others()
	return [_hub_seat]


func _retiring_remote() -> int:
	return _remote_seat if _seat == _closing_seat else _closing_seat


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
	if not await _wait_until(
		"triangle channels open", func() -> bool: return _mesh._count_connected_peers() == 2
	):
		return false
	print("WEBRTC_CHANNEL_CONTRACT " + JSON.stringify(_snapshot()))
	return true


func _traffic(phase: int, targets: Array[int]) -> bool:
	_phase = phase
	if _mesh.get_safe_multiplayer_peer() != _safe:
		_fail("traffic replaced the safe receiver")
		return false
	_reset_transfer_counts(targets)
	_delay_reader = _slow_receiver and (phase != 2 or _hub_seat != 1)
	_reader_paused = _delay_reader and _seat == 1
	if not await _barrier("traffic-ready-%d" % phase):
		return false
	var transfer := func() -> bool:
		_safe.poll()
		if (
			_reader_paused
			and _markers.has("fast-pair-%d-0" % phase)
			and _markers.has("fast-pair-%d-2" % phase)
		):
			_reader_paused = false
			_reader_resumed = true
		while not _reader_paused and _safe.get_available_packet_count() > 0:
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
			if data.size() == 20 or (data.size() >= 4 and data.decode_u32(0) == 0xFFFFFFFF):
				var count := int(data.decode_u32(16)) if data.size() == 20 else -1
				if (
					_credit_transport != "webrtc"
					or mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
					or count != _acked[seat] + WINDOW
					or count > _sent[seat]
					or data != _credit_bytes(phase, seat, _seat, count)
				):
					_fail("multi-peer consumption credit bytes, sequence or metadata differ")
					return false
				_record_credit("received", seat, count)
				_acked[seat] = count
				_credits_received[seat] += 1
				_credit_updated[seat] = Time.get_ticks_msec()
				continue
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
			var consumed: int = counts[mode]
			if mode == 2 and consumed % WINDOW == 0:
				if _credit_transport == "http":
					_pending.append(
						{"to": seat, "from": _seat, "marker": _ack_marker(phase, _seat, consumed)}
					)
				else:
					_safe.set_target_peer(sender)
					_safe.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
					var error := _safe.put_packet(_credit_bytes(phase, _seat, seat, consumed))
					_record_credit("issued", seat, consumed, error)
					if error != OK:
						_fail("multi-peer consumption credit send failed")
						return false
				if _credit_transport == "http":
					_record_credit("issued", seat, consumed)
				_credits_sent[seat] += 1
		for seat: int in targets:
			var acknowledged: int = _acked[seat]
			while (
				_credit_transport == "http"
				and acknowledged < CHUNKS
				and _markers.has(_ack_marker(phase, seat, acknowledged + WINDOW))
			):
				acknowledged += WINDOW
				_record_credit("received", seat, acknowledged)
				_credits_received[seat] += 1
			if acknowledged != _acked[seat]:
				_credit_updated[seat] = Time.get_ticks_msec()
			_acked[seat] = acknowledged
			for _batch: int in 4:
				var sequence: int = _sent[seat]
				if sequence >= CHUNKS or sequence - acknowledged >= WINDOW:
					break
				_safe.set_target_peer(MeshScript.uuid_to_peer_id(ROSTER[seat]))
				for mode: int in 3:
					if mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE and sequence >= SAMPLES:
						continue
					_safe.transfer_mode = mode as MultiplayerPeer.TransferMode
					if _safe.put_packet(_sample_bytes(phase, _seat, seat, mode, sequence)) != OK:
						_fail("multi-peer directed send failed")
						return false
				_sent[seat] = sequence + 1
				if sequence + 1 - acknowledged == WINDOW:
					_credit_updated[seat] = Time.get_ticks_msec()
				var peak: int = _peak_outstanding[seat]
				_peak_outstanding[seat] = maxi(peak, sequence + 1 - acknowledged)
		if (
			_seat == 0
			and phase == 1
			and _credit_transport == "http"
			and _http_credit_hold_proof.is_empty()
			and _sent.get(1) == WINDOW
			and _acked.get(1) == 0
			and _acked.get(2) == CHUNKS
			and _counts.get(2) == [SAMPLES, SAMPLES, CHUNKS]
		):
			_http_credit_hold_proof = {
				"sent": _sent.duplicate(),
				"acknowledged": _acked.duplicate(),
				"received": _counts.duplicate(true),
				"tick_ms": Time.get_ticks_msec()
			}
			_pending.append({"to": 2, "from": 0, "marker": "credit-hold-proof-1-0"})
		if _delay_reader and _seat != 1 and not _fast_pair_announced:
			var fast_seat := 2 if _seat == 0 else 0
			if _acked[fast_seat] == CHUNKS and _counts[fast_seat] == [SAMPLES, SAMPLES, CHUNKS]:
				if _acked.get(1, 0) != 0 or _sent.get(1, WINDOW) != WINDOW:
					_fail("delayed reader advanced before the independent pair completed")
					return false
				_fast_pair_announced = true
				_paused_proof = {
					"sent": _sent.duplicate(),
					"acknowledged": _acked.duplicate(),
					"received": _counts.duplicate(true)
				}
				_pending.append(
					{"to": 1, "from": _seat, "marker": "fast-pair-%d-%d" % [phase, _seat]}
				)
		for seat: int in targets:
			if _acked[seat] != CHUNKS:
				return false
		for counts: Array in _counts.values():
			if counts != [SAMPLES, SAMPLES, CHUNKS]:
				return false
		return true
	if _delay_reader:
		if not await _wait_until(
			"independent pair while reader paused",
			func() -> bool:
				transfer.call()
				return _reader_resumed if _seat == 1 else _fast_pair_announced
		):
			return false
	if not await _wait_until("directed concurrent snapshots and positions", transfer):
		return false
	if (
		_delay_reader
		and ((_seat == 1 and not _reader_resumed) or (_seat != 1 and not _fast_pair_announced))
	):
		_fail("delayed-reader independence was not exercised")
		return false
	if not await _barrier("traffic-done-%d" % phase):
		return false
	if _rpc_traffic and not await _multi_rpc_traffic(phase, targets):
		return false
	print("WEBRTC_MULTIPEER_PHASE " + JSON.stringify(_snapshot()))
	return true


func _setup_multi_rpc() -> void:
	get_tree().multiplayer_poll = false
	_rpc_probe = MultiRpcProbeScript.new()
	_rpc_probe.name = "MultiRpcProbe"
	add_child(_rpc_probe)
	_rpc_api = SceneMultiplayer.new()
	get_tree().set_multiplayer(_rpc_api, _rpc_probe.get_path())
	_rpc_api.multiplayer_peer = _safe


func _multi_rpc_traffic(phase: int, target_seats: Array[int]) -> bool:
	if _rpc_api.multiplayer_peer != _safe:
		_fail("three-seat RPC adapter changed")
		return false
	var probe: MultiRpcProbeScript = _rpc_probe
	var ids: Array[int] = []
	for target: int in target_seats:
		ids.append(MeshScript.uuid_to_peer_id(ROSTER[target]))
	probe.reset_multi(phase, _seat, ids)
	if not await _wait_until(
		"three-seat RPC discovery",
		func() -> bool:
			_rpc_api.poll()
			return _rpc_api.get_peers().size() == target_seats.size()
	):
		return false
	if not await _barrier("rpc-ready-%d" % phase):
		return false
	_rpc_multi_reader_paused = _delay_reader and _seat == 1
	_rpc_multi_reader_resumed = false
	_rpc_multi_fast_pair = false
	_rpc_multi_proof.clear()
	_rpc_multi_poll_us = 0
	_rpc_multi_max_poll_us = 0
	_rpc_multi_poll_count = 0
	var transfer := func() -> bool:
		if (
			_rpc_multi_reader_paused
			and _markers.has("rpc-fast-%d-0" % phase)
			and _markers.has("rpc-fast-%d-2" % phase)
		):
			_rpc_multi_reader_paused = false
			_rpc_multi_reader_resumed = true
		if not _rpc_multi_reader_paused:
			var started := Time.get_ticks_usec()
			var error := _rpc_api.poll()
			var elapsed := Time.get_ticks_usec() - started
			_rpc_multi_poll_us += elapsed
			_rpc_multi_max_poll_us = maxi(_rpc_multi_max_poll_us, elapsed)
			_rpc_multi_poll_count += 1
			if error != OK:
				_fail("three-seat RPC poll failed")
				return false
		probe.send_batch()
		if not probe.failure.is_empty():
			_fail(probe.failure)
			return false
		if _delay_reader and _seat != 1 and not _rpc_multi_fast_pair:
			var fast_seat := 2 if _seat == 0 else 0
			if probe.pair_complete(MeshScript.uuid_to_peer_id(ROSTER[fast_seat])):
				var slow_id := MeshScript.uuid_to_peer_id(ROSTER[1])
				if (
					probe.acknowledged.get(slow_id, 0) != 0
					or probe.sent_by_peer.get(slow_id, WINDOW) != WINDOW
				):
					_fail("paused RPC reader advanced before independent pair completed")
					return false
				_rpc_multi_fast_pair = true
				_rpc_multi_proof = probe.evidence()
				_pending.append(
					{"to": 1, "from": _seat, "marker": "rpc-fast-%d-%d" % [phase, _seat]}
				)
		return probe.complete() and not _rpc_multi_reader_paused
	if not await _wait_until("three-seat RPC snapshots with data-channel credit", transfer):
		return false
	# Every sample is consumed before any seat may resume raw packet reads.
	return await _barrier("rpc-done-%d" % phase) and probe.failure.is_empty()


func _reset_transfer_counts(targets: Array[int]) -> void:
	_targets = targets
	_counts.clear()
	_sent.clear()
	_acked.clear()
	_peak_outstanding.clear()
	_credit_updated.clear()
	_credits_sent.clear()
	_credits_received.clear()
	_credit_events.clear()
	_paused_proof.clear()
	_last_packet.clear()
	_reader_resumed = false
	_fast_pair_announced = false
	for seat: int in targets:
		_counts[seat] = [0, 0, 0]
		_sent[seat] = 0
		_acked[seat] = 0
		_credits_sent[seat] = 0
		_credits_received[seat] = 0
		_peak_outstanding[seat] = 0
		_credit_updated[seat] = Time.get_ticks_msec()


func _record_credit(direction: String, seat: int, count: int, error: int = OK) -> void:
	if _credit_events.size() < 32:
		_credit_events.append(
			{
				"direction": direction,
				"seat": seat,
				"count": count,
				"tick_ms": Time.get_ticks_msec(),
				"error": error
			}
		)


func _credit_bytes(phase: int, sender: int, target: int, count: int) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(20)
	data.encode_u32(0, 0xFFFFFFFF)
	data.encode_u32(4, phase)
	data.encode_u32(8, sender)
	data.encode_u32(12, target)
	data.encode_u32(16, count)
	return data


func _ack_marker(phase: int, seat: int, count: int) -> String:
	return "consumed-%d-%d-%d" % [phase, seat, count]


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


func _queue_interruption() -> bool:
	_connections.clear()
	var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
	for id: int in peer.get_peers():
		_connections[id] = peer.get_peer(id)["connection"]
	_phase = 2
	_reset_transfer_counts(_others())
	_delay_reader = false
	_reader_paused = false
	_interruption = {"queued_before_close": 0, "consumed_by_sender_and_mode": {}}
	if _seat != _hub_seat:
		if not _send_partial_snapshot(_retiring_remote()):
			return false
		if not await _wait_until(
			"select retiring snapshot",
			func() -> bool: return _safe.get_available_packet_count() == WINDOW * 3
		):
			return false
		_saved = _selected_metadata()
		var selected_peer: int = _saved["peer"]
		if _seat_for_id(selected_peer) != _retiring_remote():
			_fail("retiring snapshot was not selected")
			return false
	if not await _barrier("retiring-snapshot-selected"):
		return false
	for seat: int in _surviving_seats():
		if not _send_partial_snapshot(seat):
			return false
	if not await _wait_until(
		"queued partial snapshots on all links",
		func() -> bool: return _safe.get_available_packet_count() == WINDOW * 3 * 2
	):
		return false
	if _seat == _hub_seat:
		_saved = _selected_metadata()
	elif _saved != _selected_metadata():
		_fail("queued arrivals changed the selected retiring snapshot")
		return false
	_interruption["selected_before_close"] = _saved.duplicate()
	_interruption["queued_before_close"] = _safe.get_available_packet_count()
	return await _barrier("partial-snapshots-queued")


func _selected_metadata() -> Dictionary:
	return {
		"peer": _safe.get_packet_peer(),
		"mode": _safe.get_packet_mode(),
		"channel": _safe.get_packet_channel()
	}


func _send_partial_snapshot(seat: int) -> bool:
	_safe.set_target_peer(MeshScript.uuid_to_peer_id(ROSTER[seat]))
	for sequence: int in WINDOW:
		for mode: int in 3:
			_safe.transfer_mode = mode as MultiplayerPeer.TransferMode
			if _safe.put_packet(_sample_bytes(2, _seat, seat, mode, sequence)) != OK:
				_fail("partial snapshot send failed")
				return false
	_sent[seat] = WINDOW
	_peak_outstanding[seat] = WINDOW
	_credit_updated[seat] = Time.get_ticks_msec()
	return true


func _retire_one_link() -> bool:
	if _seat == _closing_seat:
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		var channels: Array = (
			peer.get_peer(MeshScript.uuid_to_peer_id(ROSTER[_remote_seat]))["channels"]
		)
		var channel: WebRTCDataChannel = channels[_closing_channel]
		channel.close()
	if not await _wait_until(
		"selective retirement notifications",
		func() -> bool:
			_safe.poll()
			return (
				_mesh.get_peer_count() == (2 if _seat == _hub_seat else 1)
				and _rpc_disconnected.size() == (0 if _seat == _hub_seat else 1)
			)
	):
		return false
	if not await _barrier("selective-retirement"):
		return false
	for seat: int in _surviving_seats():
		var id := MeshScript.uuid_to_peer_id(ROSTER[seat])
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if not peer.has_peer(id) or peer.get_peer(id)["connection"] != _connections[id]:
			_fail("selective retirement replaced an unrelated connection")
			return false
	if _seat == _hub_seat and _saved != _selected_metadata():
		_fail("selective retirement changed the surviving selected metadata")
		return false
	_interruption["selected_after_close"] = _selected_metadata()
	_interruption["queued_after_close"] = _safe.get_available_packet_count()
	var expected := WINDOW * 3 * _surviving_seats().size()
	if _safe.get_available_packet_count() != expected:
		_fail("retirement discarded surviving packets or retained retired packets")
		return false
	var consumed: Dictionary = {}
	for seat: int in _surviving_seats():
		consumed[seat] = [0, 0, 0]
	_interruption["consumed_by_sender_and_mode"] = consumed
	for _index: int in expected:
		var seat := _seat_for_id(_safe.get_packet_peer())
		var mode := _safe.get_packet_mode()
		if not consumed.has(seat) or mode < 0 or mode > 2 or _safe.get_packet_channel() != 0:
			_fail("partial snapshot sender or metadata differs after retirement")
			return false
		var counts: Array = consumed[seat]
		var sequence: int = counts[mode]
		var data := _safe.get_packet()
		if (
			_safe.get_packet_error() != OK
			or sequence >= WINDOW
			or data != _sample_bytes(2, seat, _seat, mode, sequence)
		):
			_fail("partial snapshot bytes or sequence differ after retirement")
			return false
		counts[mode] += 1
	for counts: Array in consumed.values():
		if counts != [WINDOW, WINDOW, WINDOW]:
			_fail("partial snapshot lost a transfer mode after retirement")
			return false
	if _safe.get_available_packet_count() != 0:
		_fail("partial snapshot retained extra or retired bytes")
		return false
	_interruption["same_safe_receiver"] = _mesh.get_safe_multiplayer_peer() == _safe
	if not await _barrier("partial-snapshots-consumed"):
		return false
	print("WEBRTC_MULTIPEER_INTERRUPTION " + JSON.stringify(_snapshot()))
	return true


func _snapshot() -> Dictionary:
	var snapshot := super._snapshot()
	snapshot["multi_peer"] = true
	snapshot["credit_transport"] = _credit_transport
	snapshot["credits_sent_by_target"] = _credits_sent
	snapshot["http_credit_hold_proof"] = _http_credit_hold_proof
	snapshot["credits_received_by_target"] = _credits_received
	snapshot["credit_events"] = _credit_events
	snapshot["rpc_independent_pair_proof"] = _rpc_multi_proof
	snapshot["rpc_reader_paused"] = _rpc_multi_reader_paused
	snapshot["rpc_reader_resumed"] = _rpc_multi_reader_resumed
	snapshot["rpc_fast_pair_completed"] = _rpc_multi_fast_pair
	snapshot["rpc_service_poll_count"] = _rpc_multi_poll_count
	snapshot["rpc_service_poll_total_us"] = _rpc_multi_poll_us
	snapshot["rpc_service_poll_max_us"] = _rpc_multi_max_poll_us
	snapshot["retirement_case"] = _retirement_case
	snapshot["closing_seat"] = _closing_seat
	snapshot["remote_seat"] = _remote_seat
	snapshot["closing_channel"] = _closing_channel
	snapshot["hub_seat"] = _hub_seat
	snapshot["delayed_reader_active"] = _delay_reader
	snapshot["same_safe_receiver"] = (
		_mesh != null and _safe != null and _mesh.get_safe_multiplayer_peer() == _safe
	)
	snapshot["directed_targets"] = _targets
	snapshot["received_by_seat_and_mode"] = _counts
	snapshot["sent_by_target"] = _sent
	snapshot["acknowledged_by_target"] = _acked
	snapshot["peak_outstanding_by_target"] = _peak_outstanding
	snapshot["independent_pair_proof"] = _paused_proof
	var waits: Dictionary = {}
	for seat: int in _sent:
		if _sent[seat] - _acked[seat] == WINDOW:
			var updated: int = _credit_updated[seat]
			waits[seat] = Time.get_ticks_msec() - updated
	snapshot["credit_wait_age_ms_by_target"] = waits
	snapshot["slow_receiver"] = _slow_receiver
	snapshot["reader_paused"] = _reader_paused
	snapshot["reader_resumed"] = _reader_resumed
	snapshot["fast_pair_completed_while_reader_paused"] = _fast_pair_announced
	snapshot["interrupted_snapshot"] = _interruption
	snapshot["last_directed_packet"] = _last_packet
	return snapshot


class RoutedClient:
	extends DrillClient
	var routed_relay: Callable

	func send_signal(to: String, generation: String, payload: Variant) -> Error:
		routed_relay.call(to, generation, payload)
		return OK
