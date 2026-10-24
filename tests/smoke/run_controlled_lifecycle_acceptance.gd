extends "res://tests/smoke/run_live_recovery_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in local server barriers for #356, #358 and #367. See docs/testing.md.

var _barrier_dir := ""


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	_barrier_dir = OS.get_environment("SF_GODOT_BARRIER_DIR")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _run() -> void:
	if _barrier_dir.is_empty() or not DirAccess.dir_exists_absolute(_barrier_dir):
		_failures.append("SF_GODOT_BARRIER_DIR must name the isolated server barrier directory")
		_finish()
		return
	for first: bool in [true, false]:
		if await _concurrent_reports(first) != true:
			_failures.append("concurrent reports did not complete")
			_finish()
			return
		_close_seats()
	if await _direct_commit_overlap() != true:
		_failures.append("Direct commit overlap did not complete")
		_finish()
		return
	_close_seats()
	for version: int in [2, 3]:
		_arm("detach-error")
		if await _spectator_recovery(version, "json") != true:
			_failures.append("registration retry recovery did not complete")
			_finish()
			return
		_expect(_reached("detach-error"), "first registration failure injected")
		_close_seats()
		if await _detach_exhaustion(version) != true:
			_failures.append("registration exhaustion did not complete")
			_finish()
			return
		_close_seats()
	_finish()


func _concurrent_reports(first: bool) -> bool:
	var reporter := _seat(3, "json", false, true)
	var observer := _seat(3, "json", false)
	var legacy := _seat(2, "json", false)
	if not await _wait(func() -> bool: return _logged_in(), "concurrent report logins"):
		return false
	var game := "godot-concurrent-%d-%s" % [OS.get_process_id(), first]
	_join(reporter, game, "")
	if not await _wait(func() -> bool: return reporter.joined, "reporter room"):
		return false
	_join(observer, game, reporter.client.get_room_code())
	_join(legacy, game, reporter.client.get_room_code())
	if not await _wait(
		func() -> bool: return observer.joined and legacy.joined, "concurrent observers"
	):
		return false
	var reports: Array[Array] = []
	var legacy_reports: Array[Array] = []
	observer.client.peer_transport_status.connect(
		func(peer_id: String, transport_kind: int, connected: bool) -> void:
			reports.append([peer_id, transport_kind, connected])
	)
	legacy.client.peer_transport_status.connect(
		func(peer_id: String, transport_kind: int, connected: bool) -> void:
			legacy_reports.append([peer_id, transport_kind, connected])
	)
	for name: String in ["report-done-true", "report-done-false"]:
		_clear(name)
	_arm("report")
	var kind := SessionScript.TransportKind.DIRECT
	_expect(reporter.client.send_transport_status(kind, first) == OK, "first report send")
	if not await _wait(func() -> bool: return _reached("report"), "first report accepted and held"):
		return false
	_arm("report-enter")
	_expect(reporter.client.send_transport_status(kind, not first) == OK, "concurrent report send")
	if not await _wait(func() -> bool: return _reached("report-enter"), "second handler entered"):
		return false
	_expect(reports.is_empty(), "no report published while first queue admission held")
	_expect(not _reached("report-done-true"), "true report has not completed")
	_expect(not _reached("report-done-false"), "false report has not completed")
	_write("report.release")
	if not await _wait(
		func() -> bool:
			return (
				_reached("report-done-true")
				and _reached("report-done-false")
				and reports.size() == 2
			),
		"both concurrent reports admitted"
	):
		return false
	var id := reporter.client.get_player_id()
	_expect(reports == [[id, kind, first], [id, kind, not first]], "typed acceptance order")
	_expect(legacy_reports.is_empty(), "v2 observer excluded from concurrent v3 reports")
	_expect(observer.client.get_players().size() == 3, "concurrent reports preserve roster")
	_arm("report-duplicate")
	_expect(reporter.client.send_transport_status(kind, not first) == OK, "duplicate report send")
	if not await _wait(func() -> bool: return _reached("report-duplicate"), "duplicate processed"):
		return false
	_expect(reporter.client.send_game_data({"after_reports": first}) == OK, "report gameplay")
	if not await _wait(
		func() -> bool: return observer.data.size() == 1 and legacy.data.size() == 1,
		"gameplay after concurrent reports"
	):
		return false
	_expect(_same_payload(observer.data[0], {"after_reports": first}), "v3 gameplay payload")
	_expect(_same_payload(legacy.data[0], {"after_reports": first}), "v2 gameplay payload")
	_expect(reports.size() == 2, "duplicate concurrent-dispatch report stays silent")
	if _failures.is_empty():
		print("LIVE_CONCURRENT_REPORTS_PASS first=%s state checked under report lock" % first)
	return _failures.is_empty()


