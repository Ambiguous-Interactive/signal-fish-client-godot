extends RefCounted

const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const ConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const MessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const Fixtures = preload("res://tests/client/client_fixtures.gd")
const PeerScript = preload("res://tests/transport/test_websocket_peer_adapter.gd")
const FakeScript = preload("res://tests/transport/sf_fake_transport.gd")


static func run() -> Array[String]:
	var failures: Array[String] = []
	for reconnecting: bool in [false, true]:
		for close_arrives: bool in [false, true]:
			var label := "reconnect=%s close=%s" % [reconnecting, close_arrives]
			var client := ClientScript.new()
			var config := ConfigScript.new()
			config.app_id = "test-app"
			config.endpoint_url = "ws://example.test/socket"
			config.auto_poll = false
			var transport := ClosingTransport.new()
			transport._send_close_grace_ms = 1000
			client.configure(config)
			client.transport = transport
			var events: Array[String] = []
			client.connection_failed.connect(func(_error: String) -> void: events.append("failed"))
			client.disconnected.connect(
				func(code: int, reason: String) -> void: events.append("%d:%s" % [code, reason])
			)
			var attempts: Array[String] = []
			client.reconnection_failed.connect(
				func(reason: String, _code: int) -> void: attempts.append(reason)
			)
			var error: Error
			if reconnecting:
				error = client.reconnect(Fixtures.PLAYER_A, Fixtures.ROOM_ID, "test-token")
			else:
				error = client.connect_to_server()
			if error != OK:
				failures.append(label + ": setup dial failed")
				client.free()
				continue
			transport.peer.ready_state = WebSocketPeer.STATE_OPEN
			transport.peer.send_text_error = OK if reconnecting else FAILED
			client.poll()
			if reconnecting:
				transport.peer.send_text_error = FAILED
				transport.peer.packets = [
					(
						MessagesScript
						. encode({"type": "Authenticated", "data": Fixtures.authenticated_data()})
						. to_utf8_buffer()
					)
				]
				transport.peer.packet_is_text = [true]
				client.poll()
			if client.transport != transport or not events.is_empty():
				failures.append(label + ": handshake discarded the close wait")
			if client.get_connection_state() != ClientScript.ConnectionState.CLOSING:
				failures.append(label + ": closing handshake lacks a client close watchdog")
			if attempts.size() != (1 if reconnecting else 0):
				failures.append(label + ": wrong reconnect failure count")
			if close_arrives:
				transport.peer.ready_state = WebSocketPeer.STATE_CLOSED
				transport.peer.close_code = 4000
				transport.peer.close_reason = "server_shutdown"
				transport.max_packets_per_poll = 1
				var pong := MessagesScript.encode({"type": "Pong"}).to_utf8_buffer()
				transport.peer.packets = [pong, pong]
				transport.peer.packet_is_text = [true, true]
				config.auto_poll = true
				client._process(config.pong_timeout_sec + 1.0)
				if not events.is_empty() or transport.peer.packets.size() != 1:
					failures.append(label + ": close watchdog beat the observed close drain")
			transport._send_failure_deadline_ms = 0
			client.poll()
			client.poll()
			var expected := ["4000:server_shutdown"] if close_arrives else ["failed"]
			if events != expected or client.transport != null:
				failures.append(label + ": wrong terminal result: " + str(events))
			client.free()
	var redialing := ClientScript.new()
	var redial_config := ConfigScript.new()
	redial_config.app_id = "test-app"
	redial_config.auto_poll = false
	redialing.configure(redial_config)
	var old := ClosingTransport.new()
	old._send_close_grace_ms = 1000
	old.peer.send_text_error = FAILED
	redialing.transport = old
	var fresh := FakeScript.new()
	var redial_started := {"value": false}
	redialing.protocol_error.connect(
		func(_error: String) -> void:
			if redial_started["value"]:
				return
			redial_started["value"] = true
			redialing.close()
			redialing.poll()
			redialing.transport = fresh
			redialing.connect_to_server("ws://example.test/socket")
			fresh.inject_open()
	)
	redialing.connect_to_server("ws://example.test/socket")
	old.peer.ready_state = WebSocketPeer.STATE_OPEN
	redialing.poll()
	if redialing.transport != fresh:
		failures.append("refused-auth handler redial lost its replacement transport")
	if redialing.get_connection_state() != ClientScript.ConnectionState.CONNECTED:
		failures.append("refused-auth handler redial was failed by the old send")
	redialing.free()
	for state: int in [WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED]:
		var closing_client := ClientScript.new()
		var closing_config := ConfigScript.new()
		closing_config.app_id = "test-app"
		closing_config.auto_poll = false
		closing_config.heartbeat_interval_sec = 0.0
		closing_config.pong_timeout_sec = 0.25
		closing_client.configure(closing_config)
		var unresponsive := ClosingWithoutTimer.new()
		unresponsive.terminal_state = state as WebSocketPeer.State
		closing_client.transport = unresponsive
		closing_client.connect_to_server("ws://example.test/socket")
		unresponsive.inject_open()
		closing_client._process(1.0)
		if closing_client.get_connection_state() != ClientScript.ConnectionState.FAILED:
			failures.append("silent adapter bypassed the client close watchdog: " + str(state))
		closing_client.free()
	_check_reentrant_reconnect(failures)
	return failures


