extends Node
# gdlint: disable=max-returns

## Opt-in native/browser gameplay drill driven by check-webrtc-interop.py.

const LifetimeProbeScript = preload("res://tests/smoke/webrtc_lifetime_probe.gd")
const RpcProbeScript = preload("res://tests/smoke/webrtc_rpc_probe.gd")
const HttpScript = preload("res://tests/smoke/webrtc_http_request.gd")
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

var _signal_players: Array[String] = PLAYERS
var _client: DrillClient
var _mesh: MeshScript
var _inbox: HttpScript
var _outbox: HttpScript
var _outboxes: Dictionary = {}
var _outgoing: Dictionary = {}
var _url := ""
var _seat := 0
var _mixed_traffic := false
var _rpc_recovery := false
var _rpc_plan_recovery := false
var _rpc_retirement := ""
var _rpc_api: SceneMultiplayer
var _rpc_polling := false
var _rpc_connected: Array[int] = []
var _rpc_disconnected: Array[int] = []
var _rpc_polls := 0
var _rpc_selected := false
var _rpc_traffic := false
var _rpc_probe: RpcProbeScript
var _metadata_probe := false
var _channel_receive := false
var _safe_receive := false
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
var _stream_waiting_ack := ""
var _max_stage_frame_gap_msec := 0
var _next_progress := 0
var _last_process := 0
var _send_started := 0
var _receive_started := 0
var _signal_sent := 0
var _signal_received := 0
var _last_marker_sent := ""
var _last_marker_received := ""
var _sending_marker := ""
var _sending_to := 0
var _marker_posts: Array[Dictionary] = []


func _ready() -> void:
	_seat = 1 if OS.has_feature("web") else 0
	_start_stage("setup")
	if _seat == 1:
		_url = JavaScriptBridge.eval("window.location.origin")
		_rpc_plan_recovery = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('rpc_plan_recovery') === '1'"
		)
		_rpc_recovery = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('rpc_recovery') === '1'"
		)
		_rpc_traffic = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('rpc_traffic') === '1'"
		)
		_mixed_traffic = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('mixed_traffic') === '1'"
		)
		_metadata_probe = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('metadata_probe') === '1'"
		)
		_safe_receive = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('safe_receive') === '1'"
		)
		_channel_receive = JavaScriptBridge.eval(
			"new URLSearchParams(window.location.search).get('channel_receive') === '1'"
		)
		if _mixed_traffic and _metadata_probe:
			_fail("choose one drill scenario")
			return
	else:
		var args := OS.get_cmdline_user_args()
		if args.is_empty():
			_fail("native seat needs the signaling URL")
			return
		_url = args[0]
		for option: String in args.slice(1):
			match option:
				"--rpc-plan-recovery":
					_rpc_plan_recovery = true
				"--rpc-recovery":
					_rpc_recovery = true
				"--rpc-traffic":
					_rpc_traffic = true
				"--mixed-traffic":
					_mixed_traffic = true
				"--metadata-probe":
					_metadata_probe = true
				"--safe-receive":
					_safe_receive = true
				"--channel-receive":
					_channel_receive = true
				_:
					_fail("unknown native drill option")
					return
		if _mixed_traffic and _metadata_probe:
			_fail("choose one drill scenario")
			return
	_rpc_recovery = _rpc_recovery or _rpc_plan_recovery
	if not _check_lifetime_controls():
		return
	_setup_http()
	_client = DrillClient.new()
	_client._player_id = PLAYERS[_seat]
	_client._room_id = "20000000-0000-0000-0000-000000000001"
	_client._connection_state = ClientScript.ConnectionState.CONNECTED
	_client._session_state = ClientScript.SessionState.IN_ROOM_FINALIZED
	_client.relay = func(generation: String, payload: Variant) -> void:
		_pending.append({"generation": generation, "payload": payload})
	_mesh = MeshScript.new()
	_mesh.attach(_client)
	if (
		(_safe_receive or _rpc_traffic or _rpc_recovery)
		and not _mesh.has_method("get_safe_multiplayer_peer")
	):
		_fail("scenario needs the metadata-safe peer addon")
		return
	for phase: int in range(1, 2 if _metadata_probe else 8):
		if not await _run_phase(phase):
			_fail("gameplay phase %d failed" % phase)
			return
	_release_rpc_recovery()
	_finished = true
	_inbox.cancel_request()
	_cancel_outboxes()
	_mesh.detach()
	if _mesh.get_peer_count() != 0 or _mesh.get_multiplayer_peer() != null:
		_fail("detach retained the multiplayer peer")
		return
	_mesh.free()
	_mesh = null
	_client.free()
	_client = null
	print(
		(
			"WEBRTC_HTTP_EVIDENCE "
			+ JSON.stringify({"http_inbox": _inbox.evidence(), "http_outbox": _outbox_evidence()})
		)
	)
	print("WEBRTC_INTEROP_PASS seat=%d" % _seat)
	# The driver owns Web teardown; early quit can race audio startup (#430).
	if not OS.has_feature("web"):
		get_tree().quit()


