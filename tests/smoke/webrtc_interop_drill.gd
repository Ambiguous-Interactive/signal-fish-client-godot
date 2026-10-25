extends Node
# gdlint: disable=max-returns

## Opt-in native/browser gameplay drill driven by check-webrtc-interop.py.

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const MsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SNAPSHOT_CHUNK_BYTES := 1200
const SNAPSHOT_PLAYERS := 1024
const BURST_PACKETS := 256
const STREAM_WINDOW := 32
const REALTIME_PACKETS := 32
const REALTIME_BYTES := 32
const INTERRUPTED_CHUNKS := 12
const CONSUMED_CHUNKS := 8
const PLAYERS: Array[String] = [
	"10000000-0000-0000-0000-000000000001", "10000000-0000-0000-0000-000000000002"
]

var _client: DrillClient
var _mesh: MeshScript
var _inbox: HTTPRequest
var _outbox: HTTPRequest
var _url := ""
var _seat := 0
var _mixed_traffic := false
var _metadata_probe := false
var _metadata_packets: Array[Dictionary] = []
var _pending: Array[Dictionary] = []
var _markers: Dictionary = {}
var _next_poll := 0
var _failed := false
var _finished := false
var _sending := false
var _receiving := false
var _phase := 0
var _stage := "setup"
var _received_modes: Dictionary = {}
var _burst_received: Array[int] = [0]
var _burst_sent := 0
var _peak_queued := 0
var _realtime_sent := 0
var _realtime_received: Array[int] = [0, 0]
var _realtime_last: Array[int] = [-1, -1]
var _realtime_seen: Array[Dictionary] = [{}, {}]
var _stage_started := 0
var _snapshot_received := PackedByteArray()
var _snapshot_total := 0
var _interrupted_sent := 0
var _interrupted_received := 0
var _interrupted_queued := 0


func _ready() -> void:
	_seat = 1 if OS.has_feature("web") else 0
	_start_stage("setup")
	if _seat == 1:
		_url = JavaScriptBridge.eval("window.location.origin")
		_mixed_traffic = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('mixed_traffic') === '1'"
		)
		_metadata_probe = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('metadata_probe') === '1'"
		)
		if _mixed_traffic and _metadata_probe:
			_fail("choose one drill scenario")
			return
	else:
		var args := OS.get_cmdline_user_args()
		if (
			args.size() not in [1, 2]
			or (args.size() == 2 and args[1] not in ["--mixed-traffic", "--metadata-probe"])
		):
			_fail("native seat needs the signaling URL and one optional scenario")
			return
		_url = args[0]
		_mixed_traffic = args.size() == 2 and args[1] == "--mixed-traffic"
		_metadata_probe = args.size() == 2 and args[1] == "--metadata-probe"
	_inbox = HTTPRequest.new()
	_outbox = HTTPRequest.new()
	add_child(_inbox)
	add_child(_outbox)
	_inbox.request_completed.connect(_on_inbox)
	_outbox.request_completed.connect(_on_outbox)
	_client = DrillClient.new()
	_client._player_id = PLAYERS[_seat]
	_client._room_id = "20000000-0000-0000-0000-000000000001"
	_client._connection_state = ClientScript.ConnectionState.CONNECTED
	_client._session_state = ClientScript.SessionState.IN_ROOM_FINALIZED
	_client.relay = func(generation: String, payload: Variant) -> void:
		_pending.append({"generation": generation, "payload": payload})
	_mesh = MeshScript.new()
	_mesh.attach(_client)
	for phase: int in range(1, 2 if _metadata_probe else 8):
		if not await _run_phase(phase):
			_fail("gameplay phase %d failed" % phase)
			return
	_finished = true
	_inbox.cancel_request()
	_outbox.cancel_request()
	_mesh.detach()
	if _mesh.get_peer_count() != 0 or _mesh.get_multiplayer_peer() != null:
		_fail("detach retained the multiplayer peer")
		return
	_mesh.free()
	_mesh = null
	_client.free()
	_client = null
	print("WEBRTC_INTEROP_PASS seat=%d" % _seat)
	get_tree().quit()