func _direct_commit_overlap() -> bool:
	var first := _seat(3, "json", false, true)
	var second := _seat(3, "json", false, true)
	var late := _seat(3, "json", false, true)
	if not await _wait(func() -> bool: return _logged_in(), "controlled Direct login"):
		return false
	var game := "godot-commit-%d" % OS.get_process_id()
	_join(first, game, "")
	if not await _wait(func() -> bool: return first.joined, "controlled Direct room"):
		return false
	_join(second, game, first.client.get_room_code())
	if not await _wait(func() -> bool: return second.joined, "controlled Direct peer"):
		return false
	_endpoint(first, "192.0.2.10", 7000)
	_endpoint(second, "192.0.2.20", 8000)
	_expect(first.client.set_ready() == OK and second.client.set_ready() == OK, "controlled ready")
	if not await _wait(func() -> bool: return first.all_ready, "controlled all ready"):
		return false
	_expect(first.client.start_game() == OK, "controlled start")
	if not await _wait(
		func() -> bool: return first.plans.size() == 1 and second.plans.size() == 1,
		"controlled initial plan"
	):
		return false
	var host: Seat = first if first.plans.back().host == first.client.get_player_id() else second
	var observer: Seat = second if host == first else first
	var observed: Array[Dictionary] = []
	observer.client.session_plan.connect(
		func(plan: SessionScript.SessionPlanInfo) -> void:
			var ids: Array[String] = []
			for player: TypesScript.PlayerInfo in observer.client.get_players():
				ids.append(player.id)
			observed.append({"plan": plan, "ids": ids})
	)
	for leaving: bool in [false, true]:
		var address := "192.0.2.32" if leaving else "192.0.2.31"
		var port := 9032 if leaving else 9031
		var prior: String = observer.plans.back().generation
		var count := observer.plans.size()
		_arm("direct")
		_endpoint(host, address, port)
		if not await _wait(func() -> bool: return _reached("direct"), "Direct commit held"):
			return false
		var entrant := "leave-enter" if leaving else "join-enter"
		_arm(entrant)
		if leaving:
			_expect(late.client.leave_room() == OK, "leave during held commit")
		else:
			_join(late, game, first.client.get_room_code())
		if not await _wait(func() -> bool: return _reached(entrant), "membership lane entered"):
			return false
		_expect(observer.plans.size() == count, "uncommitted endpoint not published")
		_expect(observer.client.get_players().size() == (3 if leaving else 2), "membership held")
		_write("direct.release")
		if not await _wait(
			func() -> bool:
				return (
					observer.client.get_players().size() == (2 if leaving else 3)
					and (
						late.client.get_room_id().is_empty()
						if leaving
						else not late.plans.is_empty()
					)
					and _matching_direct(host, observer, address, port)
				),
			"controlled commit and membership converge"
		):
			return false
		_expect(observer.plans.back().generation != prior, "controlled fresh generation")
		if not leaving:
			_expect(_matching_direct(host, late, address, port), "late member current endpoint")
	for snapshot: Dictionary in observed:
		var plan: SessionScript.SessionPlanInfo = snapshot["plan"]
		var ids: Array[String] = snapshot["ids"]
		_expect(ids.has(plan.host), "controlled plan host in signal-time roster")
		for peer: SessionScript.SessionPeerInfo in plan.peers:
			_expect(ids.has(peer.player_id), "controlled plan peer in signal-time roster")
	_expect(observer.client.send_game_data({"after_commit": true}) == OK, "controlled relay send")
	if not await _wait(func() -> bool: return host.data.size() == 1, "controlled relay receipt"):
		return false
	_expect(_same_payload(host.data[0], {"after_commit": true}), "controlled relay payload")
	if _failures.is_empty():
		print("LIVE_DIRECT_COMMIT_PASS forced join and leave at metadata commit")
	return _failures.is_empty()


