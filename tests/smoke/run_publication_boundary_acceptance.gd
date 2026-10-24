extends "res://tests/smoke/run_controlled_lifecycle_acceptance.gd"
# gdlint: disable=max-returns

## Opt-in gameplay publication boundaries for #356, #358 and #368.

var _listeners: Array[TCPServer] = []
var _applications: Array[DirectSocket] = []
var _remotes: Array[StreamPeerTCP] = []


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
	for version: int in [2, 3]:
		for format_name: String in ["json", "message_pack"]:
			if await _spectator_publication(version, format_name) != true:
				_failures.append("spectator publication did not complete")
				_finish()
				return
			_close_seats()
		if await _removed_spectator(version) != true:
			_failures.append("authoritative spectator removal did not complete")
			_finish()
			return
		_close_seats()
	if await _correlated_detach() != true:
		_failures.append("correlated spectator recovery did not complete")
		_finish()
		return
	_close_seats()
	if await _direct_socket_reconnect() != true:
		_failures.append("Direct socket reconnect did not complete")
	_finish()


func _spectator_publication(version: int, format_name: String) -> bool:
	var host := _seat(version, format_name, false)
	var peer := _seat(version, format_name, false)
	var viewer := _seat(version, format_name, false)
	var late := _seat(version, format_name, false)
	if not await _wait(func() -> bool: return _logged_in(), "publication logins"):
		return false
	var game := "godot-publish-%d-%d-%s" % [OS.get_process_id(), version, format_name]
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "publication room"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return peer.joined, "publication incumbent"):
		return false
	var events: Array[String] = []
	viewer.client.spectator_joined.connect(
		func(_info: TypesScript.SpectatorJoinedInfo) -> void: events.append("baseline")
	)
	viewer.client.player_joined.connect(
		func(_player: TypesScript.PlayerInfo) -> void: events.append("join")
	)
	_arm("spectator-baseline")
	_expect(
		viewer.client.join_as_spectator(game, host.client.get_room_code(), "Viewer") == OK,
		"publish spectate"
	)
	if not await _wait(
		func() -> bool: return _reached("spectator-baseline"), "spectator baseline held"
	):
		return false
	_arm("join-enter")
	_join(late, game, host.client.get_room_code())
	if not await _wait(
		func() -> bool: return _reached("join-enter"), "concurrent player join entered"
	):
		return false
	_send_payload(host, format_name, {"before_baseline": true})
	if not await _wait(
		func() -> bool: return peer.data.size() == 1, "gameplay while baseline held"
	):
		return false
	_expect(
		viewer.baselines == 0 and viewer.data.is_empty(), "unpublished spectator has no traffic"
	)
	_expect(not late.joined and host.client.get_players().size() == 2, "join waits behind snapshot")
	_write("spectator-baseline.release")
	if not await _wait(
		func() -> bool:
			return viewer.baselines == 1 and late.joined and viewer.client.get_players().size() == 3,
		"snapshot then concurrent membership"
	):
		return false
	_expect(events == ["baseline", "join"], "baseline precedes exactly one membership delta")
	_expect(viewer.baseline_cached, "publication baseline cached before callback")
	_expect(viewer.data.is_empty(), "late spectator does not invent prior gameplay")
	var ids: Array[String] = []
	for player: TypesScript.PlayerInfo in viewer.client.get_players():
		ids.append(player.id)
	for seat: Seat in [host, peer, late]:
		_expect(
			ids.has(seat.client.get_player_id()), "published roster contains each current player"
		)

	_send_payload(host, format_name, {"after_baseline": true})
	if not await _wait(
		func() -> bool: return viewer.data.size() == 1 and late.data.size() == 1,
		"post-publication gameplay"
	):
		return false
	if format_name == "json":
		_expect(_same_payload(viewer.data[0], {"after_baseline": true}), "publication JSON payload")
	else:
		_expect(viewer.data[0] == _msgpack({"after_baseline": true}), "publication binary payload")
	_expect(viewer.senders == [host.client.get_player_id()], "publication sender")
	_expect(
		viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING,
		"publication keeps spectator role"
	)
	_expect(viewer.plans.is_empty(), "publication has no seated plan")
	_expect(events == ["baseline", "join"], "publication delta stays exactly once")
	if _failures.is_empty():
		print(
			(
				"LIVE_SPECTATOR_PUBLICATION_PASS v%d %s forced snapshot join overlap"
				% [version, format_name]
			)
		)
	return _failures.is_empty()


