extends SceneTree

## Opt-in real WebSocket acceptance for issue #367. See docs/testing.md.

const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const TypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SessionScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")

var _seats: Array[Seat] = []
var _failures: Array[String] = []
var _base_url := "ws://127.0.0.1:3536"
var _started := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _process(_delta: float) -> bool:
	for seat: Seat in _seats:
		seat.client.poll()
	if Time.get_ticks_msec() - _started > 60000:
		push_error("live transport report watchdog expired")
		quit(1)
	return false


func _run() -> void:
	if await _reports_case() != true:
		_failures.append("live transport report phase did not complete")
	for seat: Seat in _seats:
		seat.client.close()
		seat.client.free()
	for failure: String in _failures:
		push_error(failure)
	print("LIVE_TRANSPORT_REPORTS_PASS" if _failures.is_empty() else "LIVE_TRANSPORT_REPORTS_FAIL")
	quit(0 if _failures.is_empty() else 1)


func _reports_case() -> bool:
	var reporter := _seat(3, true)
	var observer := _seat(3, false)
	var legacy := _seat(2, false)
	if not await _wait(
		func() -> bool: return reporter.ready() and observer.ready() and legacy.ready(), "logins"
	):
		return false
	var game := "godot-reports-%d" % OS.get_process_id()
	_join(reporter, game, "")
	if not await _wait(func() -> bool: return reporter.baseline != null, "reporter room"):
		return false
	for seat: Seat in [observer, legacy]:
		_join(seat, game, reporter.client.get_room_code())
	if not await _wait(
		func() -> bool:
			return (
				observer.baseline != null
				and legacy.baseline != null
				and reporter.client.get_players().size() == 3
			),
		"room membership"
	):
		return false
	var player_id := reporter.client.get_player_id()
	var room_id := reporter.client.get_room_id()
	var token := reporter.baseline.reconnection_token
	_expect(not token.is_empty(), "reconnect identity available")
	var expected: Array[Array] = []
	for kind: int in [SessionScript.TransportKind.DIRECT, SessionScript.TransportKind.RELAY]:
		var states: Array = (
			[true, false, true, true, false, false, true]
			if kind == SessionScript.TransportKind.DIRECT
			else [false, true, true, false]
		)
		var previous: Variant = null
		for connected: bool in states:
			_expect(reporter.client.send_transport_status(kind, connected) == OK, "report send")
			if previous == null or connected != previous:
				expected.append([player_id, kind, connected])
			previous = connected
	if not await _barrier(reporter, observer, legacy, 1):
		return false
	_expect(observer.reports == expected, "typed reports retain both transition orders")
	_expect(reporter.reports.is_empty(), "reporter excluded from fanout")
	_expect(legacy.reports.is_empty(), "v2 member excluded from v3 reports")
	_expect(observer.client.get_players().size() == 3, "reports preserve membership")

	reporter.client.close()
	if not await _wait(
		func() -> bool: return reporter.closed == 1 and observer.departures.has(player_id),
		"reporter disconnect"
	):
		return false
	_expect(reporter.client.reconnect(player_id, room_id, token) == OK, "reconnect send")
	if not await _wait(
		func() -> bool: return reporter.restored == 1 and observer.returns.has(player_id),
		"restored membership"
	):
		return false
	_expect(reporter.client.get_player_id() == player_id, "reconnect retains player")
	_expect(reporter.client.get_room_id() == room_id, "reconnect retains room")
	_expect(observer.client.get_room_id() == room_id, "observer retains room after reconnect")
	# The first identical state in a fresh membership generation must fan out again.
	for connected: bool in [false, false, true, true, false]:
		_expect(
			(
				reporter.client.send_transport_status(SessionScript.TransportKind.RELAY, connected)
				== OK
			),
			"restored report send"
		)
	for connected: bool in [false, true, false]:
		expected.append([player_id, SessionScript.TransportKind.RELAY, connected])
	if not await _barrier(reporter, observer, legacy, 2):
		return false
	_expect(observer.reports == expected, "fresh generation resets duplicate suppression")
	_expect(reporter.reports.is_empty(), "reconnected reporter excluded")
	_expect(legacy.reports.is_empty(), "v2 member stays excluded after reconnect")
	return _failures.is_empty()


func _barrier(reporter: Seat, observer: Seat, legacy: Seat, marker: int) -> bool:
	_expect(reporter.client.send_game_data({"barrier": marker}) == OK, "gameplay barrier send")
	if not await _wait(
		func() -> bool: return observer.markers.has(marker) and legacy.markers.has(marker),
		"gameplay barriers"
	):
		return false
	return true


func _seat(version: int, direct: bool) -> Seat:
	var seat := Seat.new()
	var config := ConfigScript.new()
	config.app_id = "godot-live-acceptance"
	config.protocol_version = version
	config.auto_poll = false
	if direct:
		config.supported_transports = PackedStringArray(["relay", "direct"])
	_expect(seat.client.configure(config) == OK, "configure")
	seat.client.protocol_error.connect(func(message: String) -> void: _failures.append(message))
	seat.client.server_error.connect(
		func(message: String, _code: int) -> void: _failures.append(message)
	)
	seat.client.connection_failed.connect(func(message: String) -> void: _failures.append(message))
	seat.client.reconnection_failed.connect(
		func(message: String, _code: int) -> void: _failures.append(message)
	)
	_expect(seat.client.connect_to_server("%s/v%d/ws" % [_base_url, version]) == OK, "connect")
	_seats.append(seat)
	return seat


func _join(seat: Seat, game: String, code: String) -> void:
	var params := ClientScript.JoinRoomParams.new()
	params.game_name = game
	params.player_name = "Reports%d" % _seats.find(seat)
	params.room_code = code
	params.max_players = 4
	params.supports_authority = false
	_expect(seat.client.join_room(params) == OK, "join send")


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


class Seat:
	extends RefCounted
	var client := ClientScript.new()
	var authenticated := false
	var protocol: TypesScript.ProtocolInfo = null
	var baseline: TypesScript.RoomJoinedInfo = null
	var reports: Array[Array] = []
	var departures: Array[String] = []
	var returns: Array[String] = []
	var markers: Array[int] = []
	var closed := 0
	var restored := 0

	func _init() -> void:
		client.authenticated.connect(
			func(_app: String, _org: String, _rates: TypesScript.RateLimitInfo) -> void:
				authenticated = true
		)
		client.protocol_info.connect(func(info: TypesScript.ProtocolInfo) -> void: protocol = info)
		client.room_joined.connect(func(info: TypesScript.RoomJoinedInfo) -> void: baseline = info)
		client.peer_transport_status.connect(
			func(peer_id: String, kind: int, connected: bool) -> void:
				reports.append([peer_id, kind, connected])
		)
		client.player_left.connect(func(player_id: String) -> void: departures.append(player_id))
		client.player_reconnected.connect(
			func(player_id: String) -> void: returns.append(player_id)
		)
		client.game_data_received.connect(
			func(_sender: String, data: Variant) -> void:
				if data is Dictionary:
					var payload: Dictionary = data
					var marker: Variant = payload.get("barrier")
					if marker is float:
						var number: float = marker
						markers.append(int(number))
					elif marker is int:
						markers.append(marker)
		)
		client.disconnected.connect(func(_code: int, _reason: String) -> void: closed += 1)
		client.reconnected.connect(
			func(
				info: TypesScript.RoomJoinedInfo, _missed: Array[TypesScript.DecodedEvent]
			) -> void:
				baseline = info
				restored += 1
		)

	func ready() -> bool:
		return authenticated and protocol != null