func _detach_exhaustion(version: int) -> bool:
	var host := _seat(version, "json", false)
	var peer := _seat(3, "json", false)
	var viewer := _seat(version, "json", false)
	var host_log := _history(host)
	var viewer_log := _history(viewer)
	var closes: Array[Array] = []
	viewer.client.disconnected.connect(
		func(code: int, reason: String) -> void: closes.append([code, reason])
	)
	if not await _wait(func() -> bool: return _logged_in(), "exhaustion logins"):
		return false
	var game := "godot-exhaust-%d-%d" % [OS.get_process_id(), version]
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "exhaustion room"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return peer.joined, "exhaustion peer"):
		return false
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Viewer") == OK,
		"exhaustion spectate"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "exhaustion baseline"):
		return false
	var viewer_id := viewer_log.spectator_id
	_arm("detach-error")
	_arm("detach-retry-panic")
	_expect(viewer.client.leave_spectator() == OK, "exhaustion leave")
	if not await _wait(
		func() -> bool: return viewer_log.closed == 1 and host_log.detached.size() == 1,
		"exhausted registration closes and notifies room"
	):
		return false
	_expect(_reached("detach-error"), "exhaustion first publication failure injected")
	_expect(_reached("detach-retry-panic"), "retry panic injected")
	_expect(closes == [[1000, "unregistered"]], "exhaustion close code and reason exactly once")
	_expect(viewer.left == 0, "unregistered generation sends no terminal acknowledgement")
	_expect(viewer.client.get_room_id().is_empty(), "exhaustion clears room")
	_expect(viewer.client.get("_context_auth_token") == "", "exhaustion clears retained identity")
	_expect(host.client.get_spectators().is_empty(), "exhaustion removes spectator roster")
	_expect(
		host_log.detached == [[viewer_id, TypesScript.SpectatorReason.VOLUNTARY_LEAVE]],
		"exhaustion preserves exactly one room notification and reason"
	)
	_expect(host.client.get_room_id() != "", "exhaustion preserves player session")
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.UNAUTHENTICATED,
		"exhaustion clears spectator role"
	)
	_expect(
		viewer.client.connect_to_server("%s/v%d/ws" % [_base_url, version]) == OK,
		"fresh connection after exhaustion"
	)
	if not await _wait(
		func() -> bool:
			return viewer.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
		"fresh authentication after exhaustion"
	):
		return false
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Fresh viewer") == OK,
		"fresh spectator admission after exhaustion"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 2, "fresh exhaustion baseline"):
		return false
	_expect(viewer_log.spectator_id != viewer_id, "fresh viewer has new identity")
	_expect(viewer.baseline_cached, "fresh exhaustion baseline installed before signal")
	_expect(host.client.send_game_data({"after_exhaustion": true}) == OK, "exhaustion gameplay")
	if not await _wait(
		func() -> bool: return peer.data.size() == 1 and viewer.data.size() == 1,
		"player and fresh spectator gameplay after exhaustion"
	):
		return false
	_expect(_same_payload(peer.data[0], {"after_exhaustion": true}), "surviving player gameplay")
	_expect(_same_payload(viewer.data[0], {"after_exhaustion": true}), "fresh spectator gameplay")
	_expect(host_log.detached.size() == 1 and viewer.left == 0, "exhaustion remains exactly once")
	if _failures.is_empty():
		print("LIVE_DETACH_EXHAUSTION_PASS v%d retry panic close and room notification" % version)
	return _failures.is_empty()


func _finish() -> void:
	if not _barrier_dir.is_empty() and DirAccess.dir_exists_absolute(_barrier_dir):
		_write("report.release")
		_write("direct.release")
	super._finish()


func _path(name: String) -> String:
	return _barrier_dir.path_join(name)


func _write(name: String) -> void:
	var file := FileAccess.open(_path(name), FileAccess.WRITE)
	if file == null:
		_failures.append("cannot write barrier " + name)
		return
	file.store_string("ready")
	file.close()


func _clear(name: String) -> void:
	for suffix: String in [".arm", ".reached", ".release"]:
		if FileAccess.file_exists(_path(name + suffix)):
			_expect(DirAccess.remove_absolute(_path(name + suffix)) == OK, "clear barrier")


func _arm(name: String) -> void:
	_clear(name)
	_write(name + ".arm")


func _reached(name: String) -> bool:
	return FileAccess.file_exists(_path(name + ".reached"))
