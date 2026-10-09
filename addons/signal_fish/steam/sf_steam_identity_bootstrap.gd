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
## publishes its id ([signal room_joined], re-published on every later join
## and on every peer advertisement, so late joiners never depend on timing).
## A peer joins, publishes its own id, consumes the host id, and dials it.
## The fence: Steam's rendezvous authenticates the connecting identity (the
## claim is Steam's, not the peer's), so the host only checks that the
## connecting id was advertised on the room's lane - an unknown requester
## waits [member accept_grace_sec] for its advertisement and is refused if it
## never comes. The lane itself is fenced too: the published host id is only
## consumed from the room's authority, and an advertisement belongs to the
## member that published it, leaving with them (issue #338).
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
## [method poll] watches [code]getP2PSessionState[/code], and a session only
## reports a drop after it was seen active (setup reports
## [code]connecting[/code]).
##
## Live-session failures surface as [signal coordination_failed] and stop the
## coordination (the signals stop with it). Membership enforcement beyond the
## accept fence - room leave/rejoin races, the host leaving while peers hold
## connections - stays the game's job. The room must have authority enabled:
## the host lane binds to the room's authority, and a room without one is
## refused by [method start] or fails with its first baseline (issue #338).

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
## closed, the room session ended, the room has no authority holder, the
## authority left the host, the published host id changed mid-session, the
## host Steam session closed, or a Steam dial timed out or failed.
signal coordination_failed(reason: String)

## Who this node coordinates as: the [enum Role.HOST] fences Steam accepts
## behind the lane, a [enum Role.PEER] dials the published host id.
enum Role { PEER, HOST }

