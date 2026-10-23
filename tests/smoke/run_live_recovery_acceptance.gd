extends "res://tests/smoke/run_live_server_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in spectator replay and Direct reconnect acceptance. See docs/testing.md.


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _run() -> void:
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			if await _spectator_recovery(version, format_name) != true:
				_failures.append("spectator recovery phase did not complete")
				_finish()
				return
			_close_seats()
	if await _direct_reconnect() != true:
		_failures.append("Direct reconnect phase did not complete")
	_finish()


func _spectator_recovery(version: int, format_name: String) -> bool:
	_case += 1
	var host := _seat(version, format_name, false)
	var peer := _seat(3, format_name, false)
	var viewer := _seat(version, format_name, false)
	var host_log := _history(host)
	var peer_log := _history(peer)
	var viewer_log := _history(viewer)
	if not await _wait(func() -> bool: return _logged_in(), "recovery logins"):
		return false
	if version == 3:
		_expect(viewer.protocol.capabilities.has("spectator_relay"), "live spectator capability")
	var game := "godot-recovery-%d-%d" % [OS.get_process_id(), _case]
	_join_with_authority(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "recovery room"):
		return false
	_join_with_authority(peer, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return peer.joined, "recovery peer"):
		return false
	var room_id := host.client.get_room_id()
	var room_code := host.client.get_room_code()
	var peer_id := peer.client.get_player_id()
	_expect(viewer.client.join_as_spectator(game, room_code, "Viewer") == OK, "recovery spectate")
	if not await _wait(func() -> bool: return viewer.baselines == 1, "recovery viewer baseline"):
		return false
	var viewer_id := viewer_log.spectator_id
	_expect(host.client.set_ready() == OK and peer.client.set_ready() == OK, "recovery readiness")
	if not await _wait(func() -> bool: return viewer.all_ready, "spectator readiness"):
		return false
	for player: TypesScript.PlayerInfo in viewer.client.get_players():
		_expect(player.is_ready, "spectator cached readiness")
	_expect(host.client.request_authority(false) == OK, "release authority")
	if not await _wait(
		func() -> bool: return viewer_log.authorities.has(""), "spectator sees vacant authority"
	):
		return false
	_expect(peer.client.request_authority(true) == OK, "transfer authority")
	if not await _wait(
		func() -> bool: return viewer_log.authorities.has(peer_id), "spectator authority transfer"
	):
		return false
	var token := peer_log.baseline.reconnection_token
	if token.is_empty():
		_failures.append("v3 replay actor has no reconnect credential")
		return false
	peer.client.close()
	if not await _wait(
		func() -> bool: return peer_log.closed == 1 and viewer_log.departures.has(peer_id),
		"spectator sees peer disconnect"
	):
		return false
	_expect(peer.client.reconnect(peer_id, room_id, token) == OK, "reconnect with live viewer")
	if not await _wait(
		func() -> bool: return peer_log.restored == 1 and viewer_log.returns == [peer_id],
		"live spectator peer return"
	):
		return false
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING,
		"peer return retains spectator role"
	)
	_expect(viewer.plans.is_empty(), "peer return has no spectator plan")
	_expect(peer_log.baseline.reconnection_token != token, "spectator recovery rotates credential")
	token = peer_log.baseline.reconnection_token
	peer.client.close()
	if not await _wait(
		func() -> bool: return peer_log.closed == 2 and viewer_log.departures.size() == 2,
		"second peer disconnect before detach"
	):
		return false
	_expect(viewer.client.leave_spectator() == OK, "detach while player absent")
	if not await _wait(
		func() -> bool: return viewer.left == 1 and host_log.detached.size() == 1,
		"live spectator detach"
	):
		return false
	_expect(
		viewer_log.terminals == [[room_id, room_code, TypesScript.SpectatorReason.VOLUNTARY_LEAVE]],
		"terminal identity and reason"
	)
	_expect(
		host_log.detached == [[viewer_id, TypesScript.SpectatorReason.VOLUNTARY_LEAVE]],
		"one live detach with reason"
	)
	_expect(host.client.get_spectators().is_empty(), "live spectator roster removed")
	_expect(viewer.client.get_room_id().is_empty(), "terminal clears viewer room")
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
		"terminal clears viewer role"
	)
	_expect(viewer.client.get("_context_auth_token") == "", "terminal clears retained identity")
	_expect(peer.client.reconnect(peer_id, room_id, token) == OK, "absent player reconnect")
	if not await _wait(func() -> bool: return peer_log.restored == 2, "replay baseline"):
		return false
	var departures: Array[TypesScript.DecodedEvent] = []
	for event: TypesScript.DecodedEvent in peer_log.missed:
		if event.signal_name == &"spectator_disconnected":
			departures.append(event)
	_expect(departures.size() == 1, "one decoded spectator detach in replay")
	if departures.size() == 1:
		_expect(departures[0].args[0] == viewer_id, "replay spectator identity")
		_expect(
			departures[0].args[1] == TypesScript.SpectatorReason.VOLUNTARY_LEAVE,
			"replay exit reason"
		)
		_expect(departures[0].args[2] == [], "replay terminal roster")
	_expect(peer_log.detached.is_empty(), "replay does not dispatch live detach signal")
	_expect(peer.client.get_spectators().is_empty(), "reconnect baseline excludes departed viewer")
	_expect(
		viewer.client.join_as_spectator(game, room_code, "Viewer again") == OK,
		"fresh spectator join"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 2, "fresh spectator baseline"):
		return false
	_expect(viewer.client.get_players().size() == 2, "fresh viewer receives restored roster")
	if format_name == "json":
		_expect(peer.client.send_game_data({"returned": true}) == OK, "returned JSON send")
	else:
		_expect(
			peer.client.send_game_data_binary(_msgpack({"returned": true})) == OK,
			"returned binary send"
		)
	if not await _wait(
		func() -> bool: return viewer.data.size() == 1, "returned player to viewer gameplay"
	):
		return false
	_expect(viewer.senders[0] == peer_id, "returned player sender identity")
	_expect(
		(
			_same_payload(viewer.data[0], {"returned": true})
			if format_name == "json"
			else viewer.data[0] == _msgpack({"returned": true})
		),
		"returned gameplay payload"
	)
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING,
		"gameplay retains spectator role"
	)
	_expect(viewer.plans.is_empty(), "viewer has no personalized plans")
	_expect(
		viewer.left == 1 and host_log.detached.size() == 1,
		"detach remains exactly once after reconnect"
	)
	if _failures.is_empty():
		print(
			(
				"LIVE_SPECTATOR_RECOVERY_PASS viewer=v%d actor=v3 %s authority readiness detach replay gameplay"
				% [version, format_name]
			)
		)
	return _failures.is_empty()


