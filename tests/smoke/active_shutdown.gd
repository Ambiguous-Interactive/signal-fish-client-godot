extends Node
# gdlint: disable=max-returns

const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const TypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const MODES := [2, 1, 0]

var _options: Dictionary
var _seats: Array[Seat] = []
var _failures: Array[String] = []
var _active := false
var _hold := false
var _generation := 0
var _shutdown_requested := false
var _started := 0
var _http := HTTPRequest.new()
var _relay_started := 0


func _ready() -> void:
	_started = Time.get_ticks_msec()
	_options = JSON.parse_string(FileAccess.get_file_as_string("res://shutdown-options.json"))
	add_child(_http)
	_http.timeout = 10
	_run()


func _process(_delta: float) -> void:
	for seat: Seat in _seats:
		var current := seat.mesh.get_multiplayer_peer()
		if current != null:
			current.call("poll")
		if not _active or not seat.trace.is_empty() and seat.trace.back() == "closed":
			continue
		if (
			seat.refused.is_empty()
			and seat.client.get_connection_state() == ClientScript.ConnectionState.CONNECTED
		):
			var rate: int = _options.get("relay_packets_per_second", 0)
			var burst: int = _options["relay_packets_per_frame"]
			if rate > 0:
				var due := int((Time.get_ticks_msec() - _relay_started) * rate / 1000.0)
				seat.offered = due
				burst = mini(16, maxi(0, due - seat.relay_sent))
			else:
				seat.offered += burst
			for _burst: int in burst:
				var credit: int = _options.get("relay_credit_bytes", 0)
				var outstanding := (seat.relay_sent - _other(seat).relay_received) * 4096
				if credit > 0 and outstanding + 4096 > credit:
					seat.credit_blocked_frames += 1
					break
				var payload := {"sequence": seat.relay_sent, "body": "0123456789abcdef".repeat(256)}
				var error := seat.client.send_game_data(payload)
				if error != OK:
					seat.refused.append({"error": error, "tick_ms": Time.get_ticks_msec()})
					_expect(_shutdown_requested, "send refused before shutdown")
					break
				seat.relay_sent += 1
				seat.peak_outstanding_body_bytes = maxi(
					seat.peak_outstanding_body_bytes, outstanding + 4096
				)
		if _hold:
			continue
		var peer := seat.mesh.get_safe_multiplayer_peer()
		if peer == null:
			continue
		while peer.get_available_packet_count() > 0:
			var mode := peer.get_packet_mode()
			var sender := peer.get_packet_peer()
			var channel := peer.get_packet_channel()
			var bytes := peer.get_packet()
			_expect(peer.get_packet_error() == OK, "mesh read status")
			var index := MODES.find(mode)
			if index < 0:
				_expect(false, "mesh transfer mode")
				return
			_expect(channel == 0, "default transfer channel")
			_expect(
				sender == MeshScript.uuid_to_peer_id(_other(seat).client.get_player_id()),
				"mesh sender"
			)
			_expect(
				bytes == _packet(_other(seat), mode, seat.received[index]),
				"exact mesh bytes and sequence"
			)
			seat.received[index] += 1
	if Time.get_ticks_msec() - _started > 60000:
		_finish("watchdog")


func _other(seat: Seat) -> Seat:
	return _seats[1 - _seats.find(seat)]


func _packet(seat: Seat, mode: int, sequence: int) -> PackedByteArray:
	return (
		(
			"mesh:%d:%d:%d:%d:" % [_generation, _seats.find(seat), mode, sequence]
			+ "0123456789abcdef".repeat(256)
		)
		. to_utf8_buffer()
	)


