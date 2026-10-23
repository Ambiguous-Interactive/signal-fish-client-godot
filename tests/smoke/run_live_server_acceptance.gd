extends SceneTree
# gdlint: disable=max-returns

## Opt-in acceptance against a local fixed server. See docs/testing.md.

const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const TypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const MsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")

var _seats: Array[Seat] = []
var _failures: Array[String] = []
var _base_url := "ws://127.0.0.1:3536"
var _started := 0
var _case := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _process(_delta: float) -> bool:
	for seat: Seat in _seats:
		seat.client.poll()
	if Time.get_ticks_msec() - _started > 120000:
		push_error("live server acceptance watchdog expired")
		quit(1)
	return false


func _run() -> void:
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			for decoded: bool in [false, true] if format_name == "message_pack" else [false]:
				if await _spectator_case(version, format_name, decoded) != true:
					_failures.append("spectator phase did not complete")
					_finish()
					return
				_close_seats()
	for format_name: String in ["rkyv", "protobuf"]:
		if await _spectator_case(3, format_name, false) != true:
			_failures.append("opaque spectator phase did not complete")
			_finish()
			return
		_close_seats()
	if await _direct_case() != true:
		_failures.append("Direct phase did not complete")
	_finish()


func _spectator_case(version: int, format_name: String, decoded: bool) -> bool:
	_case += 1
	var host := _seat(version, format_name, false)
	var viewer := _seat(version, format_name, decoded)
	if not await _wait(
		func() -> bool:
			return (
				host.authenticated
				and viewer.authenticated
				and host.protocol != null
				and viewer.protocol != null
			),
		"login"
	):
		return false
	if version == 3:
		_expect(viewer.protocol.protocol_version == 3, "v3 negotiated")
		_expect(
			viewer.protocol.capabilities.has("spectator_relay"), "server advertises spectator_relay"
		)
	var game := "godot-live-%d-%d" % [OS.get_process_id(), _case]
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "host room"):
		return false
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Viewer") == OK,
		"spectator send"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "spectator baseline"):
		return false
	_expect(viewer.baseline_cached, "baseline installed before spectator signal")
	var late := _seat(version, format_name, false)
	if not await _wait(
		func() -> bool: return late.authenticated and late.protocol != null, "late player login"
	):
		return false
	_join(late, game, host.client.get_room_code())
	if not await _wait(
		func() -> bool: return late.joined and viewer.client.get_players().size() == 2,
		"live roster join"
	):
		return false
	_expect(host.client.set_ready() == OK and late.client.set_ready() == OK, "ready sends")
	if not await _wait(func() -> bool: return host.all_ready, "ready broadcast"):
		return false
	_expect(host.client.start_game() == OK, "start send")
	if not await _wait(func() -> bool: return viewer.starts == 1, "spectator GameStarting"):
		return false
	var payload := {"tick": 42, "case": _case}
	if format_name == "json":
		_expect(host.client.send_game_data(payload) == OK, "JSON send")
	elif format_name == "message_pack":
		_expect(host.client.send_game_data_binary(_msgpack(payload)) == OK, "MessagePack send")
	else:
		_expect(host.client.send_game_data_binary(PackedByteArray([1, 2, 42])) == OK, "opaque send")
	if not await _wait(func() -> bool: return viewer.data.size() == 1, "live spectator gameplay"):
		return false
	_expect(viewer.senders[0] == host.client.get_player_id(), "gameplay sender identity")
	if format_name != "json" and not decoded:
		_expect(
			viewer.encodings[0] == TypesScript.GAME_DATA_ENCODING_FROM_STRING[format_name],
			"binary encoding identity"
		)
	if format_name == "json" or decoded:
		_expect(_same_payload(viewer.data[0], payload), "decoded gameplay payload")
	elif format_name == "message_pack":
		_expect(viewer.data[0] == _msgpack(payload), "raw MessagePack payload")
	else:
		_expect(viewer.data[0] == PackedByteArray([1, 2, 42]), "opaque gameplay payload")
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING,
		"public lifecycle preserves spectator"
	)
	_expect(
		viewer.plans.is_empty() and viewer.client.get_player_id().is_empty(),
		"viewer has no seat or personalized plan"
	)

	_expect(late.client.leave_room() == OK, "player leave send")
	if not await _wait(
		func() -> bool: return viewer.client.get_players().size() == 1, "live roster leave"
	):
		return false
	_expect(viewer.client.leave_spectator() == OK, "spectator leave send")
	if not await _wait(func() -> bool: return viewer.left == 1, "spectator terminal"):
		return false
	_expect(viewer.client.get_room_id().is_empty(), "spectator leave clears baseline")
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
		"spectator leave restores role"
	)
	if _failures.is_empty():
		print("LIVE_SPECTATOR_PASS v%d %s decoded=%s" % [version, format_name, decoded])
	return _failures.is_empty()


