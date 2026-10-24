extends "res://tests/smoke/run_live_recovery_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in #357 residue-seam acceptance. See docs/testing.md.

const Errors = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")

var _fixture_dir := ""


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	_fixture_dir = OS.get_environment("SF_GODOT_EXPIRY_DIR")
	if _fixture_dir.is_empty():
		_failures.append("SF_GODOT_EXPIRY_DIR is required")
		_finish()
		return
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _run() -> void:
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			if await _cleanup_history(version, format_name) != true:
				_failures.append("expired cleanup history did not complete")
				_finish()
				return
			_close_seats()
	_finish()


func _cleanup_history(version: int, format_name: String) -> bool:
	_case += 1
	for name: String in ["prepared", "cleaned", "candidates.json"]:
		if FileAccess.file_exists(_fixture_dir.path_join(name)):
			_expect(
				DirAccess.remove_absolute(_fixture_dir.path_join(name)) == OK,
				"clear fixture result"
			)
	var host := _seat(version, format_name, format_name == "message_pack")
	var actor := _seat(3, format_name, false)
	var host_log := _history(host)
	var actor_log := History.new()
	actor_log.attach(actor, self)
	var refused: Array[int] = []
	actor.client.reconnection_failed.connect(
		func(_reason: String, code: int) -> void: refused.append(code)
	)
	if not await _wait(func() -> bool: return _logged_in(), "cleanup login"):
		return false
	var game := "godot-expiry-%d-%d" % [OS.get_process_id(), _case]
	_join_with_authority(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "cleanup room"):
		return false
	var room := host.client.get_room_id()
	var room_code := host.client.get_room_code()
	_join_with_authority(actor, game, room_code)
	if not await _wait(func() -> bool: return actor.joined, "old membership"):
		return false
	var id := actor.client.get_player_id()
	var old_token := actor_log.baseline.reconnection_token
	_expect(not old_token.is_empty(), "old membership credential exists")
	_arm("prepare.arm")
	_expect(actor.client.ping() == OK, "capture expired pending candidate")
	if not await _wait(
		func() -> bool: return actor.pongs == 1 and actor.client.get_room_id().is_empty(),
		"candidate snapshot before fresh admission"
	):
		return false
	_expect(
		FileAccess.file_exists(_fixture_dir.path_join("prepared")),
		"server captured a real expired candidate"
	)
	actor.joined = false
	_join_with_authority(actor, game, room_code)
	if not await _wait(func() -> bool: return actor.joined, "fresh same-room admission"):
		return false
	_expect(actor.client.get_player_id() == id, "fresh admission keeps socket identity")
	_expect(actor.client.get_room_id() == room, "fresh admission uses same room")
	var token := actor_log.baseline.reconnection_token
	_expect(not token.is_empty() and token != old_token, "fresh RoomJoined replaces credential")
	_arm("cleanup.arm")
	_expect(actor.client.ping() == OK, "release stale candidate cleanup")
	if not await _wait(func() -> bool: return actor.pongs == 2, "cleanup completed before Pong"):
		return false
	_expect(
		FileAccess.get_file_as_string(_fixture_dir.path_join("cleaned")) == "0",
		"stale cleanup removes no confirmed seat"
	)
	_expect(actor.client.set_ready() == OK, "fresh seat can become ready")
	if not await _wait(func() -> bool: return _ready_player(host, id), "ready after cleanup"):
		return false
	var payload := {"after_cleanup": _case}
	var error := (
		actor.client.send_game_data(payload)
		if format_name == "json"
		else actor.client.send_game_data_binary(_msgpack(payload))
	)
	_expect(error == OK, "fresh seat sends gameplay")
	if not await _wait(func() -> bool: return host.data.size() == 1, "gameplay after cleanup"):
		return false
	_expect(_same_payload(host.data[0], payload), "exact gameplay after cleanup")
	actor.client.close()
	if not await _wait(
		func() -> bool: return host_log.departures.size() == 2, "fresh membership disconnect"
	):
		return false
	_expect(actor.client.reconnect(id, room, token) == OK, "current credential reconnects")
	if not await _wait(
		func() -> bool: return actor_log.restored == 1, "fresh seat restored after cleanup"
	):
		return false
	_expect(
		actor.client.get_player_id() == id and actor.client.get_room_id() == room,
		"current membership restored"
	)
	actor.client.close()
	if not await _wait(
		func() -> bool: return host_log.departures.size() == 3, "expiry control disconnect"
	):
		return false
	await create_timer(1.2).timeout
	_expect(
		actor.client.reconnect(id, room, actor_log.baseline.reconnection_token) == OK,
		"expired control dial"
	)
	if not await _wait(
		func() -> bool: return refused.size() == 1, "ordinary expired credential refused"
	):
		return false
	_expect(
		refused[0] in [Errors.Code.RECONNECTION_EXPIRED, Errors.Code.RECONNECTION_TOKEN_INVALID],
		"ordinary expiry uses terminal refusal code"
	)
	_expect(actor.client.get_room_id().is_empty(), "refusal retains no membership")
	_expect(
		actor.client.connect_to_server("%s/v3/ws" % _base_url) == OK, "fresh login after expiry"
	)
	if not await _wait(
		func() -> bool:
			return actor.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
		"fresh authenticated control"
	):
		return false
	actor.joined = false
	_join_with_authority(actor, game, room_code)
	if not await _wait(
		func() -> bool: return actor.joined, "fresh admission after ordinary expiry"
	):
		return false
	var fresh := {"fresh_after_expiry": _case}
	error = (
		actor.client.send_game_data(fresh)
		if format_name == "json"
		else actor.client.send_game_data_binary(_msgpack(fresh))
	)
	_expect(error == OK, "fresh admission sends after ordinary expiry")
	if not await _wait(
		func() -> bool: return host.data.size() == 2, "fresh gameplay after ordinary expiry"
	):
		return false
	_expect(_same_payload(host.data[1], fresh), "exact fresh gameplay after ordinary expiry")

	print(
		(
			"LIVE_EXPIRED_CLEANUP_PASS observer_v%d %s fresh seat ready gameplay reconnect expiry control"
			% [version, format_name]
		)
	)
	return true


func _arm(name: String) -> void:
	var file := FileAccess.open(_fixture_dir.path_join(name), FileAccess.WRITE)
	_expect(file != null, "arm cleanup fixture")
	if file != null:
		file.store_string("armed")
		file.close()


func _ready_player(seat: Seat, id: String) -> bool:
	for player: TypesScript.PlayerInfo in seat.client.get_players():
		if player.id == id:
			return player.is_ready
	return false