func _setup() -> void:
	for index: int in 2:
		var seat := Seat.new()
		var config := ConfigScript.new()
		config.app_id = "godot-active-shutdown"
		config.protocol_version = 3
		config.supported_transports = PackedStringArray(["relay", "webrtc"])
		config.supported_topologies = PackedStringArray(["host"])
		config.pong_timeout_sec = 2.0
		seat.transport.seat_index = index
		seat.transport.inbound_buffer_bytes = _options.get("inbound_buffer_bytes", 0)
		seat.transport.max_queued_packets = _options.get("max_queued_packets", 0)
		add_child(seat.client)
		add_child(seat.mesh)
		_expect(seat.client.configure(config) == OK, "configure")
		_expect(seat.mesh.attach(seat.client) == OK, "attach")
		seat.client.authenticated.connect(
			func(_app: String, _org: String, _limits: RefCounted) -> void: seat.authenticated = true
		)
		seat.client.lobby_state_changed.connect(
			func(_state: int, _ready_players: PackedStringArray, all_ready: bool) -> void:
				seat.ready = all_ready
		)
		seat.client.session_plan.connect(
			func(plan: SessionScript.SessionPlanInfo) -> void: seat.plan = plan
		)
		seat.client.going_away.connect(
			func(_deadline: int, _retry: int) -> void: seat.trace.append("going_away")
		)
		seat.client.disconnected.connect(
			func(code: int, reason: String) -> void:
				seat.trace.append("closed")
				seat.closes.append(
					{
						"code": code,
						"reason": reason,
						"tick_ms": Time.get_ticks_msec(),
						"sent": seat.relay_sent
					}
				)
		)
		seat.client.connection_failed.connect(
			func(reason: String) -> void:
				seat.failures.append(reason)
				if _options["mode"] == "graceful" or not _shutdown_requested:
					_expect(false, reason)
		)
		seat.client.protocol_error.connect(
			func(reason: String) -> void:
				seat.protocol_errors.append(reason)
				if not _shutdown_requested:
					_expect(false, reason)
		)
		seat.client.server_error.connect(
			func(reason: String, _code: int) -> void: _expect(false, reason)
		)
		seat.client.game_data_received.connect(
			func(sender: String, value: Dictionary) -> void:
				_expect(sender == seat.expected_sender, "relay sender")
				if value.get("sequence") != seat.relay_received and seat.first_gap.is_empty():
					seat.first_gap = {
						"expected": seat.relay_received,
						"received": value.get("sequence"),
						"tick_ms": Time.get_ticks_msec(),
						"poll": seat.transport.observer.latest.duplicate()
					}
				_expect(
					(
						value is Dictionary
						and value.get("sequence") == seat.relay_received
						and value.get("body") == "0123456789abcdef".repeat(256)
					),
					"exact relay bytes and sequence"
				)
				seat.relay_received += 1
		)
		_seats.append(seat)


func _connect_generation() -> bool:
	_generation += 1
	_hold = false
	_active = false
	for seat: Seat in _seats:
		seat.authenticated = false
		seat.ready = false
		if seat.plan != null:
			seat.old_generation = seat.plan.generation
		seat.plan = null
		seat.received = [0, 0, 0]
		seat.relay_sent = 0
		seat.relay_received = 0
		seat.trace.clear()
		seat.closes.clear()
		seat.failures.clear()
		seat.protocol_errors.clear()
		seat.refused.clear()
		seat.first_gap.clear()
		seat.offered = 0
		seat.credit_blocked_frames = 0
		seat.peak_outstanding_body_bytes = 0
		seat.client.transport = seat.transport
		_expect(seat.client.connect_to_server(str(_options["service_url"])) == OK, "connect")
	if not await _wait(
		func() -> bool: return _seats[0].authenticated and _seats[1].authenticated, "login"
	):
		return false
	var game := "shutdown-%d-%d" % [Time.get_ticks_usec(), _generation]
	for index: int in 2:
		var params := ClientScript.JoinRoomParams.new()
		params.game_name = game
		params.player_name = "Seat%d" % index
		params.max_players = 2
		params.supports_authority = false
		params.room_code = "" if index == 0 else _seats[0].client.get_room_code()
		_expect(_seats[index].client.join_room(params) == OK, "join")
		if not await _wait(
			func() -> bool: return not _seats[index].client.get_room_id().is_empty(), "room"
		):
			return false
	for seat: Seat in _seats:
		_expect(seat.client.set_ready() == OK, "ready")
	if not await _wait(func() -> bool: return _seats[0].ready and _seats[1].ready, "lobby"):
		return false
	_expect(_seats[0].client.start_game() == OK, "start")
	if not await _wait(
		func() -> bool:
			return (
				_seats[0].mesh._count_connected_peers() == 1
				and _seats[1].mesh._count_connected_peers() == 1
			),
		"mesh"
	):
		return false
	for seat: Seat in _seats:
		seat.expected_sender = _other(seat).client.get_player_id()
	var pause_ms: int = _options.get("receive_pause_ms", 0)
	for seat: Seat in _seats:
		seat.transport.observer.pause_until_us = (Time.get_ticks_usec() + pause_ms * 1000)
	_relay_started = Time.get_ticks_msec()
	_active = true
	for sequence: int in 32:
		for seat: Seat in _seats:
			var peer := seat.mesh.get_safe_multiplayer_peer()
			peer.set_target_peer(MeshScript.uuid_to_peer_id(_other(seat).client.get_player_id()))
			for mode: int in MODES:
				peer.transfer_mode = mode as MultiplayerPeer.TransferMode
				_expect(peer.put_packet(_packet(seat, mode, sequence)) == OK, "warm mesh send")
		await get_tree().process_frame
	var complete := await _wait(
		func() -> bool:
			return (
				_seats[0].received == [32, 32, 32]
				and _seats[1].received == [32, 32, 32]
				and _seats[0].relay_received >= 32
				and _seats[1].relay_received >= 32
			),
		"exact warm gameplay"
	)

	var evidence: Array[Dictionary] = []
	for seat: Seat in _seats:
		evidence.append(
			{
				"received_by_mode": seat.received.duplicate(),
				"relay_sent": seat.relay_sent,
				"relay_received": seat.relay_received,
				"relay_offered": seat.offered,
				"credit_blocked_frames": seat.credit_blocked_frames,
				"peak_outstanding_body_bytes": seat.peak_outstanding_body_bytes,
				"receive": seat.transport.observer.summary(),
				"first_relay_gap": seat.first_gap.duplicate(),
				"plan_generation": seat.plan.generation if seat.plan != null else ""
			}
		)
	print(
		(
			"ACTIVE_SHUTDOWN_GENERATION "
			+ JSON.stringify({"generation": _generation, "complete": complete, "seats": evidence})
		)
	)
	return complete