func _setup_http(use_fetch := true) -> void:
	_inbox = HttpScript.new()
	if OS.has_feature("web"):
		use_fetch = (
			JavaScriptBridge.eval(
				"new URLSearchParams(window.location.search).get('http_fetch') !== '0'"
			)
			and use_fetch
		)
	_inbox.use_fetch = use_fetch
	add_child(_inbox)
	_inbox.request_completed.connect(_on_inbox)
	for destination: int in _signal_players.size():
		if destination == _seat:
			continue
		var request := HttpScript.new()
		request.use_fetch = use_fetch
		add_child(request)
		request.request_completed.connect(_on_outbox.bind(destination))
		_outboxes[destination] = request
		if _outbox == null:
			_outbox = request


func _check_lifetime_controls() -> bool:
	var controls := LifetimeProbeScript.run()
	print("WEBRTC_LIFETIME_CONTROLS " + JSON.stringify(controls))
	if not controls["valid"]:
		_fail("channel lifetime positive control failed")
		return false
	return true


func _process(_delta: float) -> void:
	if _failed or _finished or _inbox == null:
		return
	var now := Time.get_ticks_msec()
	if _last_process > 0:
		_max_stage_frame_gap_msec = maxi(_max_stage_frame_gap_msec, now - _last_process)
	_last_process = now
	if now >= _next_progress:
		_next_progress = now + 1000
		print("WEBRTC_INTEROP_PROGRESS " + JSON.stringify(_snapshot()))
	if not _receiving:
		if Time.get_ticks_msec() >= _next_poll:
			_next_poll = Time.get_ticks_msec() + 30
			_receiving = true
			_receive_started = now
			if _inbox.request(_url + "/signal/%d" % _seat) != OK:
				_fail("signaling receive request failed")
	var index := 0
	while index < _pending.size():
		var message: Dictionary = _pending[index]
		var destination: int = message.get("to", 1 - _seat)
		if _outgoing.has(destination):
			index += 1
			continue
		_pending.remove_at(index)
		_outgoing[destination] = {"started": now, "marker": message.get("marker", "")}
		_update_send_state()
		if message.has("marker"):
			_last_marker_sent = message["marker"]
		var request: HttpScript = _outboxes[destination]
		if (
			request.request(
				_url + "/signal/%d" % destination,
				PackedStringArray(["Content-Type: application/json"]),
				HTTPClient.METHOD_POST,
				JSON.stringify(message)
			)
			!= OK
		):
			_fail("signaling send request failed")
			return
	if _mesh != null:
		_mesh.poll()
		var peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if peer != null:
			peer.poll()
	if _rpc_api != null and _rpc_polling:
		_rpc_polls += 1
		if _rpc_api.poll() != OK:
			_fail("RPC API poll failed")
		elif not _rpc_probe.failure.is_empty():
			_fail(_rpc_probe.failure)


