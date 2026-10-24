extends "res://tests/smoke/run_controlled_lifecycle_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in server queue pressure for #368. See docs/testing.md.

var _writer_barrier := ""


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
	for delivery: String in ["latest", "volatile"]:
		if await _pressure(delivery, 3, "json", false) != true:
			_failures.append("server pressure phase did not complete: " + delivery)
			_finish()
			return
		_close_seats()
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack", "rkyv", "protobuf"]:
			if version == 2 and format_name in ["rkyv", "protobuf"]:
				continue
			for decoded: bool in [false, true] if format_name == "message_pack" else [false]:
				if await _pressure("reliable", version, format_name, decoded) != true:
					_failures.append("reliable pressure phase did not complete")
					_finish()
					return
				_close_seats()
	_finish()


func _pressure(delivery: String, version: int, format_name: String, decoded: bool) -> bool:
	_case += 1
	var host := _seat(3, format_name, false)
	var viewer := _seat(version, format_name, decoded)
	var viewer_log := _history(viewer)
	if not await _wait(func() -> bool: return _logged_in(), "pressure login"):
		return false
	var game := "godot-pressure-%d-%d" % [OS.get_process_id(), _case]
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "pressure room"):
		return false
	if version == 3:
		_expect(
			viewer.protocol.capabilities.has("spectator_relay"), "pressure spectator capability"
		)
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Viewer") == OK,
		"pressure spectator"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "pressure baseline"):
		return false
	var reports: Array[SessionScript.DeliveryReportInfo] = []
	var trace: Array[String] = []
	var closed: Array[int] = []
	viewer.client.delivery_report.connect(
		func(report: SessionScript.DeliveryReportInfo) -> void:
			reports.append(report)
			trace.append("report")
	)
	viewer.client.game_data_received.connect(
		func(_sender: String, _data: Variant) -> void: trace.append("data")
	)
	viewer.client.disconnected.connect(
		func(code: int, _reason: String) -> void: closed.append(code)
	)
	_writer_barrier = "writer-" + viewer_log.spectator_id
	_arm(_writer_barrier)
	_expect(viewer.client.ping() == OK, "wake spectator writer")
	if not await _wait(func() -> bool: return _reached(_writer_barrier), "server writer paused"):
		return false
	var count := 5 if delivery == "reliable" else 8
	for tick: int in count:
		if delivery == "reliable":
			_expect(
				_send_reliable_payload(host, format_name, {"tick": tick}) == OK,
				"public reliable pressure send"
			)
		else:
			var data: Dictionary = {"data": {"tick": tick}, "class": delivery}
			if delivery == "latest":
				data["key"] = 7
			_expect(
				(
					host.client.transport.send_text(
						JSON.stringify({"type": "GameData", "data": data})
					)
					== OK
				),
				"raw v3 delivery fixture send"
			)
	_expect(host.client.ping() == OK, "pressure ingress fence")
	if not await _wait(
		func() -> bool: return host.pongs == 1, "all ingress processed under pressure"
	):
		return false
	_expect(viewer.data.is_empty(), "no data escaped the server queue barrier")
	_write(_writer_barrier + ".release")
	if delivery == "reliable":
		if not await _wait(
			func() -> bool: return not closed.is_empty(), "reliable slow consumer closes"
		):
			return false
		_expect(closed == [4002], "reliable queue overflow closes spectator once with 4002")
		_expect(viewer.client.get_room_id().is_empty(), "slow consumer clears spectator state")
		_expect(reports.is_empty(), "reliable overflow invents no lossy gap report")
		if not await _wait(
			func() -> bool: return host.client.get_spectators().is_empty(),
			"slow consumer removed from server roster"
		):
			return false
		_expect(
			viewer.client.connect_to_server("%s/v%d/ws" % [_base_url, version]) == OK,
			"fresh spectator connection after overflow"
		)
		viewer.authenticated = false
		if not await _wait(
			func() -> bool: return viewer.authenticated, "overflow fresh authentication"
		):
			return false
		_expect(
			viewer.client.join_as_spectator(game, host.client.get_room_code(), "Recovered") == OK,
			"readmit after overflow"
		)
		if not await _wait(func() -> bool: return viewer.baselines == 2, "overflow fresh baseline"):
			return false
		var prior := viewer.data.size()
		_expect(
			_send_reliable_payload(host, format_name, {"fresh": true}) == OK,
			"recovered reliable send"
		)
		if not await _wait(
			func() -> bool: return viewer.data.size() == prior + 1, "recovered spectator gameplay"
		):
			return false
		var expected: Variant = null
		if format_name == "json" or decoded:
			expected = {"fresh": true}
		else:
			expected = _msgpack({"fresh": true})
		_expect(viewer.data.back() == expected, "recovered spectator exact payload")
	else:
		var expected_count := 1 if delivery == "latest" else 4
		if not await _wait(
			func() -> bool: return viewer.data.size() == expected_count and not reports.is_empty(),
			"lossy outcomes and typed report"
		):
			return false
		_expect(viewer.client.ping() == OK, "pressure egress fence")
		if not await _wait(func() -> bool: return viewer.pongs == 2, "pressure egress drained"):
			return false
		_expect(viewer.data.size() == expected_count, "exact lossy delivery count")
		_expect(trace[0] == "report", "omission report precedes surviving gameplay")
		var omitted: Array[int] = []
		for report: SessionScript.DeliveryReportInfo in reports:
			for gap: SessionScript.DeliveryGapInfo in report.gaps:
				_expect(
					gap.from_player == host.client.get_player_id() and gap.epoch > 0,
					"exact gap sender and epoch"
				)
				_expect(
					(
						gap.reason
						== (
							SessionScript.DeliveryGapReason.LATEST_SUPERSEDED
							if delivery == "latest"
							else SessionScript.DeliveryGapReason.VOLATILE_DROPPED
						)
					),
					"exact gap reason"
				)
				for seq: int in range(gap.from_seq, gap.to_seq + 1):
					_expect(not omitted.has(seq), "no duplicate omission range")
					omitted.append(seq)
		var latest_report: SessionScript.DeliveryReportInfo = reports.back()
		var counters := latest_report.counters_for(delivery)
		_expect(counters != null, "typed pressure counters exist")
		if counters != null:
			_expect(
				(
					counters.get_count("superseded" if delivery == "latest" else "dropped")
					== omitted.size()
				),
				"cumulative omission counter matches exact ranges"
			)
		omitted.sort()
		_expect(
			omitted == ([1, 2, 3, 4, 5, 6, 7] if delivery == "latest" else [1, 2, 3, 4]),
			"exact omitted sequence set"
		)
		for index: int in viewer.data.size():
			_expect(
				_same_payload(
					viewer.data[index], {"tick": 7 if delivery == "latest" else index + 4}
				),
				"latest final value or newest volatile FIFO payload"
			)
		_expect(closed.is_empty(), "lossy pressure keeps spectator connected")
		_expect(
			viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING,
			"lossy pressure preserves spectator role"
		)
		_expect(host.client.send_game_data({"fresh": true}) == OK, "fresh reliable traffic")
		if not await _wait(
			func() -> bool: return viewer.data.size() == expected_count + 1,
			"fresh reliable receipt after pressure"
		):
			return false
		_expect(_same_payload(viewer.data.back(), {"fresh": true}), "fresh payload after pressure")
	_expect(host.client.get_room_id() != "", "pressure preserves sender membership")
	if _failures.is_empty():
		print(
			(
				"LIVE_DELIVERY_PRESSURE_PASS v%d %s decoded=%s %s exact outcomes"
				% [version, format_name, decoded, delivery]
			)
		)
	return _failures.is_empty()


func _send_reliable_payload(seat: Seat, format_name: String, payload: Dictionary) -> Error:
	if format_name == "json":
		return seat.client.send_game_data(payload)
	return seat.client.send_game_data_binary(_msgpack(payload))


func _finish() -> void:
	if not _writer_barrier.is_empty():
		_write(_writer_barrier + ".release")
	super._finish()
