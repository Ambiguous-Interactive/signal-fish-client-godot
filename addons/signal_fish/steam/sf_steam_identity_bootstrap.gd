class_name SFSteamIdentityBootstrap
extends Node

## Steam P2P identity bootstrap (issue #312): puts Steam relay traffic on a
## Signal Fish room, mirroring the dotnet client's Steamworks.NET adapter.
## Steam has no matchmaking, so the room itself is the fence: the Signal Fish
## room owns membership, heartbeats, and reconnection-ready sessions, while
## Steam's relay network carries the game traffic. The bootstrap is a
## coordination component, not a transport bridge - it establishes and fences
## the Steam connections, and the game owns what flows over them. The only
## thing exchanged is a pair of SteamId64s, published by role over the room's
## game-data lane (see [SFSteamIdentity]).
##
## The flow, end to end: the host joins the room, takes the authority, and
## publishes its id ([signal room_joined], re-published on every later join,
## so late joiners never depend on timing). A peer joins, publishes its own
## id, consumes the host id, and dials it. The fence: Steam's rendezvous
## authenticates the connecting identity (the claim is Steam's, not the
## peer's), so the host only checks that the connecting id was advertised on
## the room's lane - an unknown requester waits [member accept_grace_sec] for
## its advertisement and is refused if it never comes.
##
## The Steam side rides GodotSteam's classic P2P API, resolved at
## [method start] through the [code]Steam[/code] Engine singleton (or the
## injected [member steam] seam). That API is session-less: there is no
## listen call (the host simply answers [code]p2p_session_request[/code]) and
## no connect callback, so the dial is a poke on [member steam_channel] and
## the host's reply is the "connected" event. The bootstrap channel carries
## only this handshake; game traffic uses its own channel(s) and
## [code]readP2PPacket[/code] calls. Initialize Steamworks and pump its
## callbacks (GodotSteam's [code]run_callbacks()[/code] or embedded mode)
## before [method start]; this node never touches them. Steamworks has no
## session-closed callback on this API, so disconnects are best-effort:
## [method poll] watches [code]getP2PSessionState[/code] for tracked peers.
##
## Live-session failures surface as [signal coordination_failed] and stop the
## coordination (the signals stop with it). Membership enforcement beyond the
## accept fence - room leave/rejoin races, the host leaving while peers hold
## connections - stays the game's job.

## The published host id arrived on the lane. Informational: the bootstrap
## dials by itself.
signal steam_host_id_received(steam_id: String)
## The peer's session to the host is up (the host's handshake reply arrived).
signal steam_host_connected(steam_id: String)
## The host accepted a fenced peer's Steam connection.
signal steam_peer_connected(steam_id: String)
## A fenced peer's Steam session went down (best-effort detection).
signal steam_peer_disconnected(steam_id: String)
## A live-session failure stopped the coordination: the room connection
## closed, the authority left the host, the published host id changed
## mid-session, or a Steam dial timed out or failed.
signal coordination_failed(reason: String)

## Who this node coordinates as: the [enum Role.HOST] fences Steam accepts
## behind the lane, a [enum Role.PEER] dials the published host id.
enum Role { PEER, HOST }