func _removed_spectator(version: int) -> bool:
	var host := _seat(3, "json", false)
	var peer := _seat(3, "json", false)
	var viewer := _seat(version, "json", false)
	var host_log := _history(host)
	var peer_log := _history(peer)
	var viewer_log := _history(viewer)
	if not await _wait(func() -> bool: return _logged_in(), "removal logins"):
		return false
	var game := "godot-remove-%d-%d" % [OS.get_process_id(), version]
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "removal room"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return peer.joined, "removal peer"):
		return false
	var room := host.client.get_room_id()
	var code := host.client.get_room_code()
	var id := peer.client.get_player_id()
	var token := peer_log.baseline.reconnection_token
	_expect(viewer.client.join_as_spectator(game, code, "Removed viewer") == OK, "removal spectate")
	if not await _wait(func() -> bool: return viewer.baselines == 1, "removal baseline"):
		return false
	var spectator_id := viewer_log.spectator_id
	peer.client.close()
	if not await _wait(
		func() -> bool: return peer_log.closed == 1 and host_log.departures.has(id),
		"removal replay actor absent"
	):
		return false
	_arm("detach-error")
	_arm("spectator-remove")
	_expect(viewer.client.ping() == OK, "trigger administrative removal fixture")
	if not await _wait(
		func() -> bool:
			return (
				_reached("spectator-remove") and viewer.left == 1 and host_log.detached.size() == 1
			),
		"recovered authoritative removal"
	):
		return false
	_expect(_reached("detach-error"), "authoritative removal registration failure injected")
	_expect(
		viewer_log.terminals == [[room, code, TypesScript.SpectatorReason.REMOVED]],
		"authoritative room identity and reason"
	)
	_expect(
		host_log.detached == [[spectator_id, TypesScript.SpectatorReason.REMOVED]],
		"one authoritative room delta"
	)
	_expect(host.client.get_spectators().is_empty(), "authoritative roster removed")
	_expect(host.client.get_room_id() == room, "authoritative removal preserves player session")
	_expect(
		viewer.client.get("_context_auth_token") == "",
		"authoritative removal clears retained identity"
	)
	_expect(peer.client.reconnect(id, room, token) == OK, "replay authoritative removal")
	if not await _wait(
		func() -> bool: return peer_log.restored == 1, "authoritative replay baseline"
	):
		return false
	var replay: Array[Array] = []
	for event: TypesScript.DecodedEvent in peer_log.missed:
		if event.signal_name == &"spectator_disconnected":
			replay.append([event.args[0], event.args[1], event.args[2]])
	_expect(
		replay == [[spectator_id, TypesScript.SpectatorReason.REMOVED, []]],
		"one authoritative removal replay with terminal roster"
	)
	_expect(peer_log.detached.is_empty(), "authoritative replay requires consumer dispatch")
	_expect(
		viewer.client.join_as_spectator(game, code, "Fresh viewer") == OK,
		"readmit removed spectator"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 2, "fresh removed baseline"):
		return false
	_expect(viewer_log.spectator_id == spectator_id, "readmission preserves connection identity")
	_send_payload(peer, "json", {"after_removal": true})
	if not await _wait(func() -> bool: return viewer.data.size() == 1, "gameplay after removal"):
		return false
	_expect(_same_payload(viewer.data[0], {"after_removal": true}), "removal gameplay payload")
	_expect(
		viewer.left == 1 and host_log.detached.size() == 1,
		"authoritative removal stays exactly once"
	)
	if _failures.is_empty():
		print(
			"LIVE_SPECTATOR_REMOVED_PASS v%d recovered reason replay readmission gameplay" % version
		)
	return _failures.is_empty()