func _on_inbox(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _failed or _finished:
		return
	_receiving = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("signaling receive failed")
		return
	var messages: Array = JSON.parse_string(body.get_string_from_utf8())
	_signal_received += messages.size()
	for message: Dictionary in messages:
		if message.has("marker"):
			_last_marker_received = message["marker"]
			_markers[message["marker"]] = true
		else:
			var sender_seat: int = message.get("from", 1 - _seat)
			_client.signal_received.emit(
				_signal_players[sender_seat], str(message["generation"]), message["payload"]
			)


func _on_outbox(
	result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, destination: int
) -> void:
	if _failed or _finished:
		return
	var sent: Dictionary = _outgoing[destination]
	_outgoing.erase(destination)
	_update_send_state()
	if not str(sent["marker"]).is_empty():
		var now := Time.get_ticks_msec()
		var started: int = sent["started"]
		_marker_posts.append(
			{
				"marker": sent["marker"],
				"to": destination,
				"elapsed_ms": now - started,
				"completed_tick_ms": now,
				"result": result,
				"http_code": code
			}
		)
		if _marker_posts.size() > 16:
			_marker_posts.pop_front()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("signaling send failed")
	else:
		_signal_sent += 1


func _update_send_state() -> void:
	_sending = not _outgoing.is_empty()
	_send_started = 9223372036854775807
	for destination: int in _outgoing:
		var sent: Dictionary = _outgoing[destination]
		var started: int = sent["started"]
		if started < _send_started:
			_send_started = sent["started"]
			_sending_marker = sent["marker"]
			_sending_to = destination


func _cancel_outboxes() -> void:
	for request: HttpScript in _outboxes.values():
		request.cancel_request()


func _outbox_evidence(include_history := true) -> Dictionary:
	var aggregate := {
		"active": {},
		"completed": 0,
		"recent": [],
		"marker_requests": [],
		"history_included": include_history,
		"marker_count": 0,
		"marker_overflow": 0,
		"by_destination": {}
	}
	var destinations: Dictionary = aggregate["by_destination"]
	var recent: Array = aggregate["recent"]
	var markers: Array = aggregate["marker_requests"]
	for destination: int in _outboxes:
		var request: HttpScript = _outboxes[destination]
		var evidence := request.evidence(include_history)
		destinations[str(destination)] = evidence
		aggregate["completed"] += evidence["completed"]
		aggregate["marker_count"] += evidence["marker_count"]
		aggregate["marker_overflow"] += evidence["marker_overflow"]
		var request_recent: Array = evidence["recent"]
		var request_markers: Array = evidence["marker_requests"]
		recent.append_array(request_recent)
		markers.append_array(request_markers)
		if _outgoing.has(destination) and destination == _sending_to:
			aggregate["active"] = evidence["active"]
	return aggregate


func _release_rpc_recovery() -> void:
	if _rpc_api == null:
		return
	_rpc_polling = false
	get_tree().set_multiplayer(null, _rpc_probe.get_path())
	_rpc_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_rpc_api = null
	_rpc_probe.free()
	_rpc_probe = null
	get_tree().multiplayer_poll = true


func _run_phase(phase: int) -> bool:
	_phase = phase
	_rpc_retirement = ""
	_rpc_selected = false
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
	_stream_waiting_ack = ""
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
	print("WEBRTC_CHANNEL_CONTRACT " + JSON.stringify(_snapshot()))
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
			while _packet_count(multiplayer_peer) > 0:
				var packet := _read_packet(multiplayer_peer)
				if packet == null:
					return false
				var sender := packet.peer_id
				var mode := packet.transfer_mode
				var payload := packet.data.get_string_from_utf8()
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
	if _rpc_recovery:
		return await _rpc_recovery_gameplay(multiplayer_peer, channels, phase)
	if _rpc_traffic:
		if not await _rpc_gameplay(phase):
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
		if _packet_count(multiplayer_peer) != 0:
			_fail("closed channel retained gameplay packets")
			return false
	return await _finish_phase(multiplayer_peer, phase)


func _finish_phase(multiplayer_peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	_snapshot_received.clear()
	_start_stage("relay teardown")
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	_mesh._apply_plan(relay)
	_mesh.poll()
	if _mesh.get_peer_count() != 0 or _packet_count(multiplayer_peer) != 0:
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


func _rpc_recovery_gameplay(peer: WebRTCMultiplayerPeer, channels: Array, phase: int) -> bool:
	if _rpc_api == null:
		get_tree().multiplayer_poll = false
		_rpc_probe = RpcProbeScript.new()
		_rpc_probe.name = "RpcProbe"
		add_child(_rpc_probe)
		_rpc_api = SceneMultiplayer.new()
		_rpc_api.peer_connected.connect(func(id: int) -> void: _rpc_connected.append(id))
		_rpc_api.peer_disconnected.connect(func(id: int) -> void: _rpc_disconnected.append(id))
		get_tree().set_multiplayer(_rpc_api, _rpc_probe.get_path())
	_rpc_probe.reset_transfer(phase, _seat, MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat]))
	_rpc_probe.outgoing = MsgpackScript.encode(_snapshot_value(phase, _seat))["bytes"]
	_rpc_probe.expected = MsgpackScript.encode(_snapshot_value(phase, 1 - _seat))["bytes"]
	var receiver: MultiplayerPeer = _mesh.call("get_safe_multiplayer_peer")
	if not _rpc_plan_recovery or phase == 1:
		_rpc_api.multiplayer_peer = receiver
	elif _rpc_api.multiplayer_peer != receiver:
		_fail("plan recovery replaced the assigned RPC peer")
		return false
	_rpc_polling = true
	if not await _wait_until(
		"recovery RPC peer discovery", func() -> bool: return _rpc_api.get_peers().size() == 1
	):
		return false
	if _rpc_connected.size() != phase or _rpc_connected[-1] != _rpc_probe.expected_peer:
		_fail("RPC connection notifications differ")
		return false
	_pending.append({"marker": "rpc-ready-%d" % phase})
	if not await _wait_until(
		"recovery remote RPC ready", func() -> bool: return _markers.has("rpc-ready-%d" % phase)
	):
		return false
	if not await _wait_until(
		"recovery RPC snapshot and positions",
		func() -> bool:
			_rpc_probe.send_batch()
			return _rpc_probe.complete()
	):
		return false
	_pending.append({"marker": "rpc-complete-%d" % phase})
	if not await _wait_until(
		"recovery remote snapshot complete",
		func() -> bool: return _markers.has("rpc-complete-%d" % phase)
	):
		return false
	_rpc_probe.send_partial()
	if not await _wait_until(
		"recovery partial RPC snapshot", func() -> bool: return _rpc_probe.partial_received == 4
	):
		return false
	_rpc_polling = false
	_pending.append({"marker": "rpc-paused-%d" % phase})
	if not await _wait_until(
		"recovery remote RPC paused", func() -> bool: return _markers.has("rpc-paused-%d" % phase)
	):
		return false
	if (
		_rpc_probe.rpc_id(
			_rpc_probe.expected_peer, "retired_chunk", _rpc_probe.outgoing.slice(0, 32)
		)
		!= OK
	):
		_fail("retirement RPC send failed")
		return false
	if not await _wait_until(
		"recovery queued retirement RPC",
		func() -> bool: return receiver.get_available_packet_count() > 0
	):
		return false
	_rpc_selected = true
	if receiver.get_packet_mode() != MultiplayerPeer.TRANSFER_MODE_RELIABLE:
		_fail("retirement RPC mode differs")
		return false
	_pending.append({"marker": "rpc-selected-%d" % phase})
	if not await _wait_until(
		"recovery remote retirement selected",
		func() -> bool: return _markers.has("rpc-selected-%d" % phase)
	):
		return false
	_rpc_retirement = "channel-close"
	if _rpc_plan_recovery:
		match (phase - 1) % 3:
			0:
				_rpc_retirement = "relay-plan"
				var relay := SessionScript.SessionPlanInfo.new()
				relay.transport = SessionScript.TransportKind.RELAY
				_mesh._apply_plan(relay)
			1:
				_rpc_retirement = "empty-generation"
				var replacement := SessionScript.SessionPlanInfo.new()
				replacement.generation = "40000000-0000-0000-0001-%012d" % phase
				replacement.transport = SessionScript.TransportKind.WEBRTC
				_mesh._apply_plan(replacement)
			2:
				_rpc_retirement = "player-left"
				_client.player_left.emit(PLAYERS[1 - _seat])
	elif _seat == (phase - 1) % 2:
		var channel: WebRTCDataChannel = channels[((phase - 1) >> 1) % 3]
		channel.close()
	if not await _wait_until(
		"recovery retirement releases RPC link", func() -> bool: return _mesh.get_peer_count() == 0
	):
		return false
	if receiver.get_available_packet_count() != 0:
		_fail("closed link retained selected RPC bytes")
		return false
	_rpc_polling = true
	if not await _wait_until(
		"recovery RPC disconnect notification",
		func() -> bool: return _rpc_api.get_peers().is_empty() and _rpc_disconnected.size() == phase
	):
		return false
	if _rpc_disconnected[-1] != _rpc_probe.expected_peer or _rpc_probe.retired_received != 0:
		_fail("RPC disconnection or retired delivery differs")
		return false
	var evidence := _rpc_probe.evidence()
	evidence["phase"] = phase
	evidence["retirement"] = _rpc_retirement
	evidence["same_rpc_peer"] = _rpc_api.multiplayer_peer == receiver
	evidence["connected"] = _rpc_connected.size()
	evidence["disconnected"] = _rpc_disconnected.size()
	print("WEBRTC_RPC_RECOVERY_PHASE " + JSON.stringify(evidence))
	_rpc_polling = false
	if not _rpc_plan_recovery:
		_rpc_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	return await _finish_phase(peer, phase)