const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFSteamIdentityScript = preload("res://addons/signal_fish/steam/sf_steam_identity.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

## GodotSteam's [code]P2P_SEND_RELIABLE[/code] (Steamworks
## [code]k_EP2PSendReliable[/code]), pinned so the duck-typed seam needs no
## constant lookup. The handshake is one byte; reliable delivery is free.
const P2P_SEND_RELIABLE := 2

## Handshake packets drained per [method poll], mirroring the WebSocket
## transport's per-poll cap: a seam that reports available bytes without ever
## consuming them must not spin the frame (issue #335).
const DEFAULT_MAX_PACKETS_PER_POLL := 64

## Handshake bytes drained per [method poll], the inbound 256 KiB frame
## philosophy: a hostile id queuing max-size packets must not turn one poll
## into tens of megabytes of allocations (issue #338).
const DEFAULT_MAX_BYTES_PER_POLL := 262144

## Grace windows (the first request plus re-arms) one id may consume before
## its further requests are refused for the rest of the session. An id that
## re-requests faster than the grace expires would otherwise hold a pending
## slot forever (issue #338).
const MAX_REQUEST_ATTEMPTS := 8

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
## Handshake packets drained per [method poll] (issue #335).
var max_packets_per_poll: int = DEFAULT_MAX_PACKETS_PER_POLL
## Handshake bytes drained per [method poll] (issue #338). A packet larger
## than the remaining budget still drains alone: classic P2P offers no
## peek-and-skip, so the per-poll residual is one packet of whatever size the
## seam reports, and the rest of the queue waits for the next poll.
var max_bytes_per_poll: int = DEFAULT_MAX_BYTES_PER_POLL
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
# Host state: the advertised-membership set is owned by the room player that
# published the id and leaves with them (player_left and every room baseline
# reconcile it; issue #338), bounded at MAX_TRACKED_PEERS like every
# wire-driven roster (issue #335).
var _advertised_peers: Dictionary = {}
var _pending_requests: Dictionary = {}
# Grace windows consumed per id. A refusal keeps counting so a re-request
# loop burns out instead of holding a pending slot forever; an accept clears
# the id (issue #338). Bounded at MAX_TRACKED_PEERS.
var _request_attempts: Dictionary = {}
var _connected_peers: Dictionary = {}
# Sessions report connecting/inactive while Steam sets the channel up, so a
# peer drop is only reported for a session that was seen active (or that
# Steam failed through p2p_session_connect_fail). The peer's host session
# needs no such grace: the ack proves it was established.
var _ever_active_peers: Dictionary = {}


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
	client.player_left.connect(_on_client_player_left)
	client.game_data_received.connect(_on_client_game_data)
	client.authority_changed.connect(_on_client_authority_changed)
	client.disconnected.connect(_on_client_disconnected)
	return OK


## Stops consuming events and tears the coordination down.
func detach() -> void:
	if _client != null and is_instance_valid(_client):
		_client.room_joined.disconnect(_on_client_room_joined)
		_client.room_left.disconnect(_on_client_room_left)
		_client.player_joined.disconnect(_on_client_player_joined)
		_client.player_left.disconnect(_on_client_player_left)
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
		or max_packets_per_poll < 1
		or max_bytes_per_poll < 1
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
	# The same authority-less refusal the baseline path applies, for a room
	# the client joined before start() (Bugbot, PR #349).
	if _client_is_in_room() and not _client.get_supports_authority():
		SFLogScript.error("steam bootstrap: the room has no authority to fence the host lane with")
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


## Stops coordinating and closes every Steam session the bootstrap opened.
## No further signals fire after this.
func stop() -> void:
	_close_tracked_sessions()
	_reset_coordination()


## Pumps grace-window expiries, handshake packets, dial deadlines, and
## best-effort disconnect detection. Called from [code]_process[/code] while
## coordinating; call manually when driving without the tree.
func poll() -> void:
	if not _coordinating:
		return
	if not _client_is_live():
		_fail_coordination("the attached client vanished")
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
	# 107); the host-id wait arms exactly once, on the first one.
	if host_id_timeout_sec > 0.0 and _host_id.is_empty() and not _awaiting_host_id:
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


func _on_client_room_joined(info: SFTypesScript.RoomJoinedInfo) -> void:
	if _coordinating and _client != null:
		# The host lane binds to the room's authority (issue #338): a room
		# without one has no fence for the lane, so the coordination refuses
		# here instead of dying later in a misleading dial timeout.
		if not info.supports_authority:
			_fail_coordination("the room has no authority to fence the host lane with")
			return
		_reconcile_advertised_roster(info)
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


func _on_client_player_left(player_id: String) -> void:
	if not _coordinating:
		return
	for peer_id: String in _advertised_peers.keys():
		if _advertised_peers[peer_id] == player_id:
			_advertised_peers.erase(peer_id)


## A room baseline is the membership truth: fence entries whose owner is no
## longer in the roster leave with it, so a missed player_left cannot leave a
## stale entry behind (issue #338). Only room players are fenced: an owner
## that appears in later baselines solely as a spectator leaves too.
func _reconcile_advertised_roster(info: SFTypesScript.RoomJoinedInfo) -> void:
	var members := {}
	for player: SFTypesScript.PlayerInfo in info.current_players:
		members[player.id] = true
	for peer_id: String in _advertised_peers.keys():
		if not members.has(_advertised_peers[peer_id]):
			_advertised_peers.erase(peer_id)


func _on_client_game_data(from_player: String, data: Variant) -> void:
	if not _coordinating:
		return
	var host_id := SFSteamIdentityScript.read_host(data)
	if not host_id.is_empty():
		# The host lane belongs to the room's authority: a host id consumed
		# from any other sender would let one member redirect every dial, or
		# kill the whole session with one changed id (issue #338).
		if from_player == _client.get_authority_player():
			_consume_host_id(host_id)
		else:
			SFLogScript.debug(
				"steam bootstrap: host id from non-authority %s ignored" % from_player
			)
		return
	var peer_id := SFSteamIdentityScript.read_peer(data)
	if not peer_id.is_empty():
		_advertise_peer(peer_id, from_player)


func _on_client_authority_changed(_authority_player: String, you_are_authority: bool) -> void:
	if not _coordinating or role != Role.HOST:
		return
	if you_are_authority:
		# A grant landing after the session-live publish would leave peers
		# ignoring every host envelope until a later join re-publishes; the
		# grant itself re-publishes (Bugbot, PR #349).
		_publish(SFSteamIdentityScript.HOST_LANE_KEY)
		return
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
	# An id that keeps re-requesting must not hold a pending slot forever:
	# once it has consumed MAX_REQUEST_ATTEMPTS grace windows, its further
	# requests are refused for the rest of the session (issue #338).
	if _request_attempts.get(peer_id, 0) >= MAX_REQUEST_ATTEMPTS:
		_refuse_request(remote_steam_id, "request attempts exhausted for the session")
		return
	# The cap only refuses new waiters: a repeat request from an id already
	# in the grace window just re-arms its deadline (Bugbot, PR #336).
	if not _pending_requests.has(peer_id):
		if _pending_requests.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
			_refuse_request(
				remote_steam_id, "pending fence requests at cap %d" % SFTypeUtils.MAX_TRACKED_PEERS
			)
			return
		if (
			not _request_attempts.has(peer_id)
			and _request_attempts.size() >= SFTypeUtils.MAX_TRACKED_PEERS
		):
			_refuse_request(
				remote_steam_id, "request accounting at cap %d" % SFTypeUtils.MAX_TRACKED_PEERS
			)
			return
	_request_attempts[peer_id] = _request_attempts.get(peer_id, 0) + 1
	_pending_requests[peer_id] = _elapsed_sec + accept_grace_sec


func _on_steam_connect_fail(remote_steam_id: int, session_error: int) -> void:
	if not _coordinating:
		return
	if role == Role.HOST:
		var peer_id := str(remote_steam_id)
		if _connected_peers.has(peer_id):
			_drop_peer(peer_id, "the Steam session failed (session error %d)" % session_error)
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
	var first_advertisement := not _advertised_peers.has(peer_id)
	if first_advertisement:
		if _advertised_peers.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
			# A flood of unique ids must not grow the fence set or amplify
			# into a room-wide re-publish per id (issue #335). A pending
			# request from the refused id expires on schedule: the fence
			# never accepts an id the set could not record.
			SFLogScript.error(
				(
					"steam bootstrap: advertised peers at cap %d; id not fenced"
					% SFTypeUtils.MAX_TRACKED_PEERS
				)
			)
			return
		_advertised_peers[peer_id] = from_player
	if _pending_requests.has(peer_id):
		_accept_peer(peer_id)
	# The advertisement proves a peer is coordinating without a fresh join
	# event (a late start()); re-publish so its host-id wait can finish.
	if first_advertisement:
		_publish(SFSteamIdentityScript.HOST_LANE_KEY)


func _accept_peer(peer_id: String) -> void:
	_pending_requests.erase(peer_id)
	# A fenced id is a member: its window count is spent, so a session that
	# drops and re-requests starts clean (issue #338).
	_request_attempts.erase(peer_id)
	if _connected_peers.has(peer_id):
		return
	var accepted: Variant = steam.call("acceptP2PSessionWithUser", peer_id.to_int())
	if not (accepted is bool) or not accepted:
		# A refused accept leaves the poke's session unowned; close it now
		# (the dotnet adapter's accept path does the same).
		steam.call("closeP2PSessionWithUser", peer_id.to_int())
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
	var drained_packets := 0
	var drained_bytes := 0
	while size > 0 and drained_packets < max_packets_per_poll:
		if drained_bytes >= max_bytes_per_poll:
			break
		drained_packets += 1
		drained_bytes += size
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
		var state: Dictionary = _session_state(peer_id.to_int())
		if not state.is_empty() and _is_active(state):
			_ever_active_peers[peer_id] = true
			continue
		# Steam reports a just-accepted session as connecting/inactive while
		# it sets the channel up, and never-active sessions fail through
		# p2p_session_connect_fail. Only a session seen active can drop.
		if _ever_active_peers.has(peer_id):
			_drop_peer(peer_id, "the peer Steam session closed")
		if not _coordinating:
			return
	if _host_connected and not _host_session_alive():
		_host_connected = false
		_fail_coordination("the host Steam session closed")


func _session_state(remote_steam_id: int) -> Dictionary:
	var state: Variant = steam.call("getP2PSessionState", remote_steam_id)
	if typeof(state) != TYPE_DICTIONARY:
		return {}
	return state


func _is_active(state: Dictionary) -> bool:
	var active: bool = state.get("connection_active", false)
	return active


func _is_connecting(state: Dictionary) -> bool:
	var connecting: bool = state.get("connecting", false)
	return connecting


func _host_session_alive() -> bool:
	# The ack already proved the session was established, so a state that is
	# no longer active (and not connecting) is a real drop; Steam raises no
	# connect fail for a session that dies after the handshake.
	var state: Dictionary = _session_state(_host_id.to_int())
	if not state.is_empty() and _is_active(state):
		return true
	return _is_connecting(state)


func _drop_peer(peer_id: String, why: String) -> void:
	_connected_peers.erase(peer_id)
	_ever_active_peers.erase(peer_id)
	SFLogScript.info("steam bootstrap: %s dropped (%s)" % [peer_id, why])
	steam_peer_disconnected.emit(peer_id)


func _fail_coordination(reason: String) -> void:
	if not _coordinating:
		return
	SFLogScript.error("steam bootstrap: %s" % reason)
	# A dial that never completed leaves a half-open session the game never
	# owned; an established session always belongs to the game (stop() is the
	# only path that closes fenced sessions). The same holds for a fence
	# request that was never accepted or refused.
	if role == Role.PEER and _awaiting_ack and not _host_id.is_empty():
		steam.call("closeP2PSessionWithUser", _host_id.to_int())
	_close_pending_requests()
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
	_close_pending_requests()


## A fence request that was neither accepted nor refused still opened a Steam
## session; nobody owns it once the coordination stops, so failure and stop
## both close it (the dotnet adapter's teardown does the same).
func _close_pending_requests() -> void:
	for peer_id: String in _pending_requests.keys():
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
	_request_attempts = {}
	_connected_peers = {}
	_ever_active_peers = {}


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
