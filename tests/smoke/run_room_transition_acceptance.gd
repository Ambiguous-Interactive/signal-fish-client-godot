extends "res://tests/smoke/run_live_server_acceptance.gd"
# gdlint: disable=max-returns

const PeerAdapterScript = preload("res://addons/signal_fish/transport/sf_websocket_peer_adapter.gd")
const BURST := 80

var _paused: Seat = null
var _queued := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _process(_delta: float) -> bool:
	for seat: Seat in _seats:
		if seat == _paused:
			var adapter: PeerAdapterScript = seat.client.transport.get("_peer")
			adapter.poll()
			_queued = adapter.get_available_packet_count()
		else:
			seat.client.poll()
	if Time.get_ticks_msec() - _started > 120000:
		push_error("room transition acceptance watchdog expired")
		quit(1)
	return false


func _run() -> void:
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			if await _queued_switch_case(version, format_name) != true:
				_failures.append("queued room switch did not complete")
				_finish()
				return
			_close_seats()
	if await _direct_membership_case() != true:
		_failures.append("Direct membership phase did not complete")
	_finish()


func _queued_switch_case(version: int, format_name: String) -> bool:
	_case += 1
	var first := _seat(version, format_name, false)
	var second := _seat(version, format_name, false)
	var viewer := _seat(version, format_name, false)
	if not await _wait(func() -> bool: return _logged_in(), "switch login"):
		return false
	if version == 3:
		_expect(viewer.protocol.capabilities.has("spectator_relay"), "spectator relay advertised")
	var game := "godot-switch-%d-%d" % [OS.get_process_id(), _case]
	_join(first, game, "")
	_join(second, game + "-next", "")
	if not await _wait(func() -> bool: return first.joined and second.joined, "two rooms"):
		return false
	var first_room := first.client.get_room_id()
	var second_room := second.client.get_room_id()
	var rooms: Array[String] = []
	var events: Array[String] = []
	viewer.client.game_data_received.connect(
		func(_sender: String, _value: Variant) -> void:
			rooms.append(viewer.client.get_room_id())
			events.append("data")
	)
	viewer.client.game_data_binary_received.connect(
		func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void:
			rooms.append(viewer.client.get_room_id())
			events.append("data")
	)
	viewer.client.spectator_joined.connect(
		func(_info: TypesScript.SpectatorJoinedInfo) -> void: events.append("joined")
	)
	viewer.client.spectator_left.connect(
		func(
			_room: String, _code: String, _reason: int, _current: Array[TypesScript.SpectatorInfo]
		) -> void:
			events.append("left")
	)
	_expect(
		viewer.client.join_as_spectator(game, first.client.get_room_code(), "Viewer") == OK,
		"first spectate"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "first baseline"):
		return false
	_queued = 0
	_paused = viewer
	for tick: int in BURST:
		_send_tick(first, format_name, tick)
	if not await _wait(func() -> bool: return _queued >= BURST, "real receive backlog"):
		return false
	_expect(viewer.data.is_empty(), "queued packets have not reached application")
	_expect(viewer.client.leave_spectator() == OK, "queued leave")
	_expect(
		(
			viewer.client.join_as_spectator(game + "-next", second.client.get_room_code(), "Viewer")
			== OK
		),
		"pipelined room switch"
	)
	if not await _wait(
		func() -> bool: return second.client.get_spectators().size() == 1, "new server membership"
	):
		return false
	_send_tick(first, format_name, BURST)
	_send_tick(second, format_name, 900)
	_expect(viewer.client.ping() == OK, "switch barrier send")
	if not await _wait(
		func() -> bool: return _queued >= BURST + 3, "room controls queued after backlog"
	):
		return false
	viewer.client.transport.set("max_packets_per_poll", 1)
	_paused = null
	if not await _wait(
		func() -> bool: return viewer.pongs == 1 and viewer.data.size() >= BURST + 1,
		"switch drain barrier"
	):
		return false
	_expect(viewer.left == 1 and viewer.baselines == 2, "one terminal and one new baseline")
	_expect(viewer.baseline_cached, "new baseline installed before signal")
	_expect(viewer.data.size() == BURST + 1, "reliable backlog and new room payload only")
	if viewer.data.size() != BURST + 1:
		return false
	for tick: int in BURST:
		_expect(rooms[tick] == first_room, "old payload remains in old room")
		_expect(viewer.senders[tick] == first.client.get_player_id(), "old sender")
		_expect(_tick_matches(viewer.data[tick], format_name, tick), "ordered reliable backlog")
	_expect(rooms.back() == second_room, "new payload uses new baseline")
	_expect(viewer.senders.back() == second.client.get_player_id(), "new sender")
	_expect(_tick_matches(viewer.data.back(), format_name, 900), "new payload")
	_expect(
		events[BURST + 1] == "left" and events[BURST + 2] == "joined",
		"terminal precedes replacement baseline"
	)
	_expect(
		(
			viewer.client.get_players().size() == 1
			and viewer.client.get_players()[0].id == second.client.get_player_id()
		),
		"new roster excludes old host"
	)
	_expect(first.client.ping() == OK, "old sender barrier")
	if not await _wait(func() -> bool: return first.pongs == 1, "old server publication processed"):
		return false
	_expect(viewer.client.leave_spectator() == OK, "leave second room")
	_expect(
		viewer.client.join_as_spectator(game, first.client.get_room_code(), "Viewer") == OK,
		"rejoin first room"
	)
	_expect(viewer.client.ping() == OK, "rejoin barrier send")
	if not await _wait(func() -> bool: return viewer.pongs == 2, "rejoin barrier"):
		return false
	_expect(viewer.baselines == 3 and viewer.left == 2, "rejoin terminal order")
	_expect(viewer.data.size() == BURST + 1, "rejoin invents no gameplay history")
	_send_tick(first, format_name, 901)
	if not await _wait(
		func() -> bool: return viewer.data.size() == BURST + 2, "fresh rejoin gameplay"
	):
		return false
	_expect(_tick_matches(viewer.data.back(), format_name, 901), "fresh payload after rejoin")
	_expect(
		viewer.client.get_room_id() == first_room and viewer.baseline_cached,
		"rejoin authoritative baseline"
	)
	if _failures.is_empty():
		print("LIVE_QUEUED_SWITCH_PASS v%d %s backlog=%d" % [version, format_name, BURST])
	return _failures.is_empty()