func _cache_packets() -> bool:
	_hold = true
	for seat: Seat in _seats:
		seat.old_peer = seat.mesh.get_safe_multiplayer_peer()
		seat.old_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		_expect(seat.old_peer.put_packet("cached-unreliable".to_utf8_buffer()) == OK, "cached send")
	if not await _wait(
		func() -> bool:
			return (
				_seats[0].old_peer.get_available_packet_count() == 1
				and _seats[1].old_peer.get_available_packet_count() == 1
			),
		"cached selection"
	):
		return false
	for seat: Seat in _seats:
		_expect(
			seat.old_peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
			"cached unreliable mode"
		)
		seat.old_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
		_expect(seat.old_peer.put_packet(_packet(seat, 2, 32)) == OK, "late reliable arrival")
	if not await _wait(
		func() -> bool:
			return (
				_seats[0].old_peer.get_available_packet_count() == 2
				and _seats[1].old_peer.get_available_packet_count() == 2
			),
		"late reliable queue"
	):
		return false
	for seat: Seat in _seats:
		_expect(
			seat.old_peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
			"stable cached mode"
		)
		_expect(
			seat.old_peer.get_packet() == "cached-unreliable".to_utf8_buffer(),
			"stable cached bytes"
		)
		_expect(
			seat.old_peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			"late reliable mode"
		)
		_expect(seat.old_peer.get_packet() == _packet(_other(seat), 2, 32), "late reliable bytes")
		seat.old_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		_expect(seat.old_peer.put_packet("retire-me".to_utf8_buffer()) == OK, "retirement send")
	return await _wait(
		func() -> bool:
			return (
				_seats[0].old_peer.get_available_packet_count() == 1
				and _seats[1].old_peer.get_available_packet_count() == 1
			),
		"retirement selection"
	)


func _control(path: String) -> bool:
	if _http.request(str(_options["control_url"]) + path) != OK:
		return false
	var response: Array = await _http.request_completed
	return response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200


