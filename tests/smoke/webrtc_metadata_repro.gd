extends Node

## Standalone engine reproducer for #403. No Signal Fish code is used.

var _receiver := WebRTCMultiplayerPeer.new()
var _senders: Array[WebRTCMultiplayerPeer] = []
var _connections: Array[WebRTCPeerConnection] = []
var _errors: Array[String] = []
var _results: Array[Dictionary] = []


func _ready() -> void:
	if _receiver.create_mesh(1) != OK:
		_finish("receiver setup failed")
		return
	for id: int in [2, 3]:
		if not _add_sender(id):
			_finish("sender setup failed")
			return
	if not await _wait_until(func() -> bool: return _all_connected()):
		_finish("connection timed out")
		return
	for id: int in [2, 3]:
		if not await _probe(id):
			_finish("packet probe failed")
			return
	_finish("")


func _process(_delta: float) -> void:
	_receiver.poll()
	for sender: WebRTCMultiplayerPeer in _senders:
		sender.poll()


func _add_sender(id: int) -> bool:
	var sender := WebRTCMultiplayerPeer.new()
	var local := WebRTCPeerConnection.new()
	var remote := WebRTCPeerConnection.new()
	if sender.create_mesh(id) != OK or local.initialize({}) != OK or remote.initialize({}) != OK:
		return false
	_senders.append(sender)
	_connections.append_array([local, remote])
	if _receiver.add_peer(local, id) != OK or sender.add_peer(remote, 1) != OK:
		return false
	local.session_description_created.connect(
		func(type: String, sdp: String) -> void: _description(local, remote, type, sdp)
	)
	remote.session_description_created.connect(
		func(type: String, sdp: String) -> void: _description(remote, local, type, sdp)
	)
	local.ice_candidate_created.connect(
		func(mid: String, index: int, candidate: String) -> void:
			if remote.add_ice_candidate(mid, index, candidate) != OK:
				_errors.append("remote ICE failed")
	)
	remote.ice_candidate_created.connect(
		func(mid: String, index: int, candidate: String) -> void:
			if local.add_ice_candidate(mid, index, candidate) != OK:
				_errors.append("local ICE failed")
	)
	return local.create_offer() == OK


func _description(
	local: WebRTCPeerConnection, remote: WebRTCPeerConnection, type: String, sdp: String
) -> void:
	if (
		local.set_local_description(type, sdp) != OK
		or remote.set_remote_description(type, sdp) != OK
	):
		_errors.append("SDP failed")


func _all_connected() -> bool:
	for id: int in [2, 3]:
		if not _receiver.get_peer(id)["connected"]:
			return false
	return true


func _probe(id: int) -> bool:
	var sender := _senders[id - 2]
	var channels: Array = _receiver.get_peer(id)["channels"]
	var reliable_channel: WebRTCDataChannel = channels[0]
	var unreliable := ("unreliable:%d:" % id).to_utf8_buffer()
	var reliable := ("reliable:%d:" % id).to_utf8_buffer()
	sender.set_target_peer(1)
	sender.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	if sender.put_packet(unreliable) != OK:
		return false
	if not await _wait_until(func() -> bool: return _receiver.get_available_packet_count() == 1):
		return false
	var cached_peer := _receiver.get_packet_peer()
	var cached_mode := _receiver.get_packet_mode()
	var cached_channel := _receiver.get_packet_channel()
	if cached_peer != id or cached_mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
		return false
	sender.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	if sender.put_packet(reliable) != OK:
		return false
	if not await _wait_until(
		func() -> bool: return reliable_channel.get_available_packet_count() == 1
	):
		return false
	# Keep the selection across another poll after the higher-priority arrival.
	await get_tree().process_frame
	_receiver.poll()
	var before := {
		"peer": _receiver.get_packet_peer(),
		"mode": _receiver.get_packet_mode(),
		"channel": _receiver.get_packet_channel(),
	}
	var first := _receiver.get_packet()
	var first_error := _receiver.get_packet_error()
	var next_mode := _receiver.get_packet_mode()
	var next_peer := _receiver.get_packet_peer()
	var next_channel := _receiver.get_packet_channel()
	var second := _receiver.get_packet()
	var second_error := _receiver.get_packet_error()
	var preserved := (
		before == {"peer": cached_peer, "mode": cached_mode, "channel": cached_channel}
		and first == unreliable
		and first_error == OK
		and next_peer == id
		and next_channel == 0
		and next_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		and second == reliable
		and second_error == OK
	)
	var consistent: bool = (
		before["peer"] == id
		and before["channel"] == 0
		and next_peer == id
		and next_channel == 0
		and first_error == OK
		and second_error == OK
		and (
			(
				first == unreliable
				and before["mode"] == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
				and second == reliable
				and next_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
			)
			or (
				first == reliable
				and before["mode"] == MultiplayerPeer.TRANSFER_MODE_RELIABLE
				and second == unreliable
				and next_mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
			)
		)
	)
	var reproduced: bool = (
		before["peer"] == id
		and before["mode"] == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		and first == reliable
		and first_error == OK
		and second == unreliable
		and second_error == OK
	)
	(
		_results
		. append(
			{
				"sender": id,
				"before": before,
				"first": first.get_string_from_utf8(),
				"second": second.get_string_from_utf8(),
				"next_mode": next_mode,
				"next_peer": next_peer,
				"next_channel": next_channel,
				"preserved": preserved,
				"consistent": consistent,
				"reproduced": reproduced,
			}
		)
	)
	return consistent or reproduced


func _wait_until(check: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and _errors.is_empty():
		if check.call():
			return true
		await get_tree().process_frame
	return false


func _finish(failure: String) -> void:
	set_process(false)
	_receiver.close()
	for sender: WebRTCMultiplayerPeer in _senders:
		sender.close()
	for connection: WebRTCPeerConnection in _connections:
		connection.close()
		for event: String in ["session_description_created", "ice_candidate_created"]:
			for subscription: Dictionary in connection.get_signal_connection_list(event):
				var callback: Callable = subscription["callable"]
				connection.disconnect(event, callback)
	var valid := failure.is_empty() and _errors.is_empty() and _results.size() == 2
	var report := {
		"engine": Engine.get_version_info()["string"],
		"valid": valid,
		"failure": failure,
		"errors": _errors,
		"packets": _results,
	}
	print("WEBRTC_METADATA_RESULT " + JSON.stringify(report))
	# Leave Web teardown to the page owner to avoid the audio startup race (#430).
	if not OS.has_feature("web"):
		get_tree().quit(0 if valid else 1)