func _direct_reconnect() -> bool:
	var first := _seat(3, "json", false, true)
	var second := _seat(3, "json", false, true)
	var first_log := _history(first)
	var second_log := _history(second)
	if not await _wait(func() -> bool: return _logged_in(), "Direct reconnect login"):
		return false
	var game := "godot-direct-recovery-%d" % OS.get_process_id()
	_join(first, game, "")
	if not await _wait(func() -> bool: return first.joined, "Direct recovery room"):
		return false
	_join(second, game, first.client.get_room_code())
	if not await _wait(func() -> bool: return second.joined, "Direct recovery peer"):
		return false
	_endpoint(first, "192.0.2.10", 7000)
	_endpoint(second, "192.0.2.20", 8000)
	_expect(first.client.set_ready() == OK and second.client.set_ready() == OK, "Direct ready")
	if not await _wait(func() -> bool: return first.all_ready, "Direct all ready"):
		return false
	_expect(first.client.start_game() == OK, "Direct recovery start")
	if not await _wait(
		func() -> bool: return first.plans.size() == 1 and second.plans.size() == 1,
		"Direct initial plans"
	):
		return false
	var host: Seat = first if first.plans.back().host == first.client.get_player_id() else second
	var peer: Seat = second if host == first else first
	var peer_history: History = second_log if host == first else first_log
	var host_log: History = first_log if host == first else second_log
	var id := peer.client.get_player_id()
	var room := peer.client.get_room_id()
	for cycle: int in 2:
		var token := peer_history.baseline.reconnection_token
		var generation: String = host.plans.back().generation
		peer.plans.clear()
		peer.client.close()
		if not await _wait(
			func() -> bool:
				return peer_history.closed == cycle + 1 and host_log.departures.size() == cycle + 1,
			"Direct peer disconnected"
		):
			return false
		var address := "192.0.2.%d" % (40 + cycle)
		var port := 9040 + cycle
		_endpoint(host, address, port)
		_expect(peer.client.reconnect(id, room, token) == OK, "Direct overlap reconnect send")
		if not await _wait(
			func() -> bool: return peer_history.restored == cycle + 1 and not peer.plans.is_empty(),
			"Direct reconnect baseline and fresh plan"
		):
			return false
		if not await _wait(
			func() -> bool: return _matching_direct(host, peer, address, port),
			"Direct reconnect endpoint convergence"
		):
			return false
		_expect(host.plans.back().generation != generation, "Direct recovery fresh generation")
		_expect(
			peer_history.baseline.reconnection_token != token,
			"reconnect rotates current credential"
		)
		_expect(peer.client.get_players().size() == 2, "reconnecting peer baseline has full roster")
		_expect(peer_history.plan_after_baseline, "live plan follows reconnect baseline")
		_expect(peer.client.send_game_data({"cycle": cycle}) == OK, "reconnected relay send")
		if not await _wait(
			func() -> bool: return host.data.size() == cycle + 1, "reconnected relay receipt"
		):
			return false
		_expect(_same_payload(host.data.back(), {"cycle": cycle}), "reconnected relay payload")
	if _failures.is_empty():
		print("LIVE_DIRECT_RECONNECT_PASS two credential rotations endpoint overlap relay gameplay")
	return _failures.is_empty()