func _rpc_gameplay(phase: int) -> bool:
	if not _mesh.has_method("get_safe_multiplayer_peer"):
		_fail("RPC scenario needs the metadata-safe peer addon")
		return false
	_rpc_probe = RpcProbeScript.new()
	_rpc_probe.name = "RpcProbe"
	_rpc_probe.phase = phase
	_rpc_probe.seat = _seat
	_rpc_probe.expected_peer = MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
	_rpc_probe.outgoing = MsgpackScript.encode(_snapshot_value(phase, _seat))["bytes"]
	_rpc_probe.expected = MsgpackScript.encode(_snapshot_value(phase, 1 - _seat))["bytes"]
	add_child(_rpc_probe)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, _rpc_probe.get_path())
	api.multiplayer_peer = _mesh.call("get_safe_multiplayer_peer")
	var rpc_complete := await _wait_until(
		"RPC peer discovery", func() -> bool: return api.get_peers().size() == 1
	)
	if rpc_complete:
		_pending.append({"marker": "rpc-ready-%d" % phase})
		rpc_complete = await _wait_until(
			"remote RPC ready", func() -> bool: return _markers.has("rpc-ready-%d" % phase)
		)
	if rpc_complete:
		rpc_complete = await _wait_until(
			"RPC snapshot and positions",
			func() -> bool:
				_rpc_probe.send_batch()
				if not _rpc_probe.failure.is_empty():
					_fail(_rpc_probe.failure)
					return false
				return _rpc_probe.complete()
		)
	if rpc_complete:
		_pending.append({"marker": "rpc-done-%d" % phase})
		rpc_complete = await _wait_until(
			"remote RPC done", func() -> bool: return _markers.has("rpc-done-%d" % phase)
		)
	if not _rpc_probe.failure.is_empty():
		_fail(_rpc_probe.failure)
		rpc_complete = false
	print("interop RPC: seat=%d phase=%d evidence=%s" % [_seat, phase, _rpc_probe.evidence()])
	get_tree().set_multiplayer(null, _rpc_probe.get_path())
	api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_rpc_probe.free()
	_rpc_probe = null
	if not rpc_complete:
		return false
	_pending.append({"marker": "rpc-released-%d" % phase})
	return await _wait_until(
		"remote RPC receiver released",
		func() -> bool: return _markers.has("rpc-released-%d" % phase)
	)


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
				_packet_count(peer) == 1
				and (
					_channel_receive
					or _safe_receive
					or peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
				)
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
			return reliable_channel.get_available_packet_count() == 1 and _packet_count(peer) == 2
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
		var received := _read_packet(peer)
		if received == null:
			return false
		var sender := received.peer_id
		var mode := received.transfer_mode
		var channel := received.channel
		var packet := received.data
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
	if _packet_count(peer) != 0 and mismatch.is_empty():
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
			_peak_queued = maxi(_peak_queued, _packet_count(peer))
			while _packet_count(peer) > 0:
				var received := _read_packet(peer)
				if received == null:
					return false
				var sender := received.peer_id
				var mode := received.transfer_mode
				var channel := received.channel
				var packet := received.data
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
					_stream_waiting_ack = "stream-%d-%d" % [phase, previous_window]
					if not _markers.has(_stream_waiting_ack):
						break
				_stream_waiting_ack = ""
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
			_interrupted_queued = _channel_packet_count(
				reliable_channel, MultiplayerPeer.TRANSFER_MODE_RELIABLE, remote_id
			)
			return (
				_interrupted_queued == INTERRUPTED_CHUNKS
				and _packet_count(peer) >= INTERRUPTED_CHUNKS
			)
	):
		return false
	_start_stage("receive partial snapshot")
	while _interrupted_received < CONSUMED_CHUNKS:
		var offset := _interrupted_received * SNAPSHOT_CHUNK_BYTES
		var received := _read_packet(peer)
		if received == null:
			return false
		if received.transfer_mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			if not _receive_realtime(
				received.data, received.peer_id, received.transfer_mode, received.channel, phase
			):
				return false
			continue
		var sender := received.peer_id
		var mode := received.transfer_mode
		var channel := received.channel
		var packet := received.data
		_interrupted_queued = _channel_packet_count(
			reliable_channel, MultiplayerPeer.TRANSFER_MODE_RELIABLE, remote_id
		)
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
					% [
						_interrupted_received,
						sender,
						mode,
						channel,
						packet.size(),
						packet.slice(0, 8).hex_encode()
					]
				)
			)
			return false
		_snapshot_received.append_array(packet)
		_interrupted_received += 1
	_interrupted_queued = _channel_packet_count(
		reliable_channel, MultiplayerPeer.TRANSFER_MODE_RELIABLE, remote_id
	)
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