func _run() -> void:
	_setup()
	if not await _connect_generation() or not await _cache_packets():
		_finish("setup")
		return
	for seat: Seat in _seats:
		seat.client.set_auto_reconnect(true)
	var before := [_seats[0].relay_sent, _seats[1].relay_sent]
	_shutdown_requested = true
	_expect(await _control("/shutdown"), "driver shutdown")
	if _options["mode"] == "stall":
		for seat: Seat in _seats:
			_expect(seat.client.close() == OK, "nonresponding close")
	if not await _wait(
		func() -> bool: return _terminal(_seats[0]) and _terminal(_seats[1]), "terminal close"
	):
		_finish("terminal")
		return
	_active = false
	var results: Array[Dictionary] = []
	for seat: Seat in _seats:
		var retry: bool = seat.client.get("_reconnect_timer_running")
		seat.client.set_auto_reconnect(false)
		var mode: String = _options["mode"]
		if mode == "graceful":
			_expect(seat.trace == ["going_away", "closed"], "advisory then one close")
			_expect(
				(
					seat.closes.size() == 1
					and seat.failures.is_empty()
					and seat.closes[0]["code"] == 4000
					and seat.closes[0]["reason"] == "server_shutdown"
				),
				"semantic shutdown metadata"
			)
			_expect(retry, "shutdown arms automatic reconnect")
		elif mode == "reset":
			_expect(
				(
					(
						seat.trace == ["closed"]
						and seat.closes.size() == 1
						and seat.closes[0]["code"] in [-1, 1006]
						and seat.failures.is_empty()
					)
					or (
						seat.trace.is_empty()
						and seat.closes.is_empty()
						and seat.failures.size() == 1
						and seat.failures[0].begins_with("failed to send WebSocket text frame:")
					)
				),
				"abnormal reset metadata"
			)
			_expect(retry, "reset arms automatic reconnect")
		else:
			_expect(seat.failures == ["heartbeat close timeout"], "bounded nonresponding close")
			_expect(not retry and seat.trace.is_empty(), "user close stops retry")
		_expect(seat.protocol_errors.size() <= 1 and seat.refused.size() <= 1, "one refused send")
		var refused_application := 0
		for reason: String in seat.protocol_errors:
			if reason.begins_with("send_game_data send failed:"):
				refused_application += 1
			else:
				_expect(
					(
						mode == "reset"
						and reason == "send_transport_status send failed: Failed"
						and seat.failures == ["failed to send WebSocket text frame: Failed"]
					),
					"shutdown transport-status diagnostic"
				)
		_expect(refused_application == seat.refused.size(), "application refusal diagnostic")
		for refused: Dictionary in seat.refused:
			_expect(refused["error"] in [ERR_UNCONFIGURED, FAILED], "shutdown send result")
		if mode == "graceful":
			_expect(seat.relay_sent > before[_seats.find(seat)], "active sends through drain")
		_expect(
			seat.mesh.get_peer_count() == 0 and seat.mesh.get_multiplayer_peer() == null,
			"mesh retired"
		)
		_expect(seat.old_peer.get_available_packet_count() == 0, "cached packet retired")
		_expect(
			(
				seat.old_peer.get_packet().is_empty()
				and seat.old_peer.get_packet_error() == ERR_UNAVAILABLE
			),
			"retired read"
		)
		_expect(seat.old_peer.put_packet(PackedByteArray([1])) == ERR_UNCONFIGURED, "retired send")
		results.append(
			{
				"trace": seat.trace.duplicate(),
				"closes": seat.closes.duplicate(true),
				"failures": seat.failures.duplicate(),
				"protocol_errors": seat.protocol_errors.duplicate(),
				"refused_sends": seat.refused.duplicate(true),
				"retry_armed": retry,
				"relay_sent_before_shutdown": before[_seats.find(seat)],
				"relay_sent": seat.relay_sent,
				"relay_received": seat.relay_received,
				"relay_offered": seat.offered,
				"credit_blocked_frames": seat.credit_blocked_frames,
				"peak_outstanding_body_bytes": seat.peak_outstanding_body_bytes,
				"receive": seat.transport.observer.summary(),
				"first_relay_gap": seat.first_gap.duplicate(),
				"mesh_received": seat.received.duplicate()
			}
		)
	print("ACTIVE_SHUTDOWN_TERMINAL " + JSON.stringify(results))
	await get_tree().create_timer(0.2).timeout
	for seat: Seat in _seats:
		_expect(
			(
				seat.trace == results[_seats.find(seat)]["trace"]
				and seat.failures == results[_seats.find(seat)]["failures"]
				and seat.relay_sent == results[_seats.find(seat)]["relay_sent"]
			),
			"no duplicate terminal"
		)
	_expect(await _control("/restart"), "driver restart")
	_shutdown_requested = false
	if not await _connect_generation():
		_finish("fresh generation")
		return
	for seat: Seat in _seats:
		_expect(seat.mesh.get_safe_multiplayer_peer() != seat.old_peer, "fresh receiver")
		_expect(seat.plan.generation != seat.old_generation, "fresh plan generation")
		_expect(seat.old_peer.get_available_packet_count() == 0, "old receiver stays retired")
	_finish("")


func _terminal(seat: Seat) -> bool:
	return not seat.closes.is_empty() or not seat.failures.is_empty()


