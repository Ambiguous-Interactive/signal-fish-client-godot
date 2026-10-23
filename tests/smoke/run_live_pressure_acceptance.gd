extends "res://tests/smoke/run_room_transition_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in concurrent fan-in, host departure and drain. See docs/testing.md.

const STREAM_LENGTH := 40

var _drain_mode := false


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_drain_mode = args.has("drain")
	_run()


func _run() -> void:
	if _drain_mode:
		if await _drain_case() != true:
			_failures.append("drain phase did not complete")
	else:
		for version: int in [2, 3]:
			for format_name: String in ["json", "message_pack"]:
				if await _fanin_case(version, format_name) != true:
					_failures.append("fan-in phase did not complete")
					_finish()
					return
				_close_seats()
		if await _host_departure_case() != true:
			_failures.append("host departure phase did not complete")
	_finish()


func _fanin_case(version: int, format_name: String) -> bool:
	_case += 1
	var first := _seat(version, format_name, false)
	var second := _seat(version, format_name, false)
	var viewer := _seat(version, format_name, false)
	var newcomer := _seat(version, format_name, false)
	if not await _wait(func() -> bool: return _logged_in(), "fan-in login"):
		return false
	var game := "godot-fanin-%d-%d" % [OS.get_process_id(), _case]
	_join(first, game, "")
	if not await _wait(func() -> bool: return first.joined, "fan-in room"):
		return false
	_join(second, game, first.client.get_room_code())
	_expect(
		viewer.client.join_as_spectator(game, first.client.get_room_code(), "Viewer") == OK,
		"fan-in viewer"
	)
	if not await _wait(
		func() -> bool: return second.joined and viewer.baselines == 1, "fan-in baseline"
	):
		return false
	var observations: Array[String] = []
	var admissions: Array[String] = []
	viewer.client.new_spectator_joined.connect(
		func(
			info: TypesScript.SpectatorInfo, current: Array[TypesScript.SpectatorInfo], _reason: int
		) -> void:
			admissions.append(info.id)
			var cached_ids: Array[String] = []
			for cached: TypesScript.SpectatorInfo in viewer.client.get_spectators():
				cached_ids.append(cached.id)
			_expect(
				cached_ids.has(info.id) and cached_ids.size() == 2, "admission cached before signal"
			)
			_expect(
				current.size() == (2 if version == 2 else 0), "v2 full roster and v3 compact delta"
			)
	)
	newcomer.client.spectator_joined.connect(
		func(_info: TypesScript.SpectatorJoinedInfo) -> void: observations.append("baseline")
	)
	newcomer.client.game_data_received.connect(
		func(_sender: String, _payload: Variant) -> void: observations.append("data")
	)
	newcomer.client.game_data_binary_received.connect(
		func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void:
			observations.append("data")
	)
	_paused = viewer
	_queued = 0
	_expect(
		newcomer.client.join_as_spectator(game, first.client.get_room_code(), "Concurrent") == OK,
		"spectator admission overlaps two senders"
	)
	for tick: int in STREAM_LENGTH:
		_send_tick(first, format_name, tick)
		_send_tick(second, format_name, tick + 1000)
	if not await _wait(
		func() -> bool: return _queued >= STREAM_LENGTH * 2 and newcomer.baselines == 1,
		"two sender streams queued during admission"
	):
		return false
	_expect(viewer.data.is_empty(), "real socket backlog held before dispatch")
	_expect(viewer.client.get_spectators().size() == 1, "membership delta also held")
	viewer.client.transport.set("max_packets_per_poll", 1)
	_paused = null
	if not await _wait(
		func() -> bool:
			return (
				viewer.data.size() == STREAM_LENGTH * 2
				and viewer.client.get_spectators().size() == 2
			),
		"bounded fan-in dispatch and membership"
	):
		return false
	var by_sender: Dictionary = {
		first.client.get_player_id(): [], second.client.get_player_id(): []
	}
	for index: int in viewer.data.size():
		var sender: String = viewer.senders[index]
		if not by_sender.has(sender):
			_failures.append("foreign sender in fan-in")
			return false
		var received: Array = by_sender[sender]
		received.append(viewer.data[index])
	for seat: Seat in [first, second]:
		var stream: Array = by_sender[seat.client.get_player_id()]
		_expect(stream.size() == STREAM_LENGTH, "exact reliable sender count")
		for tick: int in stream.size():
			_expect(
				_tick_matches(stream[tick], format_name, tick + (1000 if seat == second else 0)),
				"per-sender order without duplicates"
			)
	_expect(
		not observations.is_empty() and observations[0] == "baseline", "baseline before live fan-in"
	)
	_expect(newcomer.baseline_cached, "concurrent baseline installed before notification")
	_expect(newcomer.client.get_players().size() == 2, "concurrent baseline seated roster")
	_expect(
		newcomer.client.get_spectators().size() == 2 and first.client.get_spectators().size() == 2,
		"spectator membership converges"
	)
	_expect(admissions.size() == 1, "one concurrent spectator admission")
	var marker := 9000
	_send_tick(first, format_name, marker)
	if not await _wait(
		func() -> bool:
			return (
				not newcomer.data.is_empty()
				and _tick_matches(newcomer.data.back(), format_name, marker)
			),
		"post-admission fresh gameplay"
	):
		return false
	_expect(viewer.plans.is_empty() and newcomer.plans.is_empty(), "fan-in preserves unseated role")
	if _failures.is_empty():
		print(
			(
				"LIVE_FANIN_PASS v%d %s two senders 80 queued frames concurrent spectator"
				% [version, format_name]
			)
		)
	return _failures.is_empty()