func _channel_packet_count(channel: Object, mode: int, peer_id: int) -> int:
	var cached := false
	if _safe_receive:
		var reader: MultiplayerPeer = _mesh.call("get_safe_multiplayer_peer")
		cached = (
			reader != null
			and reader.get_available_packet_count() > 0
			and reader.get_packet_peer() == peer_id
			and reader.get_packet_mode() == mode
			and reader.get_packet_channel() == 0
		)
	var queued: int = channel.call("get_available_packet_count")
	return queued + (1 if cached else 0)


func _drain_realtime(peer: WebRTCMultiplayerPeer, phase: int) -> bool:
	if _channel_receive:
		var remote_id := MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat])
		if not peer.has_peer(remote_id):
			return true
		var channels: Array = peer.get_peer(remote_id)["channels"]
		for index: int in [1, 2]:
			var channel: WebRTCDataChannel = channels[index]
			var mode := (
				MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
				if index == 1
				else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
			)
			while channel.get_available_packet_count() > 0:
				if not _receive_realtime(channel.get_packet(), remote_id, mode, 0, phase):
					return false
		return true
	while _packet_count(peer) > 0:
		var reader: MultiplayerPeer = (
			_mesh.call("get_safe_multiplayer_peer") if _safe_receive else peer
		)
		var mode := reader.get_packet_mode()
		if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			break
		var received := _read_packet(peer)
		if received == null:
			return false
		if not _receive_realtime(
			received.data, received.peer_id, received.transfer_mode, received.channel, phase
		):
			return false
	return true