func _wait(condition: Callable, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	_expect(false, "timed out: " + label)
	return false


func _expect(passed: Variant, label: String) -> void:
	if passed != true and not _failures.has(label):
		_failures.append(label)


func _finish(stage: String) -> void:
	_active = false
	for seat: Seat in _seats:
		seat.client.set_auto_reconnect(false)
		seat.client.close()
	print(
		(
			"ACTIVE_SHUTDOWN_RESULT "
			+ JSON.stringify(
				{
					"passed": _failures.is_empty() and stage.is_empty(),
					"stage": stage,
					"failures": _failures,
					"engine": Engine.get_version_info()["string"],
					"web": OS.has_feature("web"),
					"mode": _options["mode"]
				}
			)
		)
	)
	get_tree().quit(0 if _failures.is_empty() and stage.is_empty() else 1)


class Seat:
	extends RefCounted
	var client := ClientScript.new()
	var mesh := MeshScript.new()
	var transport := ReceiveTransport.new()
	var offered := 0
	var credit_blocked_frames := 0
	var peak_outstanding_body_bytes := 0
	var authenticated := false
	var ready := false
	var plan: SessionScript.SessionPlanInfo
	var received: Array[int] = [0, 0, 0]
	var relay_sent := 0
	var relay_received := 0
	var expected_sender := ""
	var refused: Array[Dictionary] = []
	var protocol_errors: Array[String] = []
	var trace: Array[String] = []
	var closes: Array[Dictionary] = []
	var failures: Array[String] = []
	var old_peer: MultiplayerPeer
	var old_generation := ""
	var first_gap: Dictionary = {}


class ReceiveTransport:
	extends "res://addons/signal_fish/transport/sf_websocket_transport.gd"
	var inbound_buffer_bytes := 0
	var max_queued_packets := 0
	var observer: ReceiveObserver
	var seat_index := 0
	var _connection_index := 0

	# gdscript-private-helper: allow _make_peer
	func _make_peer() -> SFWebSocketPeerAdapterScript:
		var engine_peer := WebSocketPeer.new()
		if inbound_buffer_bytes > 0:
			engine_peer.inbound_buffer_size = inbound_buffer_bytes
		if max_queued_packets > 0:
			engine_peer.max_queued_packets = max_queued_packets
		_connection_index += 1
		observer = ReceiveObserver.new(engine_peer)
		observer.seat_index = seat_index
		observer.connection_index = _connection_index
		print(
			(
				"ACTIVE_SHUTDOWN_CAPACITY "
				+ JSON.stringify(
					{
						"seat": seat_index,
						"connection": _connection_index,
						"inbound_buffer_bytes": engine_peer.inbound_buffer_size,
						"max_queued_packets": engine_peer.max_queued_packets,
						"web": OS.has_feature("web")
					}
				)
			)
		)
		return observer


class ReceiveObserver:
	extends "res://addons/signal_fish/transport/sf_websocket_peer_adapter.gd"
	var latest: Dictionary = {}
	var pause_until_us := 0
	var seat_index := 0
	var connection_index := 0
	var _skipped_polls := 0
	var _last_poll_us := 0
	var _polls := 0
	var _peak_queued := 0
	var _max_interval_us := 0
	var _wire_bytes := 0

	func poll() -> void:
		var started := Time.get_ticks_usec()
		if started < pause_until_us:
			_skipped_polls += 1
			return
		var interval := 0 if _last_poll_us == 0 else started - _last_poll_us
		_last_poll_us = started
		_polls += 1
		_max_interval_us = maxi(_max_interval_us, interval)
		var before := get_available_packet_count()
		super.poll()
		var queued := get_available_packet_count()
		_peak_queued = maxi(_peak_queued, queued)
		latest = {
			"seat": seat_index,
			"connection": connection_index,
			"poll": _polls,
			"start_us": started,
			"interval_us": interval,
			"duration_us": Time.get_ticks_usec() - started,
			"queued_before": before,
			"queued_after": queued
		}
		if queued > 0:
			print("ACTIVE_SHUTDOWN_POLL " + JSON.stringify(latest))

	func get_packet() -> PackedByteArray:
		var packet := super.get_packet()
		_wire_bytes += packet.size()
		return packet

	func summary() -> Dictionary:
		return {
			"seat": seat_index,
			"connection": connection_index,
			"polls": _polls,
			"skipped_polls": _skipped_polls,
			"peak_queued_packets": _peak_queued,
			"max_poll_interval_us": _max_interval_us,
			"received_wire_bytes": _wire_bytes
		}