func _matching_direct(host: Seat, peer: Seat, address: String, port: int) -> bool:
	if host.plans.is_empty() or peer.plans.is_empty():
		return false
	for seat: Seat in [host, peer]:
		var plan: SessionScript.SessionPlanInfo = seat.plans.back()
		if plan.transport != SessionScript.TransportKind.DIRECT or plan.direct_endpoint == null:
			return false
		if (
			plan.host != host.client.get_player_id()
			or plan.direct_endpoint.host != address
			or plan.direct_endpoint.port != port
		):
			return false
	return host.plans.back().generation == peer.plans.back().generation


func _join_with_authority(seat: Seat, game: String, code: String) -> void:
	var params := ClientScript.JoinRoomParams.new()
	params.game_name = game
	params.player_name = "Recovery%d" % _seats.find(seat)
	params.room_code = code
	params.max_players = 4
	params.supports_authority = true
	_expect(seat.client.join_room(params) == OK, "authority room join")


func _logged_in() -> bool:
	for seat: Seat in _seats:
		if not seat.authenticated or seat.protocol == null:
			return false
	return true


func _history(seat: Seat) -> History:
	var history := History.new()
	history.attach(seat, self)
	seat.client.reconnection_failed.connect(
		func(message: String, _code: int) -> void: _failures.append(message)
	)
	return history


class History:
	extends RefCounted
	var baseline: TypesScript.RoomJoinedInfo = null
	var spectator_id := ""
	var authorities: Array[String] = []
	var departures: Array[String] = []
	var returns: Array[String] = []
	var terminals: Array[Array] = []
	var detached: Array[Array] = []
	var missed: Array[TypesScript.DecodedEvent] = []
	var restored := 0
	var closed := 0
	var plan_after_baseline := true

	func attach(seat: Seat, runner: SceneTree) -> void:
		seat.client.room_joined.connect(
			func(info: TypesScript.RoomJoinedInfo) -> void: baseline = info
		)
		seat.client.spectator_joined.connect(
			func(info: TypesScript.SpectatorJoinedInfo) -> void: spectator_id = info.spectator_id
		)
		seat.client.authority_changed.connect(
			func(id: String, _you: bool) -> void:
				authorities.append(id)
				for player: TypesScript.PlayerInfo in seat.client.get_players():
					runner.call(
						"_expect",
						player.is_authority == (player.id == id),
						"authority cached before signal"
					)
		)
		seat.client.player_left.connect(func(id: String) -> void: departures.append(id))
		seat.client.player_reconnected.connect(func(id: String) -> void: returns.append(id))
		seat.client.spectator_left.connect(
			func(
				room: String, code: String, reason: int, _current: Array[TypesScript.SpectatorInfo]
			) -> void:
				terminals.append([room, code, reason])
				runner.call(
					"_expect",
					seat.client.get_room_id().is_empty(),
					"terminal clears room before signal"
				)
				runner.call(
					"_expect",
					seat.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
					"terminal clears role before signal"
				)
		)
		seat.client.spectator_disconnected.connect(
			func(id: String, reason: int, _current: Array[TypesScript.SpectatorInfo]) -> void:
				detached.append([id, reason])
				for spectator: TypesScript.SpectatorInfo in seat.client.get_spectators():
					runner.call(
						"_expect", spectator.id != id, "detach removes viewer before room signal"
					)
		)
		seat.client.disconnected.connect(func(_code: int, _reason: String) -> void: closed += 1)
		seat.client.reconnected.connect(
			func(info: TypesScript.RoomJoinedInfo, replay: Array[TypesScript.DecodedEvent]) -> void:
				baseline = info
				missed.assign(replay)
				restored += 1
		)
		seat.client.session_plan.connect(
			func(_plan: SessionScript.SessionPlanInfo) -> void:
				if closed > 0 and restored < closed:
					plan_after_baseline = false
		)