func _correlated_detach() -> bool:
	var host := _seat(3, "json", false)
	var peer := _seat(3, "json", false)
	var viewer := _seat(3, "json", false, false, PackedStringArray(["room_operation_ids"]))
	var host_log := _history(host)
	if not await _wait(func() -> bool: return _logged_in(), "correlated logins"):
		return false
	_expect(viewer.protocol.capabilities.has("room_operation_ids"), "correlation negotiated")
	var game := "godot-correlated-%d" % OS.get_process_id()
	_join(host, game, "")
	if not await _wait(func() -> bool: return host.joined, "correlated room"):
		return false
	_join(peer, game, host.client.get_room_code())
	if not await _wait(func() -> bool: return peer.joined, "correlated peer"):
		return false
	var room := host.client.get_room_id()
	var code := host.client.get_room_code()
	_expect(
		viewer.client.join_as_spectator(game, code, "Correlated viewer") == OK,
		"correlated spectate"
	)
	if not await _wait(func() -> bool: return viewer.baselines == 1, "correlated baseline"):
		return false
	var results: Array[SessionScript.RoomOperationResultInfo] = []
	viewer.client.room_operation_result.connect(
		func(result: SessionScript.RoomOperationResultInfo) -> void: results.append(result)
	)
	var operation_id := "00000000-0000-4000-8000-000000000378"
	var request := {
		"type": "RoomOperation",
		"data": {"operation_id": operation_id, "operation": {"type": "LeaveSpectator"}}
	}
	_arm("detach-error")
	_expect(
		viewer.client.transport.send_text(JSON.stringify(request)) == OK,
		"fixture-only correlated leave"
	)
	if not await _wait(
		func() -> bool: return results.size() == 1 and host_log.detached.size() == 1,
		"recovered correlated result"
	):
		return false
	_expect(_reached("detach-error"), "correlated registration failure injected")
	_expect(
		results[0].operation_id == operation_id and results[0].result_type == "SpectatorLeft",
		"correlated identity and type"
	)
	_expect(
		(
			results[0].data
			== {
				"room_id": room,
				"room_code": code,
				"reason": "voluntary_leave",
				"current_spectators": []
			}
		),
		"recovered correlated payload"
	)
	_expect(
		(
			viewer.left == 0
			and viewer.client.get_session_state() == ClientScript.SessionState.SPECTATING
			and viewer.client.get_room_id() == room
		),
		"correlated result stays informational"
	)
	_expect(host.client.get_spectators().is_empty(), "correlated server roster removed")
	_expect(viewer.client.ping() == OK, "correlated processing barrier")
	_expect(
		peer.client.send_game_data({"after_correlated": true}) == OK, "correlated survivor send"
	)
	if not await _wait(
		func() -> bool: return viewer.pongs == 1 and host.data.size() == 1,
		"correlated survivor gameplay and Pong"
	):
		return false
	_expect(_same_payload(host.data[0], {"after_correlated": true}), "correlated gameplay payload")
	_expect(
		results.size() == 1 and host_log.detached.size() == 1 and viewer.data.is_empty(),
		"correlated result exactly once and server routing detached"
	)
	if _failures.is_empty():
		print(
			"LIVE_CORRELATED_DETACH_PASS recovered operation identity payload informational result"
		)
	return _failures.is_empty()


func _send_payload(seat: Seat, format_name: String, payload: Dictionary) -> void:
	_expect(
		(
			(
				seat.client.send_game_data(payload)
				if format_name == "json"
				else seat.client.send_game_data_binary(_msgpack(payload))
			)
			== OK
		),
		"publication gameplay send"
	)


