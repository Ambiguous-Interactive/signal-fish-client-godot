class_name SFWebRTCMesh
extends Node

## Opt-in WebRTC mesh glue (PLAN P3, issue #32). Attach to a
## [SignalFishClient] that negotiated a v3 session plan, and this node turns
## the server's signaling into a [WebRTCMultiplayerPeer] mesh: one peer
## connection per plan peer, offers/answers and ICE candidates relayed through
## [method SignalFishClient.send_signal]. Assign [method get_multiplayer_peer]
## to a [MultiplayerAPI] to run high-level multiplayer RPCs across the mesh.
##
## Signaling rules (upstream rust client [code]src/webrtc.rs[/code] +
## [code]src/mesh.rs[/code], v0.14.0):
## - The server assigns the offerer; the per-peer [code]initiate[/code] flag
##   (and [code]NewPeer.you_initiate[/code]) is obeyed verbatim — roles are
##   never computed locally.
## - The latest plan wins. Every plan fully replaces the previous one: peers
##   absent from the new plan are disconnected, and a retained peer is rebuilt
##   when its [code]initiate[/code] flag or the plan generation changed.
## - Inbound signals are accepted only from a known peer, on a [code]webrtc
##   [/code]-transport plan, with a matching generation; anything else is
##   discarded silently.
## - ICE servers are replaced (never merged) on every plan; an empty plan list
##   is an authoritative clear. TURN credentials stay out of logs (PLAN §12).
## - [method SignalFishClient.send_transport_status] is reported only at the
##   aggregate 0↔1 connected-peer boundaries.
## - The mesh is torn down on [signal room_left], [signal player_left],
##   [signal disconnected], and [signal reconnected]; a replayed plan inside
##   [code]missed_events[/code] can never revive it.
##
## Peer ids: [method uuid_to_peer_id] maps each player UUID to a deterministic
## positive integer (FNV-1a), so every mesh member derives the same
## [MultiplayerAPI] ids without extra negotiation.
##
## Platform notes: Godot 4 ships WebRTC on every platform (built-in
## libdatachannel module); browser exports use the browser's own WebRTC. Data
## channels come from [code]WebRTCMultiplayerPeer.initialize_mesh[/code]
## defaults (one reliable ordered channel).
##
## Tests inject [member peer_connection_factory] and
## [member multiplayer_peer_factory] instead of real engine objects (PLAN §8).

const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

## FNV-1a 64-bit constants for the deterministic UUID → peer-id mapping. The
## offset basis is the signed form of 0xcbf29ce484222325: GDScript clamps an
## unsigned 64-bit literal to INT64_MAX instead of wrapping.
const _FNV1A_OFFSET_BASIS := -3750763034362895579
const _FNV1A_PRIME := 1099511628211

## Injectable factory returning an object duck-typed to
## [WebRTCPeerConnection]. Empty Callable = the engine class.
var peer_connection_factory: Callable = Callable()

## Injectable factory returning an object duck-typed to
## [WebRTCMultiplayerPeer]. Empty Callable = the engine class.
var multiplayer_peer_factory: Callable = Callable()

var _client: SignalFishClientScript = null
var _plan = null
var _ice_servers: Array = []
var _peers: Dictionary = {}
var _mp_peer = null
var _reported_connected := false


## Starts consuming a client's session-plan events. The client must stay
## driven (its own polling pumps inbound events); this node's [code]
## _process[/code] pumps the peer connections.
func attach(client: SignalFishClientScript) -> Error:
	if client == null:
		return ERR_INVALID_PARAMETER
	if _client != null:
		return ERR_BUSY
	_client = client
	client.room_joined.connect(_on_client_room_joined)
	client.session_plan.connect(_on_client_session_plan)
	client.signal_received.connect(_on_client_signal_received)
	client.new_peer.connect(_on_client_new_peer)
	client.player_left.connect(_on_client_player_left)
	client.room_left.connect(_on_client_room_left)
	client.disconnected.connect(_on_client_disconnected)
	client.reconnected.connect(_on_client_reconnected)
	return OK


## Stops consuming events and tears the mesh down.
func detach() -> void:
	if _client == null:
		return
	_client.room_joined.disconnect(_on_client_room_joined)
	_client.session_plan.disconnect(_on_client_session_plan)
	_client.signal_received.disconnect(_on_client_signal_received)
	_client.new_peer.disconnect(_on_client_new_peer)
	_client.player_left.disconnect(_on_client_player_left)
	_client.room_left.disconnect(_on_client_room_left)
	_client.disconnected.disconnect(_on_client_disconnected)
	_client.reconnected.disconnect(_on_client_reconnected)
	_client = null
	_reset_mesh()