static func _check_reentrant_reconnect(failures: Array[String]) -> void:
	for open_fresh: bool in [false, true]:
		var client := ClientScript.new()
		var config := ConfigScript.new()
		config.app_id = "test-app"
		config.endpoint_url = "ws://example.test/socket"
		config.auto_poll = false
		client.configure(config)
		var old := FakeScript.new()
		var fresh := FakeScript.new()
		client.transport = old
		if client.reconnect(Fixtures.PLAYER_A, Fixtures.ROOM_ID, "old-token") != OK:
			failures.append("reentrant reconnect setup dial failed")
			client.free()
			continue
		old.inject_open()
		var dial_errors: Array[int] = []
		var attempts: Array[String] = []
		client.connection_failed.connect(
			func(_error: String) -> void:
				client.transport = fresh
				dial_errors.append(
					client.reconnect(Fixtures.PLAYER_B, Fixtures.ROOM_ID, "fresh-token")
				)
				if open_fresh:
					fresh.inject_open()
		)
		client.reconnection_failed.connect(
			func(reason: String, _code: int) -> void: attempts.append(reason)
		)
		old.fail_on_send = true
		old.inject_server_message({"type": "Authenticated", "data": Fixtures.authenticated_data()})
		var label := "reentrant reconnect open=%s" % open_fresh
		if dial_errors != [OK]:
			failures.append(label + ": handler redial failed")
		if attempts.size() != 1:
			failures.append(label + ": old attempt lost its failure notification")
		if client.transport != fresh:
			failures.append(label + ": old send terminated the replacement transport")
		var expected_state := (
			ClientScript.ConnectionState.CONNECTED
			if open_fresh
			else ClientScript.ConnectionState.CONNECTING
		)
		if client.get_connection_state() != expected_state:
			failures.append(label + ": old send changed replacement connection state")
		if not open_fresh:
			fresh.inject_open()
		fresh.inject_server_message(
			{"type": "Authenticated", "data": Fixtures.authenticated_data()}
		)
		var expected := MessagesScript.encode(
			MessagesScript.reconnect(Fixtures.PLAYER_B, Fixtures.ROOM_ID, "fresh-token")
		)
		if fresh.sent_text.size() != 2 or fresh.sent_text.back() != expected:
			failures.append(label + ": replacement handshake lost its fresh credentials")
		client.free()


class ClosingTransport:
	extends "res://addons/signal_fish/transport/sf_websocket_transport.gd"
	var peer := PeerScript.new()

	# gdscript-private-helper: allow _make_peer
	func _make_peer() -> SFWebSocketPeerAdapterScript:
		return peer


class ClosingWithoutTimer:
	extends FakeScript
	var terminal_state := WebSocketPeer.STATE_CLOSING

	func send_text(_text: String) -> Error:
		_ready_state = terminal_state
		return FAILED