func _direct_case() -> bool:
	var host := _seat(3, "json", false, true)
	var peer := _seat(3, "json", false, true)
	if not await _wait(
		func() -> bool:
			return (
				host.authenticated
				and peer.authenticated
				and host.protocol != null
				and peer.protocol != null
			),
		"Direct login"
	):
		return false
	var game := "godot-direct-%d" % OS.get_process_id()
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "Direct host"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(
		func() -> bool: return peer.joined and host.client.get_players().size() == 2, "Direct peer"
	):
		return false
	_endpoint(host, "192.0.2.10", 7000)
	_endpoint(peer, "192.0.2.20", 8000)
	host.client.set_ready()
	peer.client.set_ready()
	if not await _wait(func() -> bool: return host.all_ready, "Direct ready"):
		return false
	host.client.start_game()
	if not await _wait(
		func() -> bool: return host.plans.size() == 1 and peer.plans.size() == 1,
		"initial Direct plan"
	):
		return false
	var selected: Seat = host if host.plans.back().host == host.client.get_player_id() else peer
	var other: Seat = peer if selected == host else host
	_expect(
		host.plans.back().transport == SessionScript.TransportKind.DIRECT, "host/direct negotiated"
	)
	_endpoint(selected, "192.0.2.30", 9000)
	if not await _wait(
		func() -> bool: return host.plans.size() == 2 and peer.plans.size() == 2, "endpoint refresh"
	):
		return false
	for seat: Seat in [host, peer]:
		if seat.plans[1].direct_endpoint == null:
			_failures.append("Direct refresh missing endpoint")
			return false
		_expect(
			(
				seat.plans[1].direct_endpoint.host == "192.0.2.30"
				and seat.plans[1].direct_endpoint.port == 9000
			),
			"refreshed endpoint on both clients"
		)
		_expect(seat.plans[1].generation != seat.plans[0].generation, "refresh generation changed")
	_expect(host.plans[1].generation == peer.plans[1].generation, "shared refresh generation")
	_endpoint(selected, "192.0.2.30", 9000)
	_endpoint(other, "192.0.2.40", 8001)
	selected.client.ping()
	other.client.ping()
	if not await _wait(
		func() -> bool: return selected.pongs == 1 and other.pongs == 1, "metadata barriers"
	):
		return false
	_expect(
		host.plans.size() == 2 and peer.plans.size() == 2,
		"duplicate and non-host metadata keep generation"
	)
	_endpoint(selected, "0.0.0.0", 0)
	if not await _wait(
		func() -> bool: return host.plans.size() == 3 and peer.plans.size() == 3, "host successor"
	):
		return false
	for seat: Seat in [host, peer]:
		_expect(seat.plans[2].host == other.client.get_player_id(), "successor selected")
		if seat.plans[2].direct_endpoint == null:
			_failures.append("successor missing endpoint")
			return false
		_expect(
			(
				seat.plans[2].direct_endpoint.host == "192.0.2.40"
				and seat.plans[2].direct_endpoint.port == 8001
			),
			"successor endpoint"
		)
	_endpoint(other, "0.0.0.0", 0)
	if not await _wait(
		func() -> bool: return host.plans.size() == 4 and peer.plans.size() == 4, "Relay reset"
	):
		return false
	for seat: Seat in [host, peer]:
		var reset: SessionScript.SessionPlanInfo = seat.plans.back()
		_expect(
			(
				reset.transport == SessionScript.TransportKind.RELAY
				and reset.topology == SessionScript.Topology.RELAY
			),
			"Relay floor"
		)
		_expect(
			(
				reset.host.is_empty()
				and reset.direct_endpoint == null
				and reset.peers.is_empty()
				and reset.ice_servers.is_empty()
			),
			"reset clears Direct state"
		)
	for index: int in range(1, 4):
		_expect(
			host.plans[index].generation == peer.plans[index].generation, "shared plan generation"
		)
		_expect(
			host.plans[index].generation != host.plans[index - 1].generation,
			"fresh plan generation"
		)
	_expect(host.client.send_game_data({"after_reset": true}) == OK, "relay gameplay send")
	if not await _wait(func() -> bool: return peer.data.size() == 1, "relay gameplay after reset"):
		return false
	_expect(_same_payload(peer.data[0], {"after_reset": true}), "relay payload after reset")
	if _failures.is_empty():
		print("LIVE_DIRECT_PASS refresh successor relay gameplay")
	return _failures.is_empty()


func _same_payload(actual: Variant, expected: Dictionary) -> bool:
	if not actual is Dictionary:
		return false
	var fields: Dictionary = actual
	if fields.size() != expected.size():
		return false
	for key: String in expected:
		if not fields.has(key) or fields[key] != expected[key]:
			return false
	return true


func _msgpack(payload: Dictionary) -> PackedByteArray:
	var result := MsgpackScript.encode(payload)
	var bytes: PackedByteArray = result["bytes"]
	return bytes