## Pumps every peer connection and reports connected-count boundaries. Called
## from [code]_process[/code]; call manually when driving without the tree.
func poll() -> void:
	for uuid: String in _peers:
		_peers[uuid].connection.poll()
	_update_transport_status()


## The mesh multiplayer peer, ready for [code]MultiplayerAPI.multiplayer_peer
## [/code]; null until the mesh holds at least one plan peer (and after
## teardown).
func get_multiplayer_peer():
	return _mp_peer


func get_peer_count() -> int:
	return _peers.size()


func get_peer_ids() -> Array:
	return _peers.keys()


## Deterministic, platform-stable player UUID → [MultiplayerAPI] peer id
## (FNV-1a over the UUID string, forced positive; nonzero so the id is always
## a valid non-server id).
static func uuid_to_peer_id(uuid: String) -> int:
	var digest := _FNV1A_OFFSET_BASIS
	for index: int in uuid.length():
		digest = ((digest ^ uuid.unicode_at(index)) * _FNV1A_PRIME) & 0x7FFFFFFFFFFFFFFF
	return maxi(digest, 1)


func _process(_delta: float) -> void:
	if _client == null:
		return
	poll()


func _exit_tree() -> void:
	detach()


func _on_client_room_joined(info) -> void:
	# A fresh room baseline: any stale mesh dies, and the pre-gathered ICE
	# list seeds connections opened before the first plan arrives.
	_reset_mesh()
	_ice_servers = info.ice_servers.duplicate()


func _on_client_session_plan(plan) -> void:
	_apply_plan(plan)


func _on_client_signal_received(from_player: String, generation: String, payload) -> void:
	if _plan == null or _plan.transport != SFSessionTypesScript.TransportKind.WEBRTC:
		return
	if generation != _plan.generation:
		return
	var entry = _peers.get(from_player)
	if entry == null:
		return
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var message: Dictionary = payload
	if message.has("Offer"):
		entry.connection.set_remote_description("offer", String(message["Offer"]))
	elif message.has("Answer"):
		entry.connection.set_remote_description("answer", String(message["Answer"]))
	elif message.has("IceCandidate"):
		# Matchbox convention relays the candidate string only; media and
		# index are not part of the Signal Fish signal payload.
		entry.connection.add_ice_candidate("", 0, String(message["IceCandidate"]))
	# Anything else is opaque and forward-compatible: discard silently.


func _on_client_new_peer(peer_id: String, you_initiate: bool) -> void:
	# Additive compatibility directive (upstream NewPeer): plan refreshes are
	# the primary membership mechanism; this obeys you_initiate verbatim.
	if _plan == null or _plan.transport != SFSessionTypesScript.TransportKind.WEBRTC:
		return
	if _peers.has(peer_id):
		return
	_open_peer(peer_id, you_initiate)


func _on_client_player_left(player_id: String) -> void:
	_drop_peer(player_id)


func _on_client_room_left() -> void:
	_reset_mesh()


func _on_client_disconnected(_code: int, _reason: String) -> void:
	_reset_mesh()


func _on_client_reconnected(_info, _missed_events: Array) -> void:
	# Replay delivers the missed events through this signal only, so the old
	# mesh cannot be revived by a replayed plan.
	_reset_mesh()


func _apply_plan(plan) -> void:
	_plan = plan
	# Replace, never merge: the plan's list governs connections opened from
	# here on, and an empty list is an authoritative clear.
	_ice_servers = plan.ice_servers.duplicate()
	var wanted: Dictionary = {}
	for peer in plan.peers:
		wanted[peer.player_id] = peer
	for uuid: String in wanted:
		var entry = _peers.get(uuid)
		if entry == null:
			continue
		if entry.initiate != wanted[uuid].initiate or entry.generation != plan.generation:
			# A retained connection may have been negotiated under a stale
			# role or a stale generation: rebuild it.
			_drop_peer(uuid)
	for uuid: String in wanted:
		if not _peers.has(uuid):
			_open_peer(uuid, wanted[uuid].initiate)
	for uuid: String in _peers.keys():
		if not wanted.has(uuid):
			_drop_peer(uuid)