func _host_departure_case() -> bool:
	var seats: Array[Seat] = []
	for index: int in 3:
		seats.append(_seat(3, "json", false, true))
	if not await _wait(func() -> bool: return _logged_in(), "departure login"):
		return false
	var game := "godot-host-departure-%d" % OS.get_process_id()
	_join(seats[0], game, "")
	if not await _wait(func() -> bool: return seats[0].joined, "departure room"):
		return false
	var code := seats[0].client.get_room_code()
	for index: int in range(1, 3):
		_join(seats[index], game, code)
	if not await _wait(
		func() -> bool: return seats[1].joined and seats[2].joined, "departure peers"
	):
		return false
	for index: int in 3:
		_endpoint(seats[index], "192.0.2.%d" % (10 + index), 7000 + index)
		_expect(seats[index].client.set_ready() == OK, "departure ready")
	if not await _wait(func() -> bool: return seats[0].all_ready, "departure all ready"):
		return false
	_expect(seats[0].client.start_game() == OK, "departure start")
	if not await _wait(
		func() -> bool:
			return (
				not seats[0].plans.is_empty()
				and not seats[1].plans.is_empty()
				and not seats[2].plans.is_empty()
			),
		"departure initial plan"
	):
		return false
	var host_id: String = seats[2].plans.back().host
	var host: Seat = null
	for seat: Seat in seats:
		if seat.client.get_player_id() == host_id:
			host = seat
	_expect(host != null, "initial host is seated")
	if host == null:
		return false
	var generation: String = seats[2].plans.back().generation
	_expect(host.client.leave_room() == OK, "selected host leaves")
	seats.erase(host)
	if not await _wait(
		func() -> bool:
			return (
				seats[0].client.get_players().size() == 2
				and seats[1].client.get_players().size() == 2
				and seats[0].plans.back().generation != generation
				and seats[1].plans.back().generation == seats[0].plans.back().generation
			),
		"host departure successor convergence"
	):
		return false
	var successor_id: String = seats[0].plans.back().host
	_expect(successor_id != host_id, "departed host retired")
	var successor: Seat = seats[0] if seats[0].client.get_player_id() == successor_id else seats[1]
	var successor_index := _seats.find(successor)
	for seat: Seat in seats:
		var plan: SessionScript.SessionPlanInfo = seat.plans.back()
		_expect(plan.transport == SessionScript.TransportKind.DIRECT, "successor keeps Direct")
		if plan.direct_endpoint == null:
			_failures.append("successor endpoint absent")
			return false
		_expect(
			(
				plan.direct_endpoint.host == "192.0.2.%d" % (10 + successor_index)
				and plan.direct_endpoint.port == 7000 + successor_index
			),
			"successor endpoint matches current host"
		)
	var application_paths: Array[String] = []
	for seat: Seat in seats:
		seat.client.session_plan.connect(
			func(plan: SessionScript.SessionPlanInfo) -> void:
				application_paths.append(
					plan.direct_endpoint.host if plan.direct_endpoint != null else "relay"
				)
		)
		_endpoint(seat, "0.0.0.0", 0)
	if not await _wait(
		func() -> bool:
			return (
				seats[0].plans.back().transport == SessionScript.TransportKind.RELAY
				and seats[1].plans.back().transport == SessionScript.TransportKind.RELAY
			),
		"departure fallback Relay"
	):
		return false
	for seat: Seat in seats:
		var reset: SessionScript.SessionPlanInfo = seat.plans.back()
		_expect(
			(
				reset.host.is_empty()
				and reset.direct_endpoint == null
				and reset.peers.is_empty()
				and reset.ice_servers.is_empty()
			),
			"departure reset clears selected path"
		)
	_expect(application_paths.count("relay") == 2, "plan callbacks receive Relay reset")
	_expect(
		seats[0].plans.back().generation == seats[1].plans.back().generation,
		"shared reset generation"
	)
	_expect(seats[0].client.send_game_data({"after_departure": true}) == OK, "departure relay send")
	if not await _wait(func() -> bool: return seats[1].data.size() == 1, "departure relay receipt"):
		return false
	_expect(_same_payload(seats[1].data[0], {"after_departure": true}), "departure relay payload")
	if _failures.is_empty():
		print("LIVE_HOST_DEPARTURE_PASS successor reset application relay")
	return _failures.is_empty()