func _process(_delta: float) -> void:
	if _failed or _finished or _inbox == null:
		return
	if not _receiving:
		if Time.get_ticks_msec() >= _next_poll:
			_next_poll = Time.get_ticks_msec() + 30
			_receiving = true
			if _inbox.request(_url + "/signal/%d" % _seat) != OK:
				_fail("signaling receive request failed")
	if not _pending.is_empty():
		if not _sending:
			var message: Dictionary = _pending.pop_front()
			_sending = true
			if (
				_outbox.request(
					_url + "/signal/%d" % (1 - _seat),
					PackedStringArray(["Content-Type: application/json"]),
					HTTPClient.METHOD_POST,
					JSON.stringify(message)
				)
				!= OK
			):
				_fail("signaling send request failed")
	if _mesh != null:
		_mesh.poll()
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if peer != null:
			peer.poll()


func _on_inbox(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_receiving = false
	if _finished:
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("signaling receive failed")
		return
	var messages: Array = JSON.parse_string(body.get_string_from_utf8())
	for message: Dictionary in messages:
		if message.has("marker"):
			_markers[message["marker"]] = true
		else:
			_client.signal_received.emit(
				PLAYERS[1 - _seat], str(message["generation"]), message["payload"]
			)


func _on_outbox(
	result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray
) -> void:
	_sending = false
	if _finished:
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("signaling send failed")


func _run_phase(phase: int) -> bool:
	_phase = phase
	_received_modes.clear()
	_burst_received[0] = 0
	_burst_sent = 0
	_peak_queued = 0
	_realtime_sent = 0
	_realtime_received = [0, 0]
	_realtime_last = [-1, -1]
	_realtime_seen = [{}, {}]
	_snapshot_received.clear()
	_snapshot_total = 0
	_interrupted_sent = 0
	_interrupted_received = 0
	_interrupted_queued = 0
	var generation := "40000000-0000-0000-0000-%012d" % phase
	var ready_marker := "ready-%d" % phase
	var plan := SessionScript.SessionPlanInfo.new()
	plan.generation = generation
	plan.transport = SessionScript.TransportKind.WEBRTC
	var remote := SessionScript.SessionPeerInfo.new()
	remote.player_id = PLAYERS[1 - _seat]
	remote.initiate = _seat == (phase - 1) % 2
	plan.peers.append(remote)
	if not remote.initiate:
		_mesh._apply_plan(plan)
	_pending.append({"marker": ready_marker})
	if not await _wait_until(
		"remote ready marker", func() -> bool: return _markers.has(ready_marker)
	):
		return false
	if remote.initiate:
		_mesh._apply_plan(plan)
	if not await _wait_until(
		"peer channels open", func() -> bool: return _mesh._count_connected_peers() == 1
	):
		return false
	var multiplayer_peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
	var channels: Array = (
		multiplayer_peer.get_peer(MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat]))["channels"]
	)
	_start_stage("channel contract")
	if channels.size() != 3:
		_fail("expected three gameplay channels")
		return false
	for index: int in 3:
		var channel: WebRTCDataChannel = channels[index]
		if (
			channel.get_id() != index + 1
			or not channel.is_negotiated()
			or channel.get_label() != ["reliable", "ordered", "unreliable"][index]
		):
			_fail("channel %d id, negotiation or label differs" % index)
			return false
	var modes := [
		MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	]
	_start_stage("send gameplay modes")
	for mode: int in modes:
		multiplayer_peer.transfer_mode = mode as MultiplayerPeer.TransferMode
		var payload := "phase=%d seat=%d mode=%d" % [phase, _seat, mode]
		if multiplayer_peer.put_packet(payload.to_utf8_buffer()) != OK:
			_fail("gameplay send failed for mode %d" % mode)
			return false
	if not await _wait_until(
		"receive gameplay modes",
		func() -> bool:
			while multiplayer_peer.get_available_packet_count() > 0:
				var sender: int = multiplayer_peer.get_packet_peer()
				var mode: MultiplayerPeer.TransferMode = multiplayer_peer.get_packet_mode()
				var payload := multiplayer_peer.get_packet().get_string_from_utf8()
				if not modes.has(mode):
					_fail("unexpected gameplay transfer mode")
					return false
				var expected := "phase=%d seat=%d mode=%d" % [phase, 1 - _seat, mode]
				if sender != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat]) or payload != expected:
					_fail("gameplay payload or sender differs")
					return false
				_received_modes[mode] = true
			return _received_modes.size() == 3
	):
		return false
	_pending.append({"marker": "received-%d" % phase})
	if not await _wait_until(
		"remote modes received marker", func() -> bool: return _markers.has("received-%d" % phase)
	):
		return false
	if _metadata_probe:
		return await _probe_packet_metadata(multiplayer_peer, phase)
	if not await _reliable_burst(multiplayer_peer, phase):
		return false
	if not await _wait_until(
		"signaling drained", func() -> bool: return _pending.is_empty() and not _sending
	):
		return false
	if phase <= 6:
		if not await _interrupt_snapshot(multiplayer_peer, phase):
			return false
		_start_stage("close required channel")
		if _seat == (phase - 1) % 2:
			var closed_channel: WebRTCDataChannel = channels[(phase - 1) >> 1]
			closed_channel.close()
		if not await _wait_until(
			"closed channel releases link", func() -> bool: return _mesh.get_peer_count() == 0
		):
			return false
		if multiplayer_peer.get_available_packet_count() != 0:
			_fail("closed channel retained gameplay packets")
			return false
	_snapshot_received.clear()
	_start_stage("relay teardown")
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	_mesh._apply_plan(relay)
	_mesh.poll()
	if _mesh.get_peer_count() != 0 or multiplayer_peer.get_available_packet_count() != 0:
		_fail("relay teardown retained peers or packets")
		return false
	var expected_statuses: Array[bool] = []
	for _completed: int in phase:
		expected_statuses.append_array([true, false])
	if _client.statuses != expected_statuses:
		_fail("transport reports differ from link transitions")
		return false
	_pending.append({"marker": "released-%d" % phase})
	if not await _wait_until(
		"remote link released marker", func() -> bool: return _markers.has("released-%d" % phase)
	):
		return false
	if not await _wait_until(
		"release marker delivered", func() -> bool: return _pending.is_empty() and not _sending
	):
		return false
	print("interop gameplay: seat=%d phase=%d all modes and relay teardown passed" % [_seat, phase])
	return true