func _open_peer(uuid: String, initiate: bool) -> void:
	if _client == null or uuid.is_empty() or uuid == _client.get_player_id():
		return
	var connection = _make_peer_connection()
	if connection == null:
		return
	var error: Error = connection.initialize(_rtc_configuration())
	if error != OK:
		SFLogScript.error("mesh: peer connection refused (%d)" % error)
		connection.close()
		return
	var multiplayer_peer = _multiplayer_peer()
	var entry := _MeshPeer.new()
	entry.uuid = uuid
	entry.peer_id = uuid_to_peer_id(uuid)
	entry.connection = connection
	entry.initiate = initiate
	entry.generation = _plan.generation if _plan != null else ""
	error = multiplayer_peer.add_peer(connection, entry.peer_id)
	if error != OK:
		SFLogScript.error("mesh: add_peer refused (%d)" % error)
		connection.close()
		return
	connection.session_description_created.connect(
		func(type: String, sdp: String) -> void: _on_peer_session_description(entry, type, sdp)
	)
	connection.ice_candidate_created.connect(
		func(media: String, index: int, candidate: String) -> void:
			_on_peer_ice_candidate(entry, media, index, candidate)
	)
	_peers[uuid] = entry
	if initiate:
		connection.create_offer()


func _drop_peer(uuid: String) -> void:
	var entry = _peers.get(uuid)
	if entry == null:
		return
	_peers.erase(uuid)
	if _mp_peer != null:
		_mp_peer.remove_peer(entry.peer_id)
	entry.connection.close()


func _reset_mesh() -> void:
	_plan = null
	_ice_servers = []
	for uuid: String in _peers.keys():
		_drop_peer(uuid)
	if _mp_peer != null:
		_mp_peer.close()
	_mp_peer = null
	# Teardown resolves the reported state silently: boundary reports are for
	# observed connected-count changes on a living session, never for a room
	# or connection that is already gone.
	_reported_connected = false


func _update_transport_status() -> void:
	if _client == null:
		return
	var connected := 0
	for uuid: String in _peers:
		if _peers[uuid].connection.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED:
			connected += 1
	if connected > 0 and not _reported_connected:
		_reported_connected = true
		_client.send_transport_status(SFSessionTypesScript.TransportKind.WEBRTC, true)
	elif connected == 0 and _reported_connected:
		_reported_connected = false
		_client.send_transport_status(SFSessionTypesScript.TransportKind.WEBRTC, false)


func _on_peer_session_description(entry, type: String, sdp: String) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	entry.connection.set_local_description(type, sdp)
	var payload: Dictionary = {}
	if type == "offer":
		payload["Offer"] = sdp
	elif type == "answer":
		payload["Answer"] = sdp
	else:
		return
	_send_signal_to(entry, payload)


func _on_peer_ice_candidate(entry, _media: String, _index: int, candidate: String) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	if candidate.is_empty():
		# End-of-candidates marker: nothing to relay or apply.
		return
	_send_signal_to(entry, {"IceCandidate": candidate})


func _send_signal_to(entry, payload: Dictionary) -> void:
	if _client == null:
		return
	_client.send_signal(entry.uuid, entry.generation, payload)


func _make_peer_connection():
	if peer_connection_factory.is_valid():
		return peer_connection_factory.call()
	return WebRTCPeerConnection.new()


func _make_multiplayer_peer():
	if multiplayer_peer_factory.is_valid():
		return multiplayer_peer_factory.call()
	return WebRTCMultiplayerPeer.new()


func _multiplayer_peer():
	if _mp_peer == null:
		_mp_peer = _make_multiplayer_peer()
		var my_id := uuid_to_peer_id(_client.get_player_id() if _client != null else "")
		_mp_peer.initialize_mesh(my_id)
	return _mp_peer


## [WebRTCPeerConnection] ICE configuration built from the current plan list.
## Credentials are values only: they are never logged.
func _rtc_configuration() -> Dictionary:
	var ice_servers: Array = []
	for server in _ice_servers:
		var entry: Dictionary = {"urls": Array(server.urls)}
		if not server.username.is_empty():
			entry["username"] = server.username
		if not server.credential.is_empty():
			entry["credential"] = server.credential
		ice_servers.append(entry)
	return {"iceServers": ice_servers}


class _MeshPeer:
	extends RefCounted
	var uuid: String = ""
	var peer_id: int = 0
	var connection = null
	var initiate: bool = false
	var generation: String = ""