func _direct_socket_reconnect() -> bool:
	var old_listener := TCPServer.new()
	var new_listener := TCPServer.new()
	_listeners.assign([old_listener, new_listener])
	_expect(old_listener.listen(0, "127.0.0.1") == OK, "old Direct listener")
	_expect(new_listener.listen(0, "127.0.0.1") == OK, "new Direct listener")
	var first := _seat(3, "json", false, true)
	var second := _seat(3, "json", false, true)
	var first_log := _history(first)
	var second_log := _history(second)
	if not await _wait(func() -> bool: return _logged_in(), "socket Direct logins"):
		return false
	var game := "godot-socket-%d" % OS.get_process_id()
	_join(first, game, "")
	if not await _wait(func() -> bool: return first.joined, "socket Direct room"):
		return false
	_join(second, game, first.client.get_room_code())
	if not await _wait(func() -> bool: return second.joined, "socket Direct peer"):
		return false
	for seat: Seat in [first, second]:
		_endpoint(seat, "127.0.0.1", old_listener.get_local_port())
		_expect(seat.client.set_ready() == OK, "socket Direct ready")
	if not await _wait(func() -> bool: return first.all_ready, "socket Direct all ready"):
		return false
	_expect(first.client.start_game() == OK, "socket Direct start")
	if not await _wait(
		func() -> bool: return first.plans.size() == 1 and second.plans.size() == 1,
		"socket Direct plans"
	):
		return false
	var host: Seat = first if first.plans.back().host == first.client.get_player_id() else second
	var peer: Seat = second if host == first else first
	var peer_log: History = second_log if host == first else first_log
	var host_log: History = first_log if host == first else second_log
	var app := DirectSocket.new()
	_applications.append(app)
	peer.client.session_plan.connect(app.apply)
	peer.client.disconnected.connect(func(_code: int, _reason: String) -> void: app.close())
	app.apply(peer.plans[peer.plans.size() - 1])
	if not await _wait(
		func() -> bool: return _socket_ready(app), "initial application TCP connection"
	):
		return false
	if await _tcp_gameplay(app, old_listener, "initial") != true:
		return false
	var id := peer.client.get_player_id()
	var room := peer.client.get_room_id()
	for cycle: int in 2:
		var token := peer_log.baseline.reconnection_token
		peer.client.close()
		if not await _wait(
			func() -> bool:
				return peer_log.closed == cycle + 1 and host_log.departures.size() == cycle + 1,
			"socket peer disconnect"
		):
			return false
		_expect(app.socket == null, "application closes socket on service disconnect")
		var listener: TCPServer = new_listener if cycle == 0 else old_listener
		_arm("direct")
		_endpoint(host, "127.0.0.1", listener.get_local_port())
		if not await _wait(
			func() -> bool: return _reached("direct"), "socket Direct metadata held"
		):
			return false
		_arm("reconnect-enter")
		_expect(peer.client.reconnect(id, room, token) == OK, "controlled socket reconnect")
		if not await _wait(
			func() -> bool: return _reached("reconnect-enter"),
			"reconnect enters held mutation lane"
		):
			return false
		_expect(peer_log.restored == cycle, "reconnect baseline waits for metadata commit")
		_write("direct.release")
		if not await _wait(
			func() -> bool:
				return (
					peer_log.restored == cycle + 1
					and _matching_direct(host, peer, "127.0.0.1", listener.get_local_port())
					and _socket_ready(app)
				),
			"reconnect fresh plan and application socket"
		):
			return false
		_expect(
			peer_log.baseline.reconnection_token != token, "controlled reconnect rotates credential"
		)
		_expect(peer_log.plan_after_baseline, "controlled plan follows reconnect baseline")
		if not await _wait(_all_remotes_closed, "host observes old Direct socket EOF"):
			return false
		if await _tcp_gameplay(app, listener, "cycle-%d" % cycle) != true:
			return false
		_expect(
			peer.client.send_game_data({"socket_cycle": cycle}) == OK, "socket reconnect relay send"
		)
		if not await _wait(
			func() -> bool: return host.data.size() == cycle + 1, "socket reconnect relay received"
		):
			return false
		_expect(
			_same_payload(host.data.back(), {"socket_cycle": cycle}),
			"socket reconnect relay payload"
		)
	var previous: StreamPeerTCP = app.socket
	_endpoint(host, "127.0.0.1", new_listener.get_local_port())
	if not await _wait(
		func() -> bool:
			return (
				_matching_direct(host, peer, "127.0.0.1", new_listener.get_local_port())
				and _socket_ready(app)
			),
		"running application endpoint refresh"
	):
		return false
	_expect(
		previous.get_status() == StreamPeerTCP.STATUS_NONE, "running refresh disconnects old socket"
	)
	if not await _wait(_all_remotes_closed, "host observes replaced socket EOF"):
		return false
	if await _tcp_gameplay(app, new_listener, "refreshed") != true:
		return false
	previous = app.socket
	for seat: Seat in [host, peer]:
		_expect(
			(
				seat.client.provide_connection_info(
					TypesScript.ConnectionInfo.new({"type": "relay"})
				)
				== OK
			),
			"remove application Direct endpoint"
		)
	if not await _wait(
		func() -> bool:
			return (
				peer.plans.back().transport == SessionScript.TransportKind.RELAY
				and host.plans.back().transport == SessionScript.TransportKind.RELAY
			),
		"application Relay reset"
	):
		return false
	_expect(
		app.socket == null and previous.get_status() == StreamPeerTCP.STATUS_NONE,
		"Relay reset closes application socket"
	)
	if not await _wait(_all_remotes_closed, "host observes Relay teardown EOF"):
		return false
	_expect(app.errors.is_empty(), "application socket operations succeeded")
	var reset: SessionScript.SessionPlanInfo = peer.plans.back()
	_expect(
		(
			reset.host.is_empty()
			and reset.direct_endpoint == null
			and reset.peers.is_empty()
			and reset.ice_servers.is_empty()
		),
		"application reset clears path state"
	)
	_expect(
		peer.client.send_game_data({"after_socket_reset": true}) == OK,
		"relay after socket teardown"
	)
	if not await _wait(
		func() -> bool: return host.data.size() == 3, "relay usable after socket teardown"
	):
		return false
	_expect(_same_payload(host.data.back(), {"after_socket_reset": true}), "relay teardown payload")
	var reset_token := peer_log.baseline.reconnection_token
	peer.client.close()
	if not await _wait(func() -> bool: return peer_log.closed == 3, "reset disconnect"):
		return false
	_expect(peer.client.reconnect(id, room, reset_token) == OK, "reconnect ended Direct session")
	if not await _wait(
		func() -> bool: return peer_log.restored == 3 and peer_log.plan_after_baseline,
		"reset reconnect baseline"
	):
		return false
	_expect(peer.client.ping() == OK and host.client.ping() == OK, "reset reconnect barriers")
	var peer_pongs := peer.pongs + 1
	var host_pongs := host.pongs + 1
	if not await _wait(
		func() -> bool: return peer.pongs == peer_pongs and host.pongs == host_pongs,
		"reset reconnect publications drained"
	):
		return false
	_expect(app.socket == null, "reset reconnect cannot revive the Direct socket")
	_expect(
		peer_log.baseline.reconnection_token != reset_token, "reset reconnect rotates credential"
	)
	for seat: Seat in [host, peer]:
		var plan: SessionScript.SessionPlanInfo = seat.plans.back()
		_expect(plan.transport == SessionScript.TransportKind.RELAY, "ended session stays Relay")
		_expect(plan.direct_endpoint == null and plan.host.is_empty(), "reset path stays clear")
	var plan_count := host.plans.size()
	_endpoint(host, "127.0.0.1", old_listener.get_local_port())
	_expect(host.client.ping() == OK, "ended session endpoint barrier")
	if not await _wait(
		func() -> bool: return host.pongs == host_pongs + 1, "ended metadata processed"
	):
		return false
	_expect(host.plans.size() == plan_count, "new endpoint cannot restart an ended Direct session")
	_expect(app.socket == null, "ended session endpoint cannot reopen application socket")
	_expect(
		peer.client.send_game_data({"after_reset_reconnect": true}) == OK, "reset reconnect relay"
	)
	if not await _wait(func() -> bool: return host.data.size() == 4, "reset reconnect gameplay"):
		return false
	_expect(
		_same_payload(host.data.back(), {"after_reset_reconnect": true}), "reset reconnect payload"
	)
	_expect(peer.client.leave_room() == OK, "leave ended session")
	if not await _wait(
		func() -> bool: return peer.client.get_room_id().is_empty(), "reset room exit"
	):
		return false
	_expect(app.socket == null, "room exit after reset keeps socket closed")
	if _failures.is_empty():
		print("LIVE_DIRECT_SOCKET_PASS TCP reset reconnect ended-session relay room exit")
	return _failures.is_empty()