func _packet_count(peer: WebRTCMultiplayerPeer) -> int:
	if _safe_receive:
		var safe_peer: MultiplayerPeer = _mesh.call("get_safe_multiplayer_peer")
		return safe_peer.get_available_packet_count() if safe_peer != null else 0
	if not _channel_receive:
		return peer.get_available_packet_count()
	var count := 0
	for info: Dictionary in peer.get_peers().values():
		for channel: WebRTCDataChannel in info["channels"]:
			count += channel.get_available_packet_count()
	return count


func _read_packet(peer: WebRTCMultiplayerPeer) -> MeshScript.ReceivedPacket:
	var packet: MeshScript.ReceivedPacket
	if _channel_receive:
		packet = _mesh.receive_packet()
	else:
		var reader: MultiplayerPeer = (
			_mesh.call("get_safe_multiplayer_peer") if _safe_receive else peer
		)
		packet = MeshScript.ReceivedPacket.new()
		packet.peer_id = reader.get_packet_peer()
		packet.transfer_mode = reader.get_packet_mode()
		packet.channel = reader.get_packet_channel()
		packet.data = reader.get_packet()
		packet.error = reader.get_packet_error()
	if packet == null:
		_fail("raw gameplay read returned no packet")
		return null
	if packet.error != OK:
		_fail(
			(
				"raw gameplay read failed: error=%d peer=%d mode=%d channel=%d bytes=%d"
				% [
					packet.error,
					packet.peer_id,
					packet.transfer_mode,
					packet.channel,
					packet.data.size()
				]
			)
		)
		return null
	return packet


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
	_max_stage_frame_gap_msec = 0
	print("interop stage: seat=%d phase=%d stage=%s" % [_seat, _phase, stage])


func _wait_until(stage: String, condition: Callable) -> bool:
	_start_stage(stage)
	var deadline := _stage_started + 15000
	var last_frame := _stage_started
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
		var now := Time.get_ticks_msec()
		_max_stage_frame_gap_msec = maxi(_max_stage_frame_gap_msec, now - last_frame)
		last_frame = now
	_fail("wait timed out")
	return false


