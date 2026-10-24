extends Node
# gdlint: disable=max-returns

## Opt-in native/browser gameplay drill driven by check-webrtc-interop.py.

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const PLAYERS: Array[String] = [
	"10000000-0000-0000-0000-000000000001", "10000000-0000-0000-0000-000000000002"
]

var _client: DrillClient
var _mesh: MeshScript
var _inbox: HTTPRequest
var _outbox: HTTPRequest
var _url := ""
var _seat := 0
var _pending: Array[Dictionary] = []
var _markers: Dictionary = {}
var _next_poll := 0
var _failed := false
var _finished := false
var _sending := false
var _receiving := false


func _ready() -> void:
	_seat = 1 if OS.has_feature("web") else 0
	if _seat == 1:
		_url = JavaScriptBridge.eval("window.location.origin")
	else:
		var args := OS.get_cmdline_user_args()
		if args.size() != 1:
			_fail("native seat needs the signaling URL")
			return
		_url = args[0]
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
	for phase: int in [1, 2]:
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
	var generation := "40000000-0000-0000-0000-%012d" % phase
	var ready_marker := "ready-%d" % phase
	var plan := SessionScript.SessionPlanInfo.new()
	plan.generation = generation
	plan.transport = SessionScript.TransportKind.WEBRTC
	var remote := SessionScript.SessionPeerInfo.new()
	remote.player_id = PLAYERS[1 - _seat]
	remote.initiate = _seat == phase - 1
	plan.peers.append(remote)
	if not remote.initiate:
		_mesh._apply_plan(plan)
	_pending.append({"marker": ready_marker})
	if not await _wait_until(func() -> bool: return _markers.has(ready_marker)):
		return false
	if remote.initiate:
		_mesh._apply_plan(plan)
	if not await _wait_until(func() -> bool: return _mesh._count_connected_peers() == 1):
		return false
	var multiplayer_peer: WebRTCMultiplayerPeer = _mesh.get_multiplayer_peer()
	var channels: Array = (
		multiplayer_peer.get_peer(MeshScript.uuid_to_peer_id(PLAYERS[1 - _seat]))["channels"]
	)
	if channels.size() != 3:
		return false
	for index: int in 3:
		var channel: WebRTCDataChannel = channels[index]
		if (
			channel.get_id() != index + 1
			or not channel.is_negotiated()
			or channel.get_label() != ["reliable", "ordered", "unreliable"][index]
		):
			return false
	var modes := [
		MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	]
	for mode: int in modes:
		multiplayer_peer.transfer_mode = mode as MultiplayerPeer.TransferMode
		var payload := "phase=%d seat=%d mode=%d" % [phase, _seat, mode]
		if multiplayer_peer.put_packet(payload.to_utf8_buffer()) != OK:
			return false
	var received: Dictionary = {}
	if not await _wait_until(
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
				received[mode] = true
			return received.size() == 3
	):
		return false
	_pending.append({"marker": "received-%d" % phase})
	if not await _wait_until(func() -> bool: return _markers.has("received-%d" % phase)):
		return false
	if not await _wait_until(func() -> bool: return _pending.is_empty() and not _sending):
		return false
	var relay := SessionScript.SessionPlanInfo.new()
	relay.transport = SessionScript.TransportKind.RELAY
	_mesh._apply_plan(relay)
	if _mesh.get_peer_count() != 0 or multiplayer_peer.get_available_packet_count() != 0:
		return false
	print("interop gameplay: seat=%d phase=%d all modes and relay teardown passed" % [_seat, phase])
	return true


func _wait_until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not _failed and Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return false


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(reason)
	print("WEBRTC_INTEROP_FAIL seat=%d" % _seat)
	get_tree().quit(1)


class DrillClient:
	extends ClientScript
	var relay: Callable

	func send_signal(_to: String, generation: String, payload: Variant) -> Error:
		relay.call(generation, payload)
		return OK

	func send_transport_status(_kind: int, _connected: bool) -> Error:
		return OK
