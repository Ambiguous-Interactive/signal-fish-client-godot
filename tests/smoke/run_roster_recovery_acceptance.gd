extends "res://tests/smoke/run_live_recovery_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in full-roster acceptance for #374. Requires server b264ec7 or newer.


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _run() -> void:
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			for decoded: bool in [false, true] if format_name == "message_pack" else [false]:
				if await _roster_recovery(version, format_name, decoded) != true:
					_failures.append("roster history did not complete: v%d" % version)
				_close_seats()
	_finish()


func _roster_recovery(version: int, format_name: String, decoded: bool) -> bool:
	_case += 1
	var host := _seat(version, format_name, decoded)
	var actor := _seat(3, format_name, false)
	var viewer := _seat(version, format_name, decoded)
	var late := _seat(version, format_name, decoded)
	var actor_log := _history(actor)
	var host_log := _history(host)
	var viewer_log := _history(viewer)
	var late_log := _history(late)
	if not await _wait(func() -> bool: return _logged_in(), "roster login"):
		return false
	var game := "godot-roster-%d-%d" % [OS.get_process_id(), _case]
	_join_with_authority(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "roster room"):
		return false
	_join_with_authority(actor, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return actor.joined, "roster actor"):
		return false
	var id := actor.client.get_player_id()
	var room := actor.client.get_room_id()
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Incumbent") == OK,
		"incumbent observer"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "incumbent baseline"):
		return false
	_expect(host.client.set_ready() == OK and actor.client.set_ready() == OK, "roster readiness")
	if not await _wait(func() -> bool: return viewer.all_ready, "roster ready flags"):
		return false
	_expect(host.client.request_authority(false) == OK, "release roster authority")
	if not await _wait(
		func() -> bool: return viewer_log.authorities.has(""), "vacant roster authority"
	):
		return false
	_expect(actor.client.request_authority(true) == OK, "actor takes roster authority")
	if not await _wait(
		func() -> bool: return viewer_log.authorities.has(id), "actor roster authority"
	):
		return false
	var callbacks: Array[Array] = []
	var joins: Array[String] = []
	for observer: Seat in [host, viewer, late]:
		observer.client.player_joined.connect(
			func(player: TypesScript.PlayerInfo) -> void: joins.append(player.id)
		)
		observer.client.player_reconnected.connect(
			func(player_id: String) -> void:
				var player := _find_player(observer, player_id)
				callbacks.append(
					[_seats.find(observer), player.raw.duplicate(true) if player != null else {}]
				)
		)
	for cycle: int in 2:
		var token := actor_log.baseline.reconnection_token
		actor.client.close()
		if not await _wait(
			func() -> bool:
				return (
					host_log.departures.size() == cycle + 1
					and viewer_log.departures.size() == cycle + 1
				),
			"roster disconnect published"
		):
			return false
		_expect(
			_find_player(host, id) == null and _find_player(viewer, id) == null,
			"disconnect removes live actor"
		)
		if cycle == 0:
			_expect(
				late.client.join_as_spectator(game, host.client.get_room_code(), "Late") == OK,
				"observer joins during absence"
			)
			if not await _wait(
				func() -> bool: return late.baselines == 1, "late observer baseline"
			):
				return false
			_expect(_find_player(late, id) == null, "late observer never saw absent metadata")
		_expect(actor.client.reconnect(id, room, token) == OK, "roster actor reconnect")
		if not await _wait(
			func() -> bool:
				return (
					actor_log.restored == cycle + 1
					and host_log.returns.size() == cycle + 1
					and viewer_log.returns.size() == cycle + 1
					and late_log.returns.size() == cycle + 1
				),
			"roster reconnect notifications"
		):
			return false
		var expected := _find_player(actor, id)
		if expected == null:
			_failures.append("authoritative reconnect baseline omitted actor")
			return false
		for observer: Seat in [host, viewer, late]:
			var restored := _find_player(observer, id)
			_expect(
				restored != null,
				(
					"v%d cycle%d observer%d restores full roster"
					% [version, cycle, _seats.find(observer)]
				)
			)
			if restored != null:
				_expect(
					(
						restored.name == expected.name
						and restored.is_ready == expected.is_ready
						and restored.is_authority == expected.is_authority
					),
					"restored name readiness and authority match current baseline"
				)
			_expect(
				observer.client.get_players().size() == 2, "restored roster has exactly two players"
			)
		_expect(callbacks.size() == (cycle + 1) * 3, "exactly one reconnect callback per observer")
		for row: Array in callbacks.slice(cycle * 3, (cycle + 1) * 3):
			var metadata: Dictionary = row[1]
			_expect(not metadata.is_empty(), "full metadata cached before reconnect callback")
			if not metadata.is_empty():
				_expect(
					(
						metadata.get("name") == expected.name
						and metadata.get("is_ready") == expected.is_ready
						and metadata.get("is_authority") == expected.is_authority
					),
					"current flags cached before reconnect callback"
				)
		var payload := {"cycle": cycle}
		var error := (
			actor.client.send_game_data(payload)
			if format_name == "json"
			else actor.client.send_game_data_binary(_msgpack(payload))
		)
		_expect(error == OK, "roster recovery gameplay")
		if not await _wait(
			func() -> bool:
				return viewer.data.size() == cycle + 1 and late.data.size() == cycle + 1,
			"roster recovery live gameplay"
		):
			return false
		for observer: Seat in [viewer, late]:
			if format_name == "json" or decoded:
				_expect(_same_payload(observer.data[cycle], payload), "exact recovered gameplay")
			else:
				_expect(observer.data[cycle] == _msgpack(payload), "exact raw recovered gameplay")
		_expect(joins.is_empty(), "reconnect emits no synthetic player join")
		_expect(
			(
				viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING
				and late.client.get_session_state() == ClientScript.SessionState.SPECTATING
			),
			"roster recovery preserves observer role"
		)
	_expect(actor.client.leave_room() == OK, "actor terminal leave")
	if not await _wait(
		func() -> bool:
			return (
				host_log.departures.size() == 3
				and viewer_log.departures.size() == 3
				and late_log.departures.size() == 2
			),
		"terminal leave publication"
	):
		return false
	for observer: Seat in [host, viewer, late]:
		_expect(_find_player(observer, id) == null, "terminal leave removes actor")
	print(
		(
			"LIVE_ROSTER_HISTORY v%d %s decoded=%s two cycles seated incumbent and late spectators"
			% [version, format_name, decoded]
		)
	)
	return true


func _find_player(seat: Seat, id: String) -> TypesScript.PlayerInfo:
	for player: TypesScript.PlayerInfo in seat.client.get_players():
		if player.id == id:
			return player
	return null