func _probe_packet_metadata(peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	var remote_id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	peer.set_target_peer(remote_id)
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	if peer.put_packet(_burst_packet(phase, _seat, 0, 32)) != OK:
		_fail("metadata probe unreliable send failed")
		return false
	if not await _wait_until(
		"metadata probe unreliable queued",
		func() -> bool:
			return (
				peer.get_available_packet_count() == 1
				and peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
			)
	):
		return false
	_pending.append({"marker": "metadata-cached"})
	if not await _wait_until(
		"metadata probe remote cache", func() -> bool: return _markers.has("metadata-cached")
	):
		return false
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	if peer.put_packet(_burst_packet(phase, _seat, 1, 1200)) != OK:
		_fail("metadata probe reliable send failed")
		return false
	var reliable_channel: WebRTCDataChannel = peer.get_peer(remote_id)["channels"][0]
	if not await _wait_until(
		"metadata probe reliable queued",
		func() -> bool:
			return (
				reliable_channel.get_available_packet_count() == 1
				and peer.get_available_packet_count() == 2
			)
	):
		return false
	_pending.append({"marker": "metadata-queued"})
	if not await _wait_until(
		"metadata probe remote queued", func() -> bool: return _markers.has("metadata-queued")
	):
		return false
	_start_stage("metadata probe read queued packets")
	var modes: Array[int] = []
	var mismatch := ""
	for index: int in 2:
		var sender := peer.get_packet_peer()
		var mode := peer.get_packet_mode()
		var channel := peer.get_packet_channel()
		var packet := peer.get_packet()
		var reliable_bytes := _burst_packet(phase, 1 - _seat, 1, 1200)
		var unreliable_bytes := _burst_packet(phase, 1 - _seat, 0, 32)
		_metadata_packets.append(
			{
				"sender": sender,
				"mode": mode,
				"channel": channel,
				"bytes": packet.size(),
				"matches_reliable": packet == reliable_bytes,
				"matches_unreliable": packet == unreliable_bytes
			}
		)
		print(
			(
				(
					"interop metadata probe: seat=%d packet=%d mode=%d bytes=%d "
					+ "matches_reliable=%s matches_unreliable=%s"
				)
				% [
					_seat,
					index,
					mode,
					packet.size(),
					packet == reliable_bytes,
					packet == unreliable_bytes
				]
			)
		)
		if (
			sender != remote_id
			or channel != 0
			or modes.has(mode)
			or not (
				(mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE and packet == reliable_bytes)
				or (mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE and packet == unreliable_bytes)
			)
		):
			if mismatch.is_empty():
				mismatch = "queued packet transfer mode differs from payload"
		modes.append(mode)
	if peer.get_available_packet_count() != 0 and mismatch.is_empty():
		mismatch = "metadata probe retained packets"
	_pending.append({"marker": "metadata-read"})
	if not await _wait_until(
		"metadata probe remote read", func() -> bool: return _markers.has("metadata-read")
	):
		return false
	if not await _wait_until(
		"metadata probe marker delivered",
		func() -> bool: return _pending.is_empty() and not _sending
	):
		return false
	if not mismatch.is_empty():
		_fail(mismatch)
		return false
	return true


func _reliable_burst(peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	var remote_id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	peer.set_target_peer(remote_id)
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	var sizes: Array[int] = [1, 16, 255, 1200]
	var snapshot: Dictionary = MsgpackScript.encode(_snapshot_value(phase, _seat))
	var remote_snapshot: Dictionary = MsgpackScript.encode(_snapshot_value(phase, 1 - _seat))
	if not snapshot["ok"] or not remote_snapshot["ok"]:
		_fail("snapshot encode failed")
		return false
	var outgoing: PackedByteArray = snapshot["bytes"]
	var expected_snapshot: PackedByteArray = remote_snapshot["bytes"]
	_snapshot_total = expected_snapshot.size()
	var total := BURST_PACKETS + ceili(float(outgoing.size()) / SNAPSHOT_CHUNK_BYTES)
	if not await _wait_until(
		"stream reliable gameplay",
		func() -> bool:
			_peak_queued = maxi(_peak_queued, peer.get_available_packet_count())
			while peer.get_available_packet_count() > 0:
				var sender := peer.get_packet_peer()
				var mode := peer.get_packet_mode()
				var channel := peer.get_packet_channel()
				var packet := peer.get_packet()
				if mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE:
					if not _receive_realtime(packet, sender, mode, channel, phase):
						return false
					continue
				var sequence := _burst_received[0]
				var expected := _stream_packet(phase, 1 - _seat, sequence, sizes, expected_snapshot)
				if (
					sequence >= total
					or packet != expected
					or sender != remote_id
					or mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
					or channel != 0
				):
					_fail(
						(
							(
								"reliable gameplay mismatch: sequence=%d sender=%d mode=%d "
								+ "channel=%d bytes=%d"
							)
							% [sequence, sender, mode, channel, packet.size()]
						)
					)
					return false
				if sequence >= BURST_PACKETS:
					_snapshot_received.append_array(packet)
				_burst_received[0] += 1
				if _burst_received[0] % STREAM_WINDOW == 0:
					_pending.append({"marker": "stream-%d-%d" % [phase, _burst_received[0]]})
			peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
			for _batch: int in 4:
				if _burst_sent == total:
					break
				if _burst_sent >= STREAM_WINDOW:
					var previous_window := _burst_sent - (_burst_sent % STREAM_WINDOW)
					if not _markers.has("stream-%d-%d" % [phase, previous_window]):
						break
				var packet := _stream_packet(phase, _seat, _burst_sent, sizes, outgoing)
				if peer.put_packet(packet) != OK:
					_fail("directed reliable gameplay send failed")
					return false
				_burst_sent += 1
			for _sample: int in 4:
				if (
					not _mixed_traffic
					or _burst_sent <= BURST_PACKETS
					or _realtime_sent == REALTIME_PACKETS
				):
					break
				for mode: int in [
					MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
					MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
				]:
					peer.transfer_mode = mode as MultiplayerPeer.TransferMode
					if peer.put_packet(_realtime_packet(phase, _seat, mode, _realtime_sent)) != OK:
						_fail("realtime gameplay send failed for mode %d" % mode)
						return false
				_realtime_sent += 1
			return (
				_burst_received[0] == total
				and _burst_sent == total
				and (
					not _mixed_traffic
					or (
						_realtime_sent == REALTIME_PACKETS
						and _realtime_received[0] > 0
						and _realtime_received[1] > 0
					)
				)
			)
	):
		return false
	_start_stage("decode reassembled snapshot")
	var decoded: Dictionary = MsgpackScript.decode(_snapshot_received)
	if (
		_snapshot_received != expected_snapshot
		or not decoded["ok"]
		or decoded["value"] != _snapshot_value(phase, 1 - _seat)
	):
		_fail("reassembled snapshot bytes or values differ")
		return false
	_pending.append({"marker": "burst-%d" % phase})
	if not await _wait_until(
		"remote burst received marker",
		func() -> bool: return _drain_realtime(peer, phase) and _markers.has("burst-%d" % phase)
	):
		return false
	peer.set_target_peer(0)
	if _mixed_traffic:
		print(
			(
				"interop realtime stream: seat=%d phase=%d sent_per_mode=%d received=%s last_sequence=%s"
				% [_seat, phase, _realtime_sent, _realtime_received, _realtime_last]
			)
		)
	print(
		(
			(
				"interop reliable stream: seat=%d phase=%d packets=%d max_size=%d "
				+ "peak_queued=%d snapshot_bytes=%d snapshot_players=%d"
			)
			% [_seat, phase, total, 1200, _peak_queued, outgoing.size(), SNAPSHOT_PLAYERS]
		)
	)
	return true


func _interrupt_snapshot(peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	_start_stage("send interrupted snapshot")
	var remote_id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	var outgoing: Dictionary = MsgpackScript.encode(_snapshot_value(phase + 100, _seat))
	var incoming: Dictionary = MsgpackScript.encode(_snapshot_value(phase + 100, 1 - _seat))
	if not outgoing["ok"] or not incoming["ok"]:
		_fail("interrupted snapshot encode failed")
		return false
	var bytes: PackedByteArray = outgoing["bytes"]
	var expected: PackedByteArray = incoming["bytes"]
	_snapshot_received.clear()
	_snapshot_total = expected.size()
	peer.set_target_peer(remote_id)
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	for index: int in INTERRUPTED_CHUNKS:
		var offset := index * SNAPSHOT_CHUNK_BYTES
		if peer.put_packet(bytes.slice(offset, offset + SNAPSHOT_CHUNK_BYTES)) != OK:
			_fail("interrupted snapshot send failed")
			return false
		_interrupted_sent += 1
	var channels: Array = peer.get_peer(remote_id)["channels"]
	var reliable_channel: WebRTCDataChannel = channels[0]
	if not await _wait_until(
		"interrupted snapshot queued",
		func() -> bool:
			if not _drain_realtime(peer, phase):
				return false
			_interrupted_queued = reliable_channel.get_available_packet_count()
			return (
				_interrupted_queued == INTERRUPTED_CHUNKS
				and peer.get_available_packet_count() >= INTERRUPTED_CHUNKS
			)
	):
		return false
	_start_stage("receive partial snapshot")
	for index: int in CONSUMED_CHUNKS:
		var offset := index * SNAPSHOT_CHUNK_BYTES
		var sender := peer.get_packet_peer()
		var mode := peer.get_packet_mode()
		var channel := peer.get_packet_channel()
		var packet := peer.get_packet()
		_interrupted_queued = reliable_channel.get_available_packet_count()
		if (
			packet != expected.slice(offset, offset + SNAPSHOT_CHUNK_BYTES)
			or sender != remote_id
			or mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE
			or channel != 0
		):
			_fail(
				(
					(
						"interrupted snapshot bytes or metadata differ: chunk=%d "
						+ "sender=%d mode=%d channel=%d bytes=%d prefix=%s"
					)
					% [index, sender, mode, channel, packet.size(), packet.slice(0, 8).hex_encode()]
				)
			)
			return false
		_snapshot_received.append_array(packet)
		_interrupted_received += 1
	_interrupted_queued = reliable_channel.get_available_packet_count()
	if _interrupted_queued != INTERRUPTED_CHUNKS - CONSUMED_CHUNKS:
		_fail("interrupted snapshot queued count differs")
		return false
	_pending.append({"marker": "partial-%d" % phase})
	if not await _wait_until(
		"remote partial snapshot marker", func() -> bool: return _markers.has("partial-%d" % phase)
	):
		return false
	print(
		(
			"interop interrupted snapshot: seat=%d phase=%d received_bytes=%d queued=%d total_bytes=%d"
			% [_seat, phase, _snapshot_received.size(), _interrupted_queued, _snapshot_total]
		)
	)
	return true


func _drain_realtime(peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	while peer.get_available_packet_count() > 0:
		var mode := peer.get_packet_mode()
		if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			break
		var sender := peer.get_packet_peer()
		var channel := peer.get_packet_channel()
		if not _receive_realtime(peer.get_packet(), sender, mode, channel, phase):
			return false
	return true


func _receive_realtime(
	packet: PackedByteArray, sender: int, mode: int, channel: int, phase: int
) -> bool:
	if (
		(
			mode
			not in [
				MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
				MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
			]
		)
		or sender != MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
		or channel != 0
		or packet.size() != REALTIME_BYTES
	):
		_fail(
			(
				"realtime gameplay metadata differs: sender=%d mode=%d channel=%d bytes=%d"
				% [sender, mode, channel, packet.size()]
			)
		)
		return false
	var sequence := packet.decode_u32(0)
	var index := 1 if mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED else 0
	if (
		sequence >= REALTIME_PACKETS
		or packet != _realtime_packet(phase, 1 - _seat, mode, sequence)
		or _realtime_seen[index].has(sequence)
		or (index == 1 and sequence <= _realtime_last[index])
	):
		var other_mode := (
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
			if index == 0
			else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		)
		var matches_other := packet == _realtime_packet(phase, 1 - _seat, other_mode, sequence)
		_fail(
			(
				(
					"realtime gameplay mismatch: mode=%d sequence=%d previous=%d "
					+ "duplicate=%s matches_other_mode=%s"
				)
				% [
					mode,
					sequence,
					_realtime_last[index],
					_realtime_seen[index].has(sequence),
					matches_other
				]
			)
		)
		return false
	_realtime_seen[index][sequence] = true
	_realtime_received[index] += 1
	_realtime_last[index] = sequence
	return true


func _realtime_packet(phase: int, seat: int, mode: int, sequence: int) -> PackedByteArray:
	var packet := _burst_packet(phase, seat, sequence + mode * REALTIME_PACKETS, REALTIME_BYTES)
	packet.encode_u32(0, sequence)
	return packet


func _snapshot_value(phase: int, seat: int) -> Dictionary:
	var players: Array[Dictionary] = []
	for index: int in SNAPSHOT_PLAYERS:
		players.append(
			{
				"id": 256 + index,
				"x": phase * 1.25 + index,
				"y": seat * 2.5 - index,
				"health": 1000 - index,
				"animation": "running"
			}
		)
	return {"phase": phase, "seat": seat, "players": players}


func _stream_packet(
	phase: int, seat: int, sequence: int, sizes: Array[int], snapshot: PackedByteArray
) -> PackedByteArray:
	if sequence < BURST_PACKETS:
		return _burst_packet(phase, seat, sequence, sizes[sequence % sizes.size()])
	var offset := (sequence - BURST_PACKETS) * SNAPSHOT_CHUNK_BYTES
	return snapshot.slice(offset, mini(offset + SNAPSHOT_CHUNK_BYTES, snapshot.size()))


func _burst_packet(phase: int, seat: int, sequence: int, size: int) -> PackedByteArray:
	var packet := PackedByteArray()
	packet.resize(size)
	for index: int in size:
		packet[index] = (phase * 61 + seat * 37 + sequence * 17 + index) & 0xff
	return packet


func _start_stage(stage: String) -> void:
	_stage = stage
	_stage_started = Time.get_ticks_msec()
	print("interop stage: seat=%d phase=%d stage=%s" % [_seat, _phase, stage])


func _wait_until(stage: String, condition: Callable) -> bool:
	_start_stage(stage)
	var deadline := _stage_started + 15000
	while not _failed and Time.get_ticks_msec() < deadline:
		if condition.call():
			print(
				(
					"interop ready: seat=%d phase=%d stage=%s elapsed_ms=%d"
					% [_seat, _phase, stage, Time.get_ticks_msec() - _stage_started]
				)
			)
			return true
		await get_tree().process_frame
	_fail("wait timed out")
	return false


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	var snapshot := {
		"seat": _seat,
		"phase": _phase,
		"stage": _stage,
		"stage_elapsed_ms": Time.get_ticks_msec() - _stage_started,
		"reason": reason,
		"markers": _markers.keys(),
		"received_modes": _received_modes.keys(),
		"burst_received": _burst_received[0],
		"burst_sent": _burst_sent,
		"peak_queued": _peak_queued,
		"mixed_traffic": _mixed_traffic,
		"metadata_probe": _metadata_probe,
		"metadata_packets": _metadata_packets,
		"realtime_sent_per_mode": _realtime_sent,
		"realtime_received": _realtime_received,
		"realtime_last_sequence": _realtime_last,
		"snapshot_received_bytes": _snapshot_received.size(),
		"snapshot_expected_bytes": _snapshot_total,
		"interrupted_sent": _interrupted_sent,
		"interrupted_received": _interrupted_received,
		"interrupted_queued": _interrupted_queued,
		"pending_signals": _pending.size(),
		"sending": _sending,
		"receiving": _receiving,
		"transport_reports": _client.statuses if _client != null else [],
		"queued_packets": 0,
		"peers": []
	}
	if _mesh != null:
		var multiplayer_peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if multiplayer_peer != null:
			snapshot["queued_packets"] = multiplayer_peer.get_available_packet_count()
		for uuid: String in _mesh._peers:
			var entry: Object = _mesh._peers[uuid]
			var connection: WebRTCPeerConnection = entry.get("connection")
			var peer_id: int = entry.get("peer_id")
			var channel_states: Array[Dictionary] = []
			var peer_state := {
				"connection": connection.get_connection_state(),
				"gathering": connection.get_gathering_state(),
				"signaling": connection.get_signaling_state(),
				"channels": channel_states
			}
			if multiplayer_peer != null and multiplayer_peer.has_peer(peer_id):
				var peer: Dictionary = multiplayer_peer.get_peer(peer_id)
				for channel: WebRTCDataChannel in peer["channels"]:
					channel_states.append(
						{
							"id": channel.get_id(),
							"state": channel.get_ready_state(),
							"negotiated": channel.is_negotiated(),
							"label": channel.get_label()
						}
					)
			var peer_states: Array = snapshot["peers"]
			peer_states.append(peer_state)
	print("WEBRTC_INTEROP_FAIL " + JSON.stringify(snapshot))
	if _inbox != null:
		_inbox.cancel_request()
	if _outbox != null:
		_outbox.cancel_request()
	if _mesh != null:
		_mesh.detach()
	get_tree().quit(1)


class DrillClient:
	extends ClientScript
	var relay: Callable
	var statuses: Array[bool] = []

	func send_signal(_to: String, generation: String, payload: Variant) -> Error:
		relay.call(generation, payload)
		return OK

	func send_transport_status(_kind: int, up: bool) -> Error:
		statuses.append(up)
		return OK
