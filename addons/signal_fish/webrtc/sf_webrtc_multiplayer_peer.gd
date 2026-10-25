extends MultiplayerPeerExtension

## Opt-in RPC peer that keeps received bytes and channel metadata together.
## Use through SFWebRTCMesh.get_safe_multiplayer_peer() as the sole receiver.

var _mesh: WeakRef
var _peer: Object
var _closed := false
var _packet: RefCounted
var _packet_connection: Object
var _packet_revision := 0
var _connected: Dictionary = {}


func _init(mesh: Object, peer: Object) -> void:
	_mesh = weakref(mesh)
	_peer = peer


func _live_mesh() -> Object:
	if _closed:
		return null
	var mesh: Object = _mesh.get_ref()
	if (
		mesh == null
		or not mesh.call("_client_is_live")
		or mesh.call("get_multiplayer_peer") != _peer
	):
		_invalidate()
		return null
	return mesh


func _invalidate() -> void:
	_closed = true
	_packet = null
	_packet_connection = null
	_connected.clear()
	_peer = null


func _prefetch() -> bool:
	var mesh := _live_mesh()
	if mesh == null:
		return false
	var revision: int = mesh.get("_mesh_revision")
	if _packet != null:
		var sender: int = _packet.get("peer_id")
		if (
			_packet_revision != revision
			or not _peer.call("has_peer", sender)
			or (
				_packet_connection.call("get_connection_state")
				!= WebRTCPeerConnection.STATE_CONNECTED
			)
		):
			_packet = null
		else:
			var info: Dictionary = _peer.call("get_peer", sender)
			if info["connection"] != _packet_connection:
				_packet = null
			var channels: Array = info["channels"]
			if channels.size() != 3:
				_packet = null
			for channel: Object in channels:
				if channel.call("get_ready_state") != WebRTCDataChannel.STATE_OPEN:
					_packet = null
	if _packet == null:
		_packet_connection = null
		_packet = mesh.call("receive_packet")
		if _packet != null:
			_packet_revision = revision
			var sender: int = _packet.get("peer_id")
			var info: Dictionary = _peer.call("get_peer", sender)
			_packet_connection = info["connection"]
	return _packet != null


func _get_available_packet_count() -> int:
	if not _prefetch():
		return 0
	var count := 1
	var peers: Dictionary = _peer.call("get_peers")
	for info: Dictionary in peers.values():
		var connection: Object = info["connection"]
		if connection.call("get_connection_state") != WebRTCPeerConnection.STATE_CONNECTED:
			continue
		var channels: Array = info["channels"]
		var ready := channels.size() == 3
		for channel: Object in channels:
			if channel.call("get_ready_state") != WebRTCDataChannel.STATE_OPEN:
				ready = false
		if not ready:
			continue
		for channel: Object in channels:
			var queued: int = channel.call("get_available_packet_count")
			count += queued
	return count


func _get_packet_peer() -> int:
	return _packet.get("peer_id") if _prefetch() else 0


func _get_packet_mode() -> int:
	return _packet.get("transfer_mode") if _prefetch() else MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_packet_channel() -> int:
	return _packet.get("channel") if _prefetch() else 0


func _get_packet_script() -> PackedByteArray:
	if not _prefetch():
		return PackedByteArray()
	var packet := _packet
	_packet = null
	_packet_connection = null
	if packet.get("error") != OK:
		return PackedByteArray()
	return packet.get("data")


func _put_packet_script(buffer: PackedByteArray) -> int:
	if _live_mesh() == null:
		return ERR_UNCONFIGURED
	return _peer.call("put_packet", buffer)


func _poll() -> void:
	var mesh := _live_mesh()
	if mesh == null:
		return
	mesh.call("poll")
	if _live_mesh() == null:
		return
	_peer.call("poll")
	if _live_mesh() == null:
		return
	var peers: Dictionary = _peer.call("get_peers")
	var connected: Dictionary = {}
	for id: int in peers:
		var info: Dictionary = peers[id]
		if info["connected"]:
			connected[id] = info["connection"]
	for id: int in _connected.keys():
		if not _connected.has(id):
			continue
		if connected.get(id) != _connected[id]:
			_connected.erase(id)
			peer_disconnected.emit(id)
			if _live_mesh() == null:
				return
	for id: int in connected:
		if not _peer.call("has_peer", id):
			continue
		var info: Dictionary = _peer.call("get_peer", id)
		if info["connection"] != connected[id] or not info["connected"]:
			continue
		if not _connected.has(id):
			_connected[id] = connected[id]
			peer_connected.emit(id)
			if _live_mesh() == null:
				return


func _close() -> void:
	var mesh := _live_mesh()
	_invalidate()
	if mesh != null:
		mesh.call("_reset_mesh")


func _disconnect_peer(id: int, force: bool) -> void:
	var mesh := _live_mesh()
	if mesh == null:
		return
	var peers: Dictionary = mesh.get("_peers")
	for uuid: String in peers.keys():
		var entry: Object = peers[uuid]
		if entry.get("peer_id") == id:
			mesh.call("_drop_peer", uuid)
			if force:
				_connected.erase(id)
			return


func _get_connection_status() -> int:
	if _live_mesh() == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return _peer.call("get_connection_status")


func _get_unique_id() -> int:
	return _peer.call("get_unique_id") if _live_mesh() != null else 0


func _get_max_packet_size() -> int:
	# Godot 4.3 WebRTCMultiplayerPeer::get_max_packet_size().
	return 1200


func _is_server() -> bool:
	return false


func _is_server_relay_supported() -> bool:
	return false


func _set_target_peer(id: int) -> void:
	if _live_mesh() != null:
		_peer.call("set_target_peer", id)


func _get_transfer_mode() -> int:
	if _live_mesh() == null:
		return MultiplayerPeer.TRANSFER_MODE_RELIABLE
	return _peer.get("transfer_mode")


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	if _live_mesh() != null:
		_peer.set("transfer_mode", mode)


func _get_transfer_channel() -> int:
	return _peer.get("transfer_channel") if _live_mesh() != null else 0


func _set_transfer_channel(channel: int) -> void:
	if _live_mesh() != null:
		_peer.set("transfer_channel", channel)


func _is_refusing_new_connections() -> bool:
	return _peer.get("refuse_new_connections") if _live_mesh() != null else true


func _set_refuse_new_connections(enable: bool) -> void:
	if _live_mesh() != null:
		_peer.set("refuse_new_connections", enable)