func _drain_case() -> bool:
	var host := _seat(3, "json", false)
	var viewer := _seat(3, "json", false)
	if not await _wait(func() -> bool: return _logged_in(), "drain logins"):
		return false
	var game := "godot-drain-%d" % OS.get_process_id()
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "drain room"):
		return false
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Drain") == OK,
		"drain spectate"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "drain baseline"):
		return false
	var trace: Array[String] = []
	viewer.client.spectator_left.connect(
		func(
			_room: String, _code: String, _reason: int, _current: Array[TypesScript.SpectatorInfo]
		) -> void:
			trace.append("left")
	)
	viewer.client.going_away.connect(
		func(_deadline: int, _retry: int) -> void: trace.append("going_away")
	)
	viewer.client.disconnected.connect(
		func(code: int, _reason: String) -> void:
			trace.append("closed")
			_expect(code == 4000, "server drain close code")
	)
	_paused = viewer
	_queued = 0
	_expect(viewer.client.leave_spectator() == OK, "pre-drain leave")
	if not await _wait(
		func() -> bool: return _queued > 0 and host.client.get_spectators().is_empty(),
		"terminal queued before drain"
	):
		return false
	_paused = null
	print("LIVE_DRAIN_READY")
	if not await _wait(func() -> bool: return trace.has("closed"), "terminal and shutdown close"):
		return false
	_expect(
		trace == ["left", "going_away", "closed"], "terminal then advisory then close exactly once"
	)
	_expect(viewer.client.get_room_id().is_empty(), "drain clears room")
	_expect(viewer.client.get("_context_auth_token") == "", "drain clears retained identity")
	if _failures.is_empty():
		print("LIVE_DRAIN_PASS terminal advisory close")
	return _failures.is_empty()