func _seat(version: int, format_name: String, decoded: bool, direct := false) -> Seat:
	var seat := Seat.new()
	var config := ConfigScript.new()
	config.app_id = "godot-live-acceptance"
	config.protocol_version = version
	config.game_data_format = format_name
	config.decode_msgpack_payloads = decoded
	config.auto_poll = false
	if direct:
		config.supported_transports = PackedStringArray(["relay", "direct"])
		config.supported_topologies = PackedStringArray(["relay", "host"])
	_expect(seat.client.configure(config) == OK, "configure")
	seat.client.protocol_error.connect(func(message: String) -> void: _failures.append(message))
	seat.client.server_error.connect(
		func(message: String, _code: int) -> void: _failures.append(message)
	)
	seat.client.connection_failed.connect(func(message: String) -> void: _failures.append(message))
	_expect(seat.client.connect_to_server("%s/v%d/ws" % [_base_url, version]) == OK, "connect")
	_seats.append(seat)
	return seat


func _join(seat: Seat, game: String, code: String) -> void:
	var params := ClientScript.JoinRoomParams.new()
	params.game_name = game
	params.player_name = "Player%d" % _seats.find(seat)
	params.room_code = code
	params.max_players = 4
	params.supports_authority = false
	_expect(seat.client.join_room(params) == OK, "join send")


func _endpoint(seat: Seat, host: String, port: int) -> void:
	_expect(
		(
			seat.client.provide_connection_info(
				TypesScript.ConnectionInfo.new({"type": "direct", "host": host, "port": port})
			)
			== OK
		),
		"endpoint send"
	)


func _wait(condition: Callable, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	_failures.append("timed out: " + label)
	return false


func _expect(passed: Variant, label: String) -> void:
	if passed != true:
		_failures.append(label)


func _close_seats() -> void:
	for seat: Seat in _seats:
		seat.client.close()
		seat.client.free()
	_seats.clear()


func _finish() -> void:
	_close_seats()
	for failure: String in _failures:
		push_error(failure)
	print("LIVE_SERVER_ACCEPTANCE_PASS" if _failures.is_empty() else "LIVE_SERVER_ACCEPTANCE_FAIL")
	quit(0 if _failures.is_empty() else 1)


class Seat:
	extends RefCounted
	var client := ClientScript.new()
	var authenticated := false
	var protocol: TypesScript.ProtocolInfo = null
	var joined := false
	var baselines := 0
	var baseline_cached := false
	var starts := 0
	var left := 0
	var all_ready := false
	var data: Array = []
	var senders: Array[String] = []
	var encodings: Array[int] = []
	var pongs := 0
	var plans: Array[SessionScript.SessionPlanInfo] = []

	func _init() -> void:
		client.authenticated.connect(
			func(_app: String, _org: String, _rates: TypesScript.RateLimitInfo) -> void:
				authenticated = true
		)
		client.protocol_info.connect(func(info: TypesScript.ProtocolInfo) -> void: protocol = info)
		client.room_joined.connect(func(_info: TypesScript.RoomJoinedInfo) -> void: joined = true)
		client.spectator_joined.connect(
			func(info: TypesScript.SpectatorJoinedInfo) -> void:
				baselines += 1
				baseline_cached = _baseline_matches(info)
		)
		client.game_starting.connect(
			func(_peers: Array[TypesScript.PeerConnectionInfo]) -> void: starts += 1
		)
		client.spectator_left.connect(
			func(
				_room: String,
				_code: String,
				_reason: int,
				_current: Array[TypesScript.SpectatorInfo]
			) -> void:
				left += 1
		)
		client.lobby_state_changed.connect(
			func(_state: int, _ready: PackedStringArray, ready: bool) -> void: all_ready = ready
		)
		client.game_data_received.connect(
			func(sender: String, value: Variant) -> void:
				senders.append(sender)
				data.append(value)
		)
		client.game_data_binary_received.connect(
			func(sender: String, encoding: int, bytes: PackedByteArray) -> void:
				senders.append(sender)
				encodings.append(encoding)
				data.append(bytes)
		)
		client.pong.connect(func() -> void: pongs += 1)
		client.session_plan.connect(
			func(plan: SessionScript.SessionPlanInfo) -> void: plans.append(plan)
		)

	func _baseline_matches(info: TypesScript.SpectatorJoinedInfo) -> bool:
		if client.get_room_id() != info.room_id or client.get_room_code() != info.room_code:
			return false
		if client.get_lobby_state() != info.lobby_state or not client.get_player_id().is_empty():
			return false
		var players := client.get_players()
		var spectators := client.get_spectators()
		if (
			players.size() != info.current_players.size()
			or spectators.size() != info.current_spectators.size()
		):
			return false
		for index: int in players.size():
			if players[index].raw != info.current_players[index].raw:
				return false
		for index: int in spectators.size():
			if spectators[index].raw != info.current_spectators[index].raw:
				return false
		return client.get_session_state() == ClientScript.SessionState.SPECTATING