func _socket_ready(app: DirectSocket) -> bool:
	if app.socket == null:
		return false
	app.socket.poll()
	return app.socket.get_status() == StreamPeerTCP.STATUS_CONNECTED


func _tcp_gameplay(app: DirectSocket, listener: TCPServer, payload: String) -> bool:
	if not await _wait(
		func() -> bool: return listener.is_connection_available(), "application host accepts TCP"
	):
		return false
	var remote := listener.take_connection()
	_remotes.append(remote)
	_expect(app.socket.put_data(payload.to_utf8_buffer()) == OK, "application TCP gameplay send")
	if not await _wait(
		func() -> bool:
			remote.poll()
			return remote.get_available_bytes() >= payload.length(),
		"application TCP gameplay receipt"
	):
		remote.disconnect_from_host()
		return false
	var received := remote.get_data(payload.length())
	_expect(
		received[0] == OK and received[1] == payload.to_utf8_buffer(), "application TCP payload"
	)
	return _failures.is_empty()


func _all_remotes_closed() -> bool:
	for remote: StreamPeerTCP in _remotes:
		remote.poll()
		if remote.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return false
	return true


func _drain_listener(listener: TCPServer) -> void:
	while listener.is_connection_available():
		listener.take_connection().disconnect_from_host()


func _finish() -> void:
	if not _barrier_dir.is_empty() and DirAccess.dir_exists_absolute(_barrier_dir):
		_write("spectator-baseline.release")
	for app: DirectSocket in _applications:
		app.close()
	for remote: StreamPeerTCP in _remotes:
		remote.disconnect_from_host()
	for listener: TCPServer in _listeners:
		_drain_listener(listener)
		listener.stop()
	super._finish()


class DirectSocket:
	extends RefCounted
	var socket: StreamPeerTCP = null
	var generation := ""
	var errors: Array[int] = []

	func apply(plan: SessionScript.SessionPlanInfo) -> void:
		if plan.generation == generation:
			return
		close()
		generation = plan.generation
		if plan.transport == SessionScript.TransportKind.DIRECT and plan.direct_endpoint != null:
			socket = StreamPeerTCP.new()
			var result := socket.connect_to_host(
				plan.direct_endpoint.host, plan.direct_endpoint.port
			)
			if result != OK:
				errors.append(result)

	func close() -> void:
		if socket != null:
			socket.disconnect_from_host()
			socket = null
