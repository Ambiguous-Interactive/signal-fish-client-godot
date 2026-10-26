var _service_plan: SessionScript.SessionPlanInfo
var _service_ready := false
var _service_all_ready := false
var _service_signals_received := 0
var _service_receiver_retired := false
var _service_rejoin := false
var _service_previous_receiver: MultiplayerPeer
var _service_game_name := ""
var _service_reference_epoch := 0


func _service_setup() -> bool:
	var config := preload("res://addons/signal_fish/signal_fish_config.gd").new()
	var options: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://reference-options.json")
	)
	config.app_id = options["service_app_id"]
	_service_rejoin = options["service_rejoin"]
	config.protocol_version = 3
	config.auto_poll = false
	config.supported_transports = PackedStringArray(["relay", "webrtc"])
	config.supported_topologies = PackedStringArray(["host"])
	_signal_players = PLAYERS.duplicate()
	_client.service = true
	_client.authenticated.connect(
		func(_app: String, _org: String, _limits: RefCounted) -> void: _service_ready = true
	)
	_client.lobby_state_changed.connect(
		func(_state: int, _players: PackedStringArray, all_ready: bool) -> void:
			_service_all_ready = all_ready
	)
	_client.session_plan.connect(
		func(plan: SessionScript.SessionPlanInfo) -> void: _service_plan = plan
	)
	_client.signal_received.connect(
		func(_from: String, _generation: String, _payload: Variant) -> void:
			_service_signals_received += 1
	)
	_client.protocol_error.connect(func(error: String) -> void: _fail.call_deferred(error))
	_client.server_error.connect(
		func(error: String, _code: int) -> void: _fail.call_deferred(error)
	)
	_client.connection_failed.connect(func(error: String) -> void: _fail.call_deferred(error))
	_client.authentication_error.connect(
		func(error: String, _code: int) -> void: _fail.call_deferred(error)
	)
	_client.room_join_failed.connect(
		func(error: String, _code: int) -> void: _fail.call_deferred(error)
	)
	if (
		_client.configure(config) != OK
		or _client.connect_to_server(str(options["service_url"])) != OK
	):
		_fail.call_deferred("reference service connect failed")
		return false
	return true


func _service_receiver_matches(phase: int, receiver: MultiplayerPeer) -> bool:
	return phase == 1 or ((receiver == _reference_receiver) == _service_rejoin)


func _service_begin(phase: int) -> bool:
	_service_receiver_retired = (
		_reference_receiver == null
		or (
			(
				_service_rejoin
				or (
					_reference_receiver.get_connection_status()
					== MultiplayerPeer.CONNECTION_DISCONNECTED
				)
			)
			and _reference_receiver.get_available_packet_count() == 0
			and _reference_receiver.get_packet().is_empty()
		)
	)
	if not _service_receiver_retired:
		_fail("service room retained the old receiver")
		return false
	_service_previous_receiver = _reference_receiver
	_client.service_signals_sent = 0
	_service_signals_received = 0
	_service_plan = null
	_service_all_ready = false
	if not await _wait_until("service login", func() -> bool: return _service_ready):
		return false
	if not await _service_join(phase):
		return false
	return await _service_finalize()


func _service_join(phase: int) -> bool:
	var params := ClientScript.JoinRoomParams.new()
	var existing := _service_rejoin and phase > 1
	if not existing:
		_service_game_name = "godot-reference-%d-%d" % [Time.get_ticks_usec(), phase]
	params.game_name = _service_game_name
	params.player_name = "Godot"
	params.max_players = 2
	params.supports_authority = false
	if not existing and _client.join_room(params) != OK:
		return false
	if not await _wait_until(
		"service room", func() -> bool: return not _client.get_room_code().is_empty()
	):
		return false
	(
		_pending
		. append(
			{
				"marker": "service-room-%d" % phase,
				"game_name": params.game_name,
				"room_code": _client.get_room_code(),
				"player_id": _client.get_player_id(),
			}
		)
	)
	if not await _wait_until(
		"service membership", func() -> bool: return _client.get_players().size() == 2
	):
		return false
	return true


func _service_finalize() -> bool:
	if not _service_rejoin or _phase == 1:
		if _client.set_ready() != OK:
			return false
		if not await _wait_until("service readiness", func() -> bool: return _service_all_ready):
			return false
		if _client.start_game() != OK:
			return false
	if not await _wait_until(
		"service plan",
		func() -> bool: return _service_plan != null and _service_plan.peers.size() == 1
	):
		return false
	if (
		_service_plan.transport != SessionScript.TransportKind.WEBRTC
		or _service_plan.peers.size() != 1
		or _service_plan.peers[0].initiate
	):
		_fail("service needs a WebRTC host plan with the reference offering")
		return false
	_signal_players[_seat] = _client.get_player_id()
	_signal_players[1 - _seat] = _service_plan.peers[0].player_id
	_service_reference_epoch = 0
	for player: ClientScript.SFTypesScript.PlayerInfo in _client.get_players():
		if player.id == _signal_players[1 - _seat]:
			_service_reference_epoch = player.raw.get("epoch", 0)
	return true


func _service_end(phase: int) -> bool:
	var evidence := {
		"phase": phase,
		"room_id": _client.get_room_id(),
		"generation": _service_plan.generation,
		"player_id": _client.get_player_id(),
		"peer_id": _signal_players[1 - _seat],
		"signals_sent": _client.service_signals_sent,
		"signals_received": _service_signals_received,
		"receiver_retired": _service_receiver_retired,
		"same_receiver": _service_previous_receiver == _reference_receiver,
		"reference_epoch": _service_reference_epoch,
	}
	if _service_rejoin and phase == 1:
		var departed := await _wait_until(
			"service peer departure",
			func() -> bool: return _client.get_players().size() == 1 and _mesh.get_peer_count() == 0
		)
		evidence["left"] = false
		evidence["peer_departed"] = departed
		print("WEBRTC_REFERENCE_SERVICE " + JSON.stringify(evidence))
		return departed
	if _client.leave_room() != OK:
		return false
	var left := await _wait_until(
		"service room leave", func() -> bool: return _client.get_room_id().is_empty()
	)
	evidence["left"] = left
	print("WEBRTC_REFERENCE_SERVICE " + JSON.stringify(evidence))
	return left