func _snapshot() -> Dictionary:
	var now := Time.get_ticks_msec()
	var snapshot := {
		"seat": _seat,
		"phase": _phase,
		"stage": _stage,
		"tick_ms": now,
		"stage_elapsed_ms": Time.get_ticks_msec() - _stage_started,
		"max_stage_frame_gap_ms": _max_stage_frame_gap_msec,
		"stream_waiting_ack": _stream_waiting_ack,
		"markers": _markers.keys(),
		"received_modes": _received_modes.keys(),
		"burst_received": _burst_received[0],
		"burst_sent": _burst_sent,
		"peak_queued": _peak_queued,
		"mixed_traffic": _mixed_traffic,
		"rpc_traffic": _rpc_traffic,
		"rpc_recovery": _rpc_recovery,
		"rpc_plan_recovery": _rpc_plan_recovery,
		"rpc_retirement": _rpc_retirement,
		"rpc_polling": _rpc_polling,
		"rpc_polls": _rpc_polls,
		"rpc_connected": _rpc_connected,
		"rpc_disconnected": _rpc_disconnected,
		"rpc_selected": _rpc_selected,
		"rpc": _rpc_probe.evidence() if _rpc_probe != null else {},
		"metadata_probe": _metadata_probe,
		"channel_receive": _channel_receive,
		"safe_receive": _safe_receive,
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
		"http_inbox": _inbox.evidence(false) if _inbox != null else {},
		"http_outbox": _outbox_evidence(false) if _outbox != null else {},
		"web_http_fetch": OS.has_feature("web") and _inbox != null and _inbox.use_fetch,
		"signal_sent": _signal_sent,
		"signal_received": _signal_received,
		"last_marker_sent": _last_marker_sent,
		"last_marker_received": _last_marker_received,
		"marker_posts": _marker_posts,
		"sending_marker": _sending_marker if _sending else "",
		"sending_to": _sending_to if _sending else -1,
		"send_inflight_ms": now - _send_started if _sending else 0,
		"receive_inflight_ms": now - _receive_started if _receiving else 0,
		"sending": _sending,
		"receiving": _receiving,
		"transport_reports": _client.statuses if _client != null else [],
		"queued_packets": 0,
		"peers": []
	}
	if _mesh != null:
		var multiplayer_peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
		if multiplayer_peer != null:
			snapshot["queued_packets"] = _packet_count(multiplayer_peer)
		for uuid: String in _mesh._peers:
			var entry: Object = _mesh._peers[uuid]
			var connection: WebRTCPeerConnection = entry.get("connection")
			var peer_id: int = entry.get("peer_id")
			var channel_states: Array[Dictionary] = []
			var peer_state := {
				"peer_id": peer_id,
				"connection": connection.get_connection_state(),
				"gathering": connection.get_gathering_state(),
				"signaling": connection.get_signaling_state(),
				"channels": channel_states
			}
			if multiplayer_peer != null and multiplayer_peer.has_peer(peer_id):
				var peer: Dictionary = multiplayer_peer.get_peer(peer_id)
				var channels: Array = peer["channels"]
				for index: int in channels.size():
					var channel: WebRTCDataChannel = channels[index]
					var mode: int = [2, 1, 0][index]
					channel_states.append(
						{
							"id": channel.get_id(),
							"state": channel.get_ready_state(),
							"negotiated": channel.is_negotiated(),
							"label": channel.get_label(),
							"ordered": channel.is_ordered(),
							"max_packet_life_time": channel.get_max_packet_life_time(),
							"max_retransmits": channel.get_max_retransmits(),
							"queued_packets": _channel_packet_count(channel, mode, peer_id),
							"buffered_bytes": channel.get_buffered_amount()
						}
					)
			var peer_states: Array = snapshot["peers"]
			peer_states.append(peer_state)
	return snapshot


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	var snapshot := _snapshot()
	snapshot["http_inbox"] = _inbox.evidence() if _inbox != null else {}
	snapshot["http_outbox"] = _outbox_evidence() if _outbox != null else {}
	snapshot["reason"] = reason
	print("WEBRTC_INTEROP_FAIL " + JSON.stringify(snapshot))
	_release_rpc_recovery()
	if _inbox != null:
		_inbox.cancel_request()
	if _outbox != null:
		_cancel_outboxes()
	if _mesh != null:
		_mesh.detach()
		_mesh.free()
		_mesh = null
	if _client != null:
		_client.free()
		_client = null
	if not OS.has_feature("web"):
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
