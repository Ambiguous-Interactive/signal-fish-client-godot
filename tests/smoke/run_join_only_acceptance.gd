extends "res://tests/smoke/run_live_server_acceptance.gd"
# gdlint: disable=max-returns

const ErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_base_url = args[0].trim_suffix("/")
	_run()


func _run() -> void:
	for version: int in [2, 3]:
		if await _join_only_case(version) != true:
			_failures.append("join-only case did not complete: v%d" % version)
		_close_seats()
	_finish()


func _join_only_case(version: int) -> bool:
	var host := _seat(version, "json", false)
	var peer := _seat(version, "json", false)
	var errors: Array[int] = []
	peer.client.room_join_failed.connect(
		func(_message: String, code: int) -> void: errors.append(code)
	)
	if not await _wait(func() -> bool: return host.authenticated and peer.authenticated, "login"):
		return false
	var params := ClientScript.JoinRoomParams.new()
	params.game_name = "godot-join-only-%d-v%d" % [OS.get_process_id(), version]
	params.player_name = "Guest"
	params.room_code = "ZZZZZZ"
	params.max_players = 4
	params.supports_authority = false
	params.join_only = true
	_expect(peer.client.join_room(params) == OK, "join-only request sent")
	if not await _wait(func() -> bool: return not errors.is_empty() or peer.joined, "missing room"):
		return false
	_expect(errors == [ErrorCodesScript.Code.ROOM_NOT_FOUND], "missing room refused")
	_expect(not peer.joined and peer.client.get_room_id().is_empty(), "refusal leaves no room")
	_expect(
		peer.client.get_session_state() == ClientScript.SessionState.AUTHENTICATED,
		"refusal retains authenticated session"
	)
	_expect(peer.client.join_room(params) == OK, "repeat join-only request")
	if not await _wait(
		func() -> bool: return errors.size() == 2 or peer.joined, "room stays absent"
	):
		return false
	_expect(
		errors == [ErrorCodesScript.Code.ROOM_NOT_FOUND, ErrorCodesScript.Code.ROOM_NOT_FOUND],
		"no orphan room created"
	)
	_expect(not peer.joined, "repeat refusal has no baseline")
	params.player_name = "Host"
	params.join_only = false
	_expect(host.client.join_room(params) == OK, "create-on-join remains available")
	if not await _wait(func() -> bool: return host.joined, "create room"):
		return false
	_expect(host.client.get_players().size() == 1, "new room has one member")
	params.player_name = "Guest"
	params.join_only = true
	_expect(peer.client.join_room(params) == OK, "join existing room")
	if not await _wait(func() -> bool: return peer.joined, "existing room joined"):
		return false
	_expect(peer.client.get_room_id() == host.client.get_room_id(), "same room joined")
	_expect(errors.size() == 2, "existing join has no new refusal")
	_expect(peer.client.get_players().size() == 2, "joined roster has both members")
	_expect(host.client.set_ready() == OK and peer.client.set_ready() == OK, "ready players")
	if not await _wait(
		func() -> bool:
			return host.client.get_players().size() == 2 and host.all_ready and peer.all_ready,
		"players ready"
	):
		return false
	_expect(host.client.start_game() == OK, "start joined game")
	if not await _wait(
		func() -> bool: return host.starts == 1 and peer.starts == 1, "game started"
	):
		return false
	_expect(host.client.send_game_data({"joined": true}) == OK, "gameplay send")
	if not await _wait(func() -> bool: return peer.data.size() == 1, "joined gameplay"):
		return false
	_expect(peer.data[0] == {"joined": true}, "exact joined gameplay")
	print("LIVE_JOIN_ONLY_PASS v%d" % version)
	return _failures.is_empty()