func _logged_in() -> bool:
	for seat: Seat in _seats:
		if not seat.authenticated or seat.protocol == null:
			return false
	return true


func _send_tick(seat: Seat, format_name: String, tick: int) -> void:
	if format_name == "json":
		_expect(seat.client.send_game_data({"tick": tick}) == OK, "JSON tick send")
	else:
		_expect(
			seat.client.send_game_data_binary(_msgpack({"tick": tick})) == OK, "binary tick send"
		)


func _tick_matches(value: Variant, format_name: String, tick: int) -> bool:
	if format_name == "json":
		return _same_payload(value, {"tick": tick})
	return value == _msgpack({"tick": tick})


func _direct_membership_case() -> bool:
	var host := _seat(3, "json", false, true)
	var peer := _seat(3, "json", false, true)
	var late := _seat(3, "json", false, true)
	if not await _wait(func() -> bool: return _logged_in(), "Direct membership login"):
		return false
	var game := "godot-direct-race-%d" % OS.get_process_id()
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "Direct race room"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(
		func() -> bool: return peer.joined and host.client.get_players().size() == 2,
		"Direct race peer"
	):
		return false
	_endpoint(host, "192.0.2.10", 7000)
	_endpoint(peer, "192.0.2.20", 8000)
	_expect(host.client.set_ready() == OK and peer.client.set_ready() == OK, "Direct race ready")
	if not await _wait(func() -> bool: return host.all_ready, "Direct race all ready"):
		return false
	_expect(host.client.start_game() == OK, "Direct race start")
	if not await _wait(
		func() -> bool: return host.plans.size() == 1 and peer.plans.size() == 1,
		"Direct race initial plans"
	):
		return false
	var selected: Seat = host if host.plans.back().host == host.client.get_player_id() else peer
	var observer: Seat = peer if selected == host else host
	var initial_generation: String = host.plans.back().generation
	var selected_id := selected.client.get_player_id()
	var snapshots: Array[Dictionary] = []
	observer.client.session_plan.connect(
		func(plan: SessionScript.SessionPlanInfo) -> void:
			var ids: Array[String] = []
			for player: TypesScript.PlayerInfo in observer.client.get_players():
				ids.append(player.id)
			snapshots.append({"plan": plan, "ids": ids})
	)
	_endpoint(selected, "192.0.2.31", 9031)
	_join(late, game, host.client.get_room_code())
	if not await _wait(
		func() -> bool:
			return (
				late.joined
				and observer.client.get_players().size() == 3
				and not late.plans.is_empty()
			),
		"join during endpoint update"
	):
		return false
	if not await _converged_plan([host, peer, late], selected_id, "192.0.2.31", 9031):
		return false
	var join_generation: String = host.plans.back().generation
	_expect(join_generation != initial_generation, "join overlap has fresh generation")
	_endpoint(selected, "192.0.2.32", 9032)
	_expect(late.client.leave_room() == OK, "leave during endpoint update")
	if not await _wait(
		func() -> bool:
			return (
				observer.client.get_players().size() == 2 and late.client.get_room_id().is_empty()
			),
		"leave applied"
	):
		return false
	if not await _converged_plan([host, peer], selected_id, "192.0.2.32", 9032):
		return false
	_expect(host.plans.back().generation != join_generation, "leave overlap has fresh generation")
	for snapshot: Dictionary in snapshots:
		var plan: SessionScript.SessionPlanInfo = snapshot["plan"]
		var ids: Array[String] = snapshot["ids"]
		_expect(ids.has(plan.host), "plan host belongs to current wire-order roster")
		for planned_peer: SessionScript.SessionPeerInfo in plan.peers:
			_expect(
				ids.has(planned_peer.player_id), "plan peer belongs to current wire-order roster"
			)
	_expect(observer.client.send_game_data({"after_overlap": true}) == OK, "overlap relay send")
	if not await _wait(func() -> bool: return selected.data.size() == 1, "overlap relay receipt"):
		return false
	_expect(_same_payload(selected.data[0], {"after_overlap": true}), "overlap relay payload")
	if _failures.is_empty():
		print("LIVE_DIRECT_MEMBERSHIP_PASS endpoint updates overlap join and leave")
	return _failures.is_empty()


func _converged_plan(seats: Array[Seat], host_id: String, address: String, port: int) -> bool:
	return await _wait(
		func() -> bool:
			var generation := ""
			for seat: Seat in seats:
				if seat.plans.is_empty():
					return false
				var plan: SessionScript.SessionPlanInfo = seat.plans.back()
				if plan.transport != SessionScript.TransportKind.DIRECT or plan.host != host_id:
					return false
				if (
					plan.direct_endpoint == null
					or plan.direct_endpoint.host != address
					or plan.direct_endpoint.port != port
				):
					return false
				if not generation.is_empty() and plan.generation != generation:
					return false
				generation = plan.generation
			return true,
		"shared Direct plan after membership overlap"
	)