const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSteamIdentityScript = preload("res://addons/signal_fish/steam/sf_steam_identity.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

## GodotSteam's [code]P2P_SEND_RELIABLE[/code] (Steamworks
## [code]k_EP2PSendReliable[/code]), pinned so the duck-typed seam needs no
## constant lookup. The handshake is one byte; reliable delivery is free.
const P2P_SEND_RELIABLE := 2

const _POKE_BYTE := 0x53
const _ACK_BYTE := 0x41

## How long the host waits for an unknown requester's lane advertisement
## before refusing the session. Zero refuses every requester that was not
## already advertised.
var accept_grace_sec: float = 5.0
## How long a peer waits for the host's published id before the coordination
## fails. Zero waits forever.
var host_id_timeout_sec: float = 30.0
## How long a peer's Steam dial may take (poke to handshake reply) before the
## coordination fails. Zero waits forever - Steam's own dial timeout still
## reports through [code]p2p_session_connect_fail[/code].
var steam_connect_timeout_sec: float = 30.0
## The P2P channel the bootstrap exchanges its handshake on. The game owns
## every other channel and must stay off this one.
var steam_channel: int = 1
## Duck-typed Steam seam (the GodotSteam singleton surface). Null resolves
## [code]Engine.get_singleton("Steam")[/code] at [method start]; tests inject
## a fake. Never reference the bare [code]Steam[/code] identifier: the script
## must keep parsing without the extension installed.
var steam: Object = null
## Which side of the fence this node coordinates as.
var role: Role = Role.PEER

var _client: SignalFishClientScript = null
var _coordinating := false
var _local_id := ""
var _host_id := ""
var _host_connected := false
var _elapsed_sec := 0.0
var _awaiting_host_id := false
var _host_id_deadline_sec := 0.0
var _awaiting_ack := false
var _ack_deadline_sec := 0.0
# Host state: the advertised-membership set only grows during a session (a
# member that leaves keeps its entry until the session ends), matching the
# dotnet adapter's fence semantics.
var _advertised_peers: Dictionary = {}
var _pending_requests: Dictionary = {}
var _connected_peers: Dictionary = {}


## Starts consuming a client's session events. Attach before [method start].
func attach(client: SignalFishClientScript) -> Error:
	if client == null:
		return ERR_INVALID_PARAMETER
	_client_is_live()
	if _client != null:
		return ERR_BUSY
	_client = client
	client.room_joined.connect(_on_client_room_joined)
	client.room_left.connect(_on_client_room_left)
	client.player_joined.connect(_on_client_player_joined)
	client.game_data_received.connect(_on_client_game_data)
	client.authority_changed.connect(_on_client_authority_changed)
	client.disconnected.connect(_on_client_disconnected)
	return OK


## Stops consuming events and tears the coordination down.
func detach() -> void:
	if _client == null:
		return
	_client_is_live()
	if _client == null:
		return
	_client.room_joined.disconnect(_on_client_room_joined)
	_client.room_left.disconnect(_on_client_room_left)
	_client.player_joined.disconnect(_on_client_player_joined)
	_client.game_data_received.disconnect(_on_client_game_data)
	_client.authority_changed.disconnect(_on_client_authority_changed)
	_client.disconnected.disconnect(_on_client_disconnected)
	_client = null
	stop()


## Begins coordinating on the attached client. Fails loudly when Steam is not
## available or the Steamworks API is not initialized (id 0), so a silent
## no-op can never masquerade as a fenced session.
func start() -> Error:
	if _client == null or not _client_is_live():
		return ERR_INVALID_PARAMETER
	if _coordinating:
		return ERR_BUSY
	if (
		accept_grace_sec < 0.0
		or host_id_timeout_sec < 0.0
		or steam_connect_timeout_sec < 0.0
		or steam_channel < 0
	):
		return ERR_INVALID_PARAMETER
	if steam == null:
		steam = Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if (
		steam == null
		or not steam.has_method("getSteamID")
		or not steam.has_signal("p2p_session_request")
		or not steam.has_signal("p2p_session_connect_fail")
	):
		SFLogScript.error(
			(
				"steam bootstrap: GodotSteam is not available; install the GDExtension"
				+ " and initialize Steamworks before start()"
			)
		)
		return ERR_UNAVAILABLE
	_local_id = str(steam.call("getSteamID"))
	if not SFSteamIdentityScript.is_valid_steam_id(_local_id):
		SFLogScript.error("steam bootstrap: getSteamID() returned no usable id")
		return ERR_UNAVAILABLE
	steam.connect("p2p_session_request", _on_steam_session_request)
	steam.connect("p2p_session_connect_fail", _on_steam_connect_fail)
	_coordinating = true
	if _client_is_in_room():
		_on_session_live()
	return OK


## Stops coordinating and closes every Steam session the bootstrap
## established. No further signals fire after this.
func stop() -> void:
	_close_tracked_sessions()
	_reset_coordination()


## Pumps grace-window expiries, handshake packets, dial deadlines, and
## best-effort disconnect detection. Called from [code]_process[/code] while
## coordinating; call manually when driving without the tree.
func poll() -> void:
	if not _coordinating:
		return
	_expire_pending_requests()
	if not _coordinating:
		return
	_pump_handshake_channel()
	if not _coordinating:
		return
	_check_dial_deadlines()
	if not _coordinating:
		return
	_detect_session_drops()


func get_local_steam_id() -> String:
	return _local_id


## The consumed host id (peer side); empty until [signal
## steam_host_id_received].
func get_host_steam_id() -> String:
	return _host_id


func is_coordinating() -> bool:
	return _coordinating


func _process(delta: float) -> void:
	if not _coordinating:
		return
	_elapsed_sec += delta
	poll()


func _exit_tree() -> void:
	detach()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()


func _on_session_live() -> void:
	if role == Role.HOST:
		var error: Error = _client.request_authority(true)
		if error != OK:
			SFLogScript.warn("steam bootstrap: authority request refused (%d)" % error)
		_publish(SFSteamIdentityScript.HOST_LANE_KEY)
		return
	_publish(SFSteamIdentityScript.PEER_LANE_KEY)
	# The client re-emits room_joined on every RoomJoined baseline (issue
	# 107); only the first one arms the host-id wait.
	if host_id_timeout_sec > 0.0 and _host_id.is_empty():
		_awaiting_host_id = true
		_host_id_deadline_sec = _elapsed_sec + host_id_timeout_sec


func _publish(lane_key: String) -> void:
	var envelope: Dictionary = {}
	if lane_key == SFSteamIdentityScript.HOST_LANE_KEY:
		envelope = SFSteamIdentityScript.host_envelope(_local_id)
	else:
		envelope = SFSteamIdentityScript.peer_envelope(_local_id)
	if envelope.is_empty():
		_fail_coordination("local id %s does not fit the lane envelope" % _local_id)
		return
	var error: Error = _client.send_game_data(envelope)
	if error != OK:
		# The next join re-publishes; a transient send failure (for example
		# backpressure) must not kill the coordination on its own.
		SFLogScript.warn(
			(
				"steam bootstrap: %s publish failed (%d); re-publishes on the next join"
				% [lane_key, error]
			)
		)


func _on_client_room_joined(_info: SFTypesScript.RoomJoinedInfo) -> void:
	if _coordinating and _client != null:
		_on_session_live()


func _on_client_room_left() -> void:
	_fail_coordination("the room session ended")


func _on_client_player_joined(_player: SFTypesScript.PlayerInfo) -> void:
	if _coordinating and _client != null and _client_is_in_room():
		_publish(
			(
				SFSteamIdentityScript.HOST_LANE_KEY
				if role == Role.HOST
				else SFSteamIdentityScript.PEER_LANE_KEY
			)
		)


func _on_client_game_data(from_player: String, data: Variant) -> void:
	if not _coordinating:
		return
	var host_id := SFSteamIdentityScript.read_host(data)
	if not host_id.is_empty():
		_consume_host_id(host_id)
		return
	var peer_id := SFSteamIdentityScript.read_peer(data)
	if not peer_id.is_empty():
		_advertise_peer(peer_id, from_player)


func _on_client_authority_changed(_authority_player: String, you_are_authority: bool) -> void:
	if _coordinating and role == Role.HOST and not you_are_authority:
		_fail_coordination("authority left the host; the fence has no holder")


func _on_client_disconnected(_code: int, _reason: String) -> void:
	_fail_coordination("the room connection closed")


func _on_steam_session_request(remote_steam_id: int) -> void:
	if not _coordinating or role != Role.HOST:
		_refuse_request(remote_steam_id, "not hosting")
		return
	var peer_id := str(remote_steam_id)
	if _connected_peers.has(peer_id):
		# A repeat request for an already-fenced session re-accepts.
		steam.call("acceptP2PSessionWithUser", remote_steam_id)
		return
	if _advertised_peers.has(peer_id):
		_accept_peer(peer_id)
		return
	if accept_grace_sec <= 0.0:
		_refuse_request(remote_steam_id, "id not advertised on the lane")
		return
	_pending_requests[peer_id] = _elapsed_sec + accept_grace_sec


func _on_steam_connect_fail(remote_steam_id: int, session_error: int) -> void:
	if not _coordinating or role != Role.PEER:
		return
	if str(remote_steam_id) != _host_id:
		return
	_fail_coordination("the Steam dial failed (session error %d)" % session_error)


func _consume_host_id(host_id: String) -> void:
	if role != Role.PEER:
		return
	if _host_id.is_empty():
		_host_id = host_id
		steam_host_id_received.emit(_host_id)
		# A handler may have stopped the coordination inside the signal; the
		# dial must not outlive it.
		if not _coordinating:
			return
		_awaiting_host_id = false
		_host_id_deadline_sec = 0.0
		_dial_host()
		return
	if _host_id != host_id:
		_fail_coordination("the published host id changed mid-session")


func _dial_host() -> void:
	_awaiting_ack = true
	if steam_connect_timeout_sec > 0.0:
		_ack_deadline_sec = _elapsed_sec + steam_connect_timeout_sec
	var sent: Variant = steam.call(
		"sendP2PPacket",
		_host_id.to_int(),
		PackedByteArray([_POKE_BYTE]),
		P2P_SEND_RELIABLE,
		steam_channel
	)
	if not (sent is bool) or not sent:
		_fail_coordination("the Steam dial to %s was refused" % _host_id)


func _advertise_peer(peer_id: String, from_player: String) -> void:
	if role != Role.HOST:
		return
	SFLogScript.debug("steam bootstrap: lane advertised %s from %s" % [peer_id, from_player])
	_advertised_peers[peer_id] = true
	if _pending_requests.has(peer_id):
		_accept_peer(peer_id)


func _accept_peer(peer_id: String) -> void:
	_pending_requests.erase(peer_id)
	if _connected_peers.has(peer_id):
		return
	var accepted: Variant = steam.call("acceptP2PSessionWithUser", peer_id.to_int())
	if not (accepted is bool) or not accepted:
		SFLogScript.error("steam bootstrap: accept refused for %s" % peer_id)
		return
	_connected_peers[peer_id] = true
	# The handshake reply is the peer-side "connected" event: the classic P2P
	# API has no connect-success callback.
	steam.call(
		"sendP2PPacket",
		peer_id.to_int(),
		PackedByteArray([_ACK_BYTE]),
		P2P_SEND_RELIABLE,
		steam_channel
	)
	steam_peer_connected.emit(peer_id)


func _refuse_request(remote_steam_id: int, why: String) -> void:
	_pending_requests.erase(str(remote_steam_id))
	steam.call("closeP2PSessionWithUser", remote_steam_id)
	SFLogScript.warn("steam bootstrap: refused %d (%s)" % [remote_steam_id, why])


func _expire_pending_requests() -> void:
	for peer_id: String in _pending_requests.keys():
		var deadline: float = _pending_requests[peer_id]
		if _elapsed_sec < deadline:
			continue
		_refuse_request(peer_id.to_int(), "lane advertisement never arrived")


func _pump_handshake_channel() -> void:
	var size: int = steam.call("getAvailableP2PPacketSize", steam_channel)
	while size > 0:
		var packet: Variant = steam.call("readP2PPacket", size, steam_channel)
		size = steam.call("getAvailableP2PPacketSize", steam_channel)
		if typeof(packet) != TYPE_DICTIONARY:
			continue
		var frame: Dictionary = packet
		if frame.is_empty():
			continue
		# Both key spellings exist across GodotSteam versions.
		var from: Variant = frame.get("remote_steam_id", frame.get("steam_id_remote", 0))
		if role == Role.HOST:
			continue
		if (
			_awaiting_ack
			and str(from) == _host_id
			and frame["data"] == PackedByteArray([_ACK_BYTE])
		):
			_awaiting_ack = false
			_host_connected = true
			steam_host_connected.emit(_host_id)
		if not _coordinating:
			return


func _check_dial_deadlines() -> void:
	if _awaiting_host_id and host_id_timeout_sec > 0.0 and _elapsed_sec >= _host_id_deadline_sec:
		_fail_coordination("the host id did not arrive in time")
		return
	if _awaiting_ack and steam_connect_timeout_sec > 0.0 and _elapsed_sec >= _ack_deadline_sec:
		_fail_coordination("the Steam dial timed out")


func _detect_session_drops() -> void:
	for peer_id: String in _connected_peers.keys():
		if _session_is_active(peer_id.to_int()):
			continue
		_connected_peers.erase(peer_id)
		steam_peer_disconnected.emit(peer_id)
		# A handler may have stopped the coordination inside the signal; the
		# documented contract is that no signals follow stop().
		if not _coordinating:
			return
	if _host_connected and not _session_is_active(_host_id.to_int()):
		_host_connected = false
		_fail_coordination("the host Steam session closed")


func _session_is_active(remote_steam_id: int) -> bool:
	var state: Variant = steam.call("getP2PSessionState", remote_steam_id)
	if typeof(state) != TYPE_DICTIONARY:
		return false
	var session_state: Dictionary = state
	if session_state.is_empty():
		return false
	var active: bool = session_state.get("connection_active", true)
	return active


func _fail_coordination(reason: String) -> void:
	if not _coordinating:
		return
	SFLogScript.error("steam bootstrap: %s" % reason)
	# A dial that never completed leaves a half-open session the game never
	# owned; an established session always belongs to the game (stop() is the
	# only path that closes fenced sessions).
	if role == Role.PEER and _awaiting_ack and not _host_id.is_empty():
		steam.call("closeP2PSessionWithUser", _host_id.to_int())
	_reset_coordination()
	coordination_failed.emit(reason)


func _close_tracked_sessions() -> void:
	if steam == null:
		return
	var closed := _connected_peers.keys()
	if role == Role.PEER and not _host_id.is_empty():
		closed.append(_host_id)
	for peer_id: String in closed:
		steam.call("closeP2PSessionWithUser", peer_id.to_int())


func _reset_coordination() -> void:
	_coordinating = false
	# Steam listeners stop with the coordination: a failed session must not
	# keep answering requests, and the next start() reconnects them cleanly.
	if steam != null and steam.has_signal("p2p_session_request"):
		if steam.is_connected("p2p_session_request", _on_steam_session_request):
			steam.disconnect("p2p_session_request", _on_steam_session_request)
		if steam.is_connected("p2p_session_connect_fail", _on_steam_connect_fail):
			steam.disconnect("p2p_session_connect_fail", _on_steam_connect_fail)
	_awaiting_host_id = false
	_awaiting_ack = false
	_host_connected = false
	_host_id = ""
	_local_id = ""
	_elapsed_sec = 0.0
	_advertised_peers = {}
	_pending_requests = {}
	_connected_peers = {}


func _client_is_live() -> bool:
	if _client == null:
		return false
	if not is_instance_valid(_client):
		_client = null
		return false
	return true


func _client_is_in_room() -> bool:
	var state: int = _client.get_session_state()
	return (
		state == SignalFishClientScript.SessionState.IN_ROOM_WAITING
		or state == SignalFishClientScript.SessionState.IN_ROOM_LOBBY
		or state == SignalFishClientScript.SessionState.IN_ROOM_FINALIZED
	)
