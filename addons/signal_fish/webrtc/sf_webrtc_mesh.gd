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
##   is an authoritative clear. `RoomJoined` pre-gather seeds the list before
##   the first plan lands, so attach before joining (or re-attach only when
##   the next plan carries its own ICE list). TURN credentials stay out of
##   logs (PLAN §12).
## - [method SignalFishClient.send_transport_status] is reported only at the
##   aggregate 0↔1 connected-peer boundaries.
## - A signaling relay refused by the client (backpressure `ERR_BUSY`) or
##   dropped by the server (`SIGNAL_RATE_LIMITED` via [signal server_error])
##   is re-queued per peer and redelivered in order; retries wait out one
##   interval each (issue #127, the issue-#102 pattern), and a recovered
##   link flushes the backlog. Redelivered ICE candidates are idempotent;
##   redelivered SDP relies on the remote tolerating reapplication (the
##   next plan/generation reconciles roles). A queue that keeps being
##   refused locally is dropped loudly after a retry budget — a
##   new-generation plan or membership change rebuilds the peer.
## - The mesh is torn down on [signal room_joined] (fresh baseline),
##   [signal room_left], [signal disconnected],
##   [signal connection_failed], [signal authentication_error], [signal reconnected], and
##   [code]_exit_tree[/code]; a replayed plan inside [code]missed_events
##   [/code] can never revive it. [signal player_left] drops only the leaving
##   peer — the rest of the mesh survives. Fresh [signal player_joined] or
##   [signal player_reconnected] epochs retire that peer until a new plan
##   generation arrives. Duplicate known epochs keep the existing link; an
##   announcement without an epoch retires it conservatively.
##
## Peer ids: [method uuid_to_peer_id] maps each player UUID to a deterministic
## positive integer (FNV-1a), so every mesh member derives the same
## [MultiplayerAPI] ids without extra negotiation.
##
## Platform notes: native exports need a WebRTC GDExtension; browser exports
## use browser WebRTC. [WebRTCMultiplayerPeer] creates three negotiated data
## channels: reliable, ordered, and unreliable. A peer counts as connected
## only while every required channel is open.

const SFWebRTCMultiplayerPeerScript = preload(
	"res://addons/signal_fish/webrtc/sf_webrtc_multiplayer_peer.gd"
)
const Recovery = preload("res://addons/signal_fish/webrtc/sf_webrtc_recovery.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

# Signed FNV offset: GDScript clamps unsigned 64-bit literals.
const _FNV1A_OFFSET_BASIS := -3750763034362895579
const _FNV1A_PRIME := 1099511628211
const _RECEIVE_MODES := [
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
]

## Signals queued per peer while the link is backpressured (issue #335).
const MAX_PENDING_RELAYS := 64

## Injectable factory returning an object duck-typed to
## [WebRTCPeerConnection]. Empty Callable = the engine class.
var peer_connection_factory: Callable = Callable()

## Injectable factory returning an object duck-typed to
## [WebRTCMultiplayerPeer]. Empty Callable = the engine class.
var multiplayer_peer_factory: Callable = Callable()

## A boundary report refused (e.g. backpressure) stays armed (issue #102) and
## retries at most once per interval — the heartbeat's backpressured-beat
## rule (PLAN §4.7) — so a sustained congestion episode surfaces one
## protocol_error per interval instead of one per poll. Injectable for
## deterministic tests.
var transport_status_retry_msec := 1000

## A signaling relay refused locally (backpressure) or dropped remotely
## (server `SIGNAL_RATE_LIMITED`) is re-queued and redelivered at most once
## per interval (issue #127). Injectable for deterministic tests.
var signal_retry_msec := 1000

## Consecutive refused attempts (the initial send plus drain retries) one
## relay payload may consume before the mesh logs a diagnostic and drops
## its pending queue (issue #127).
var signal_retry_budget := 10

## Enable before the first WebRTC plan. Both endpoints must opt in.
var pair_recovery_enabled := false
var pair_recovery_retry_msec := 500
var pair_recovery_timeout_msec := 5000
var pair_recovery_clock: Callable = Time.get_ticks_msec

var _client: SignalFishClientScript = null
# Distinguishes "never attached / detached" from "the attached client node was
# freed": Godot reads a freed object held by a script-typed variable as null,
# so the vanished-client case must be detected by the flag, not the reference.
var _attached := false
var _plan: SFSessionTypesScript.SessionPlanInfo = null
var _ice_servers: Array[SFSessionTypesScript.IceServerInfo] = []
var _peers: Dictionary = {}
var _retired_generations: Dictionary = {}
var _known_peers: Dictionary = {}
var _recovery_pairs: Dictionary = {}
var _recovery_generation := ""
var _mp_peer: Object = null
var _safe_mp_peer: SFWebRTCMultiplayerPeerScript = null
var _reported_connected := false
var _status_retry_due_msec := 0
var _mesh_revision := 0
var _receive_peer_cursor := 0
var _receive_peer_ids: Array = []


## Starts consuming a client's session-plan events. The client must stay
## driven (its own polling pumps inbound events); this node's [code]
## _process[/code] pumps the peer connections. Attach before joining, or make
## sure the next plan carries its own ICE list.
func attach(client: SignalFishClientScript) -> Error:
	if client == null:
		return ERR_INVALID_PARAMETER
	_client_is_live()
	if _client != null:
		return ERR_BUSY
	_client = client
	_attached = true
	client.room_joined.connect(_on_client_room_joined)
	client.spectator_joined.connect(_on_client_spectator_joined)
	client.session_plan.connect(_on_client_session_plan)
	client.signal_received.connect(_on_client_signal_received)
	client.new_peer.connect(_on_client_new_peer)
	client.player_left.connect(_on_client_player_left)
	client.player_joined.connect(_on_client_player_joined)
	client.player_reconnected.connect(_on_client_player_reconnected)
	client.room_left.connect(_on_client_room_left)
	client.disconnected.connect(_on_client_disconnected)
	client.connection_failed.connect(_on_client_connection_failed)
	client.authentication_error.connect(_on_client_authentication_error)
	client.reconnected.connect(_on_client_reconnected)
	client.server_error.connect(_on_client_server_error)
	return OK


## Stops consuming events and tears the mesh down.
func detach() -> void:
	if not _client_is_live():
		return
	_client.room_joined.disconnect(_on_client_room_joined)
	_client.spectator_joined.disconnect(_on_client_spectator_joined)
	_client.session_plan.disconnect(_on_client_session_plan)
	_client.signal_received.disconnect(_on_client_signal_received)
	_client.new_peer.disconnect(_on_client_new_peer)
	_client.player_left.disconnect(_on_client_player_left)
	_client.player_joined.disconnect(_on_client_player_joined)
	_client.player_reconnected.disconnect(_on_client_player_reconnected)
	_client.room_left.disconnect(_on_client_room_left)
	_client.disconnected.disconnect(_on_client_disconnected)
	_client.connection_failed.disconnect(_on_client_connection_failed)
	_client.authentication_error.disconnect(_on_client_authentication_error)
	_client.reconnected.disconnect(_on_client_reconnected)
	_client.server_error.disconnect(_on_client_server_error)
	_client = null
	_attached = false
	_reset_mesh()


## Pumps every peer connection and reports connected-count boundaries. Called
## from [code]_process[/code]; call manually when driving without the tree.
func poll() -> void:
	if not _client_is_live():
		return
	var recovering := (
		_plan != null
		and _plan.generation == _recovery_generation
		and not _recovery_pairs.is_empty()
	)
	var now: int = pair_recovery_clock.call() if recovering else 0
	if recovering:
		_tick_recovery(now)
	# Iterate a keys copy: a real connection's poll() can pump callbacks that
	# end in consumer handlers, which may legally mutate the mesh re-entrantly
	# (a peer dropped mid-poll is simply skipped).
	for uuid: String in _peers.keys():
		var entry: _MeshPeer = _peers.get(uuid)
		if entry == null:
			continue
		var error: Error = entry.connection.call("poll")
		if not _check_peer_result(entry, "poll", error):
			continue
		if _peer_is_terminal(entry):
			_lose_peer(entry, now)
			continue
		var pair := _recovery_pair(uuid)
		if _peer_is_ready_for_recovery(entry, pair):
			pair.was_ready = true
			pair.request_count = 0
			pair.expires = -1
		_drain_relay(entry)
	_update_transport_status()


## The mesh multiplayer peer, ready for [code]MultiplayerAPI.multiplayer_peer
## [/code]; null until the mesh holds at least one plan peer (and after
## teardown).
func get_multiplayer_peer() -> Object:
	return _mp_peer


## Returns an opt-in RPC peer with stable received packet metadata (#403).
## Use as the sole receiver; do not mix with raw or engine packet reads.
## Only the three default channels are supported. Empty datagrams and channel
## read errors surface as ERR_UNAVAILABLE through Godot's script packet hook.
func get_safe_multiplayer_peer() -> MultiplayerPeer:
	if _mp_peer == null:
		return null
	if _safe_mp_peer == null:
		_safe_mp_peer = SFWebRTCMultiplayerPeerScript.new(self, _mp_peer)
	return _safe_mp_peer


## Reads one raw gameplay packet with metadata from its physical channel.
## Returns null when no packet is ready. Poll the mesh first. Use this as the
## sole receive path; do not combine it with MultiplayerAPI/RPC or the engine
## multiplayer peer's packet reads. Sending still uses the multiplayer peer.
## Only the mesh's three default channels are supported.
func receive_packet() -> ReceivedPacket:
	if not _client_is_live() or _mp_peer == null or _peers.is_empty():
		return null
	if _receive_peer_ids.is_empty():
		_receive_peer_ids = _peers.keys()
	var ids := _receive_peer_ids
	for offset: int in ids.size():
		var index := (_receive_peer_cursor + offset) % ids.size()
		var entry: _MeshPeer = _peers[ids[index]]
		if entry.connection.call("get_connection_state") != WebRTCPeerConnection.STATE_CONNECTED:
			continue
		if not _mp_peer.call("has_peer", entry.peer_id):
			continue
		var peer: Dictionary = _mp_peer.call("get_peer", entry.peer_id)
		var channels: Array = peer["channels"]
		if channels.size() != 3:
			continue
		var channel_index := entry.receive_channel_cursor
		var selected_channel: Object = channels[channel_index]
		if selected_channel.call("get_available_packet_count") == 0:
			channel_index = -1
			for channel_offset: int in range(1, 3):
				var index_in_peer := (entry.receive_channel_cursor + channel_offset) % 3
				var channel: Object = channels[index_in_peer]
				if channel.call("get_available_packet_count") > 0:
					channel_index = index_in_peer
					selected_channel = channel
					break
			if channel_index < 0:
				continue
		var channels_open := true
		for channel: Object in channels:
			if channel.call("get_ready_state") != WebRTCDataChannel.STATE_OPEN:
				channels_open = false
		if not channels_open:
			continue
		var packet := ReceivedPacket.new()
		packet.peer_id = entry.peer_id
		packet.transfer_mode = _RECEIVE_MODES[channel_index]
		# Issue #403: get_packet() rescans channels after caching metadata.
		packet.data = selected_channel.call("get_packet")
		packet.error = selected_channel.call("get_packet_error")
		entry.receive_channel_cursor = (channel_index + 1) % 3
		_receive_peer_cursor = (index + 1) % ids.size()
		return packet
	return null


func get_peer_count() -> int:
	return _peers.size()


func get_peer_ids() -> Array[String]:
	var ids: Array[String] = []
	for uuid: String in _peers.keys():
		ids.append(uuid)
	return ids


## Deterministic, platform-stable player UUID → [MultiplayerAPI] peer id
## (FNV-1a over the UUID string). The result is forced into the valid
## non-server id range [2, 2^31): 0 is invalid and 1 is the reserved server
## id, and both would make [code]create_mesh[/code] fail. The range
## squeeze is shared by every mesh member, so ids stay collision-consistent.
static func uuid_to_peer_id(uuid: String) -> int:
	var digest := _FNV1A_OFFSET_BASIS
	for index: int in uuid.length():
		digest = ((digest ^ uuid.unicode_at(index)) * _FNV1A_PRIME) & 0x7FFFFFFFFFFFFFFF
	var id := digest & 0x7FFFFFFF
	return id + 2 if id < 2 else id


func _process(_delta: float) -> void:
	poll()


func _exit_tree() -> void:
	detach()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# A mesh discarded without a teardown path (freed while outside the
		# tree, so _exit_tree never runs) must still break the peer clusters:
		# the entry-lambda cycle (issue #86) would otherwise outlive the node
		# and leak every live peer connection.
		_reset_mesh()


func _client_is_live() -> bool:
	if _client == null:
		if _attached:
			_attached = false
			_reset_mesh()
		return false
	if not is_instance_valid(_client):
		_attached = false
		_client = null
		_reset_mesh()
		return false
	return true


func _on_client_room_joined(info: SFTypesScript.RoomJoinedInfo) -> void:
	_reset_mesh()
	_ice_servers = info.ice_servers.duplicate()


func _on_client_spectator_joined(_info: SFTypesScript.SpectatorJoinedInfo) -> void:
	_reset_mesh()


func _on_client_session_plan(plan: SFSessionTypesScript.SessionPlanInfo) -> void:
	# A plan is room-scoped (issue #120): a plan landing before any room
	# baseline is off-contract server input, and applying it would open peer
	# connections keyed on an empty local player id. The baseline re-arms
	# the mesh, so dropping the stray plan loses nothing.
	if _client == null or _client.get_room_id().is_empty():
		return
	if _client.get_session_state() == SignalFishClientScript.SessionState.SPECTATING:
		return
	_apply_plan(plan)


func _on_client_signal_received(from_player: String, generation: String, payload: Variant) -> void:
	if _plan == null or _plan.transport != SFSessionTypesScript.TransportKind.WEBRTC:
		return
	if generation != _plan.generation:
		return
	if not payload is Dictionary:
		return
	var message: Dictionary = payload
	var pair := _recovery_pair(from_player)
	if message.has(Recovery.TAG):
		if message.size() == 1 and message[Recovery.TAG] is Dictionary:
			var recovery_message: Dictionary = message[Recovery.TAG]
			_receive_recovery(pair, recovery_message)
		return
	var entry: _MeshPeer = _peers.get(from_player)
	if entry == null or (pair != null and (pair.attempt > 0 or pair.retired)):
		return
	_apply_peer_signal(entry, message)


func _apply_peer_signal(entry: _MeshPeer, message: Dictionary) -> void:
	if message.has("Offer") or message.has("Answer"):
		var type := "offer" if message.has("Offer") else "answer"
		var sdp: String = str(message["Offer"] if type == "offer" else message["Answer"])
		var error: Error = entry.connection.call("set_remote_description", type, sdp)
		_check_peer_result(entry, "set_remote_description", error)
	elif message.has("IceCandidate"):
		_apply_ice_candidate(entry, message["IceCandidate"])


func _apply_ice_candidate(entry: _MeshPeer, payload: Variant) -> void:
	if not payload is String:
		SFLogScript.warn("mesh: invalid ICE candidate")
		return
	var candidate: String = payload
	var media := ""
	var index := 0
	# Native reference engine.rs @ b264ec7 emits RTCIceCandidateInit JSON.
	# Existing raw-line peers keep their candidate text verbatim.
	if candidate.strip_edges().begins_with("{"):
		var parser := JSON.new()
		if parser.parse(candidate) != OK:
			SFLogScript.warn("mesh: invalid ICE candidate envelope")
			return
		var decoded: Variant = parser.data
		if not decoded is Dictionary:
			SFLogScript.warn("mesh: invalid ICE candidate envelope")
			return
		var envelope: Dictionary = decoded
		if not envelope.get("candidate") is String:
			SFLogScript.warn("mesh: invalid ICE candidate envelope")
			return
		var mid: Variant = envelope.get("sdpMid")
		var line: Variant = envelope.get("sdpMLineIndex")
		if mid != null and not mid is String:
			SFLogScript.warn("mesh: invalid ICE candidate media")
			return
		if line != null:
			if not SFTypeUtils.is_integral_number(line) or line < 0 or line > 65535:
				SFLogScript.warn("mesh: invalid ICE candidate index")
				return
			var number: float = line
			index = int(number)
		media = mid if mid != null else ""
		candidate = envelope["candidate"]
	var error: Error = entry.connection.call("add_ice_candidate", media, index, candidate)
	if error != OK:
		SFLogScript.warn("mesh: add_ice_candidate refused (%d)" % error)


func _on_client_new_peer(peer_id: String, you_initiate: bool) -> void:
	# Additive compatibility directive (upstream NewPeer): plan refreshes are
	# the primary membership mechanism; this obeys you_initiate verbatim.
	if _plan == null or _plan.transport != SFSessionTypesScript.TransportKind.WEBRTC:
		return
	if _peers.has(peer_id) or _recovery_pair(peer_id) != null:
		return
	if _peers.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
		# Hostile NewPeer streams must not open unbounded peer connections
		# (issue #274); only the next plan reconciliation can reshuffle.
		SFLogScript.error(
			"mesh: peer count is at cap %d; NewPeer not tracked" % SFTypeUtils.MAX_TRACKED_PEERS
		)
		return
	_open_peer(peer_id, you_initiate)


func _on_client_player_joined(player: SFTypesScript.PlayerInfo) -> void:
	_retire_prior_incarnation(player.id)


func _on_client_player_reconnected(player_id: String) -> void:
	_retire_prior_incarnation(player_id)


func _retire_prior_incarnation(player_id: String) -> void:
	if _plan == null:
		return
	var pair := _recovery_pair(player_id)
	if pair != null and _client._get_player_epoch(player_id) != pair.remote_epoch:
		pair.retired = true
	var entry: _MeshPeer = _peers.get(player_id)
	if entry == null:
		if _known_peers.has(player_id):
			_retired_generations[player_id] = _plan.generation
			return
		for peer: SFSessionTypesScript.SessionPeerInfo in _plan.peers:
			if peer.player_id != player_id:
				continue
			if _peers.size() + _retired_generations.size() < SFTypeUtils.MAX_TRACKED_PEERS:
				_retired_generations[player_id] = _plan.generation
			return
		return
	var epoch := _client._get_player_epoch(player_id)
	if epoch != -1 and entry.epoch != -1 and epoch <= entry.epoch:
		return
	# Server #937: membership can precede its replacement plan. Retire the
	# old physical link now and fence additive NewPeer until a fresh plan.
	_retired_generations[player_id] = entry.generation
	_drop_peer(player_id)


func _on_client_player_left(player_id: String) -> void:
	var pair := _recovery_pair(player_id)
	if pair != null:
		pair.retired = true
	_drop_peer(player_id)


func _on_client_room_left() -> void:
	_reset_mesh()


func _on_client_disconnected(_code: int, _reason: String) -> void:
	_reset_mesh()


func _on_client_connection_failed(_error: String) -> void:
	# A transport failure kills the session without a close frame (no
	# `disconnected` fires): the mesh must not outlive it.
	_reset_mesh()


func _on_client_authentication_error(_message: String, _error_code: int) -> void:
	_reset_mesh()


func _on_client_reconnected(
	_info: SFTypesScript.RoomJoinedInfo, _missed_events: Array[SFTypesScript.DecodedEvent]
) -> void:
	# Replay delivers the missed events through this signal only, so the old
	# mesh cannot be revived by a replayed plan. No peer reopens until the
	# next plan arrives, and that plan's ICE list governs new connections.
	_reset_mesh()


func _apply_plan(plan: SFSessionTypesScript.SessionPlanInfo) -> void:
	if _plan == null or _plan.generation != plan.generation or _plan.transport != plan.transport:
		_mesh_revision += 1
		_status_retry_due_msec = 0
	if _plan == null or _plan.generation != plan.generation:
		_known_peers.clear()
	_plan = plan
	if (
		not _recovery_generation.is_empty()
		and (
			plan.generation != _recovery_generation
			or plan.transport != SFSessionTypesScript.TransportKind.WEBRTC
		)
	):
		for pair: Recovery in _recovery_pairs.values():
			pair.retired = true
	for uuid: String in _retired_generations.keys():
		if _retired_generations[uuid] != plan.generation:
			_retired_generations.erase(uuid)
	_ice_servers = plan.ice_servers.duplicate()
	if plan.transport != SFSessionTypesScript.TransportKind.WEBRTC:
		# Only a webrtc plan carries peer connections for this mesh. A relay
		# floor or a host+direct plan empties it — opening connections whose
		# signals would be gated away could never complete a handshake.
		for uuid: String in _peers.keys():
			_drop_peer(uuid)
		return
	var wanted: Dictionary = {}
	var peer_count: int = plan.peers.size()
	if peer_count > SFTypeUtils.MAX_TRACKED_PEERS:
		SFLogScript.error(
			(
				"mesh: plan exceeds %d peers; dropped %d"
				% [SFTypeUtils.MAX_TRACKED_PEERS, peer_count - SFTypeUtils.MAX_TRACKED_PEERS]
			)
		)
		peer_count = SFTypeUtils.MAX_TRACKED_PEERS
	for index: int in peer_count:
		var peer: SFSessionTypesScript.SessionPeerInfo = plan.peers[index]
		wanted[peer.player_id] = peer
	_update_recovery_plan(plan, wanted)
	for uuid: String in wanted:
		var entry: _MeshPeer = _peers.get(uuid)
		if entry == null:
			continue
		var wanted_peer: SFSessionTypesScript.SessionPeerInfo = wanted[uuid]
		if entry.initiate != wanted_peer.initiate or entry.generation != plan.generation:
			_drop_peer(uuid)
	# Drops precede opens: a full-roster plan flip must never hold both
	# generations past the tracked-peer ceiling (issue #335).
	for uuid: String in _peers.keys():
		if not wanted.has(uuid):
			_drop_peer(uuid)
	for uuid: String in wanted:
		var pair := _recovery_pair(uuid)
		if not _peers.has(uuid) and (pair == null or (not pair.retired and not pair.was_ready)):
			var wanted_peer: SFSessionTypesScript.SessionPeerInfo = wanted[uuid]
			_open_peer(uuid, wanted_peer.initiate)


func _update_recovery_plan(plan: SFSessionTypesScript.SessionPlanInfo, wanted: Dictionary) -> void:
	if not pair_recovery_enabled or plan.generation.is_empty():
		return
	if plan.generation == _recovery_generation:
		for uuid: String in _recovery_pairs:
			var pair: Recovery = _recovery_pairs[uuid]
			var directive: SFSessionTypesScript.SessionPeerInfo = wanted.get(uuid)
			if directive == null or directive.initiate != pair.initiate:
				pair.retired = true
		return
	if not _recovery_generation.is_empty():
		return
	_recovery_generation = plan.generation
	var local_epoch := _client._get_player_epoch(_client.get_player_id())
	if local_epoch < 0:
		return
	for uuid: String in wanted:
		var remote_epoch := _client._get_player_epoch(uuid)
		if uuid == _client.get_player_id() or remote_epoch < 0:
			continue
		var directive: SFSessionTypesScript.SessionPeerInfo = wanted[uuid]
		var pair := Recovery.new()
		pair.peer = uuid
		pair.local_player = _client.get_player_id()
		pair.room = _client.get_room_id()
		pair.generation = plan.generation
		pair.local_epoch = local_epoch
		pair.remote_epoch = remote_epoch
		pair.initiate = directive.initiate
		_recovery_pairs[uuid] = pair


func _recovery_pair(uuid: String) -> Recovery:
	if _plan == null or _plan.generation != _recovery_generation:
		return null
	return _recovery_pairs.get(uuid)


func _recovery_is_current(pair: Recovery) -> bool:
	return (
		pair != null
		and not pair.retired
		and _recovery_pairs.get(pair.peer) == pair
		and _plan != null
		and _plan.generation == pair.generation
		and _client_connected()
		and _client.get_room_id() == pair.room
		and _client.get_player_id() == pair.local_player
		and _client._get_player_epoch(pair.local_player) == pair.local_epoch
		and _client._get_player_epoch(pair.peer) == pair.remote_epoch
	)


func _peer_is_ready_for_recovery(entry: _MeshPeer, pair: Recovery) -> bool:
	return (
		_recovery_is_current(pair)
		and (not pair.was_ready or pair.expires >= 0)
		and entry.attempt == pair.attempt
		and _peer_is_ready(entry)
		and _peers.get(entry.uuid) == entry
		and _recovery_is_current(pair)
	)


func _lose_peer(entry: _MeshPeer, now: int) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	var pair := _recovery_pair(entry.uuid)
	if _recovery_is_current(pair) and pair.was_ready and entry.attempt == pair.attempt:
		_schedule_recovery(pair, now)
	_drop_peer(entry.uuid)


func _schedule_recovery(pair: Recovery, now: int) -> void:
	pair.expires = -1
	if pair.due == -1:
		pair.due = now + clampi(pair_recovery_retry_msec, 0, 60000)


func _tick_recovery(now: int) -> void:
	for uuid: String in _recovery_pairs.keys():
		var pair := _recovery_pair(uuid)
		if not _recovery_is_current(pair):
			continue
		if pair.expires >= 0 and now >= pair.expires:
			_schedule_recovery(pair, now)
			_drop_peer(uuid)
		if not _recovery_is_current(pair) or pair.due < 0 or now < pair.due:
			continue
		pair.due = -1
		if pair.initiate:
			if pair.attempt < Recovery.MAX_ATTEMPTS:
				_begin_recovery(pair, pair.attempt + 1, now)
		elif pair.request_count < Recovery.MAX_ATTEMPTS and pair.attempt < Recovery.MAX_ATTEMPTS:
			pair.request_count += 1
			pair.due = now + clampi(pair_recovery_retry_msec, 1, 60000)
			_client.send_signal(pair.peer, pair.generation, pair.envelope("request"))


func _begin_recovery(pair: Recovery, attempt: int, now: int) -> void:
	if not _recovery_is_current(pair) or attempt <= pair.attempt:
		return
	pair.attempt = attempt
	pair.was_ready = true
	pair.due = -1
	pair.expires = now + clampi(pair_recovery_timeout_msec, 1, 60000)
	_drop_peer(pair.peer)
	if _recovery_is_current(pair) and pair.attempt == attempt:
		_open_peer(pair.peer, pair.initiate, attempt)


func _receive_recovery(pair: Recovery, message: Dictionary) -> void:
	if not _recovery_is_current(pair) or not pair.accepts(message):
		return
	var wire_attempt: float = message["attempt"]
	var attempt := int(wire_attempt)
	var kind: String = message["kind"]
	var body: String = message["body"]
	if kind == "request":
		if pair.initiate and pair.was_ready and attempt == pair.attempt and body.is_empty():
			if pair.attempt < Recovery.MAX_ATTEMPTS and pair.due == -1:
				var requested_at: int = pair_recovery_clock.call()
				if _recovery_is_current(pair) and pair.attempt == attempt:
					_schedule_recovery(pair, requested_at)
		return
	if attempt == 0 or body.is_empty():
		return
	var now: int = pair_recovery_clock.call()
	if (
		kind == "Offer"
		and not pair.initiate
		and attempt > pair.attempt
		and Recovery.has_data_offer_shape(body)
	):
		_begin_recovery(pair, attempt, now)
	if not _recovery_is_current(pair) or pair.attempt != attempt or pair.due >= 0:
		return
	if pair.expires >= 0 and now >= pair.expires:
		return
	var entry: _MeshPeer = _peers.get(pair.peer)
	if entry == null or entry.attempt != attempt:
		return
	var expected_description := "Answer" if pair.initiate else "Offer"
	if kind == expected_description:
		if entry.remote_description_seen:
			return
		entry.remote_description_seen = true
	elif kind != "IceCandidate" or not entry.remote_description_seen:
		return
	_apply_peer_signal(entry, {kind: body})


func _open_peer(uuid: String, initiate: bool, attempt := 0) -> void:
	if (
		_client == null
		or uuid.is_empty()
		or uuid == _client.get_player_id()
		or _retired_generations.has(uuid)
	):
		return
	if not _known_peers.has(uuid) and _known_peers.size() >= SFTypeUtils.MAX_TRACKED_PEERS:
		return
	var opening_client := _client
	var opening_revision := _mesh_revision
	var pair := _recovery_pair(uuid)
	var connection: Object = _make_peer_connection()
	if connection == null:
		return
	if not _can_open_peer(opening_client, opening_revision, uuid, pair, attempt):
		connection.call("close")
		return
	var error: Error = connection.call("initialize", _rtc_configuration())
	if error != OK or not _can_open_peer(opening_client, opening_revision, uuid, pair, attempt):
		if error != OK:
			SFLogScript.error("mesh: peer connection refused (%d)" % error)
		connection.call("close")
		return
	var multiplayer_peer: Object = _multiplayer_peer()
	if (
		multiplayer_peer == null
		or not _can_open_peer(opening_client, opening_revision, uuid, pair, attempt)
	):
		connection.call("close")
		return
	var entry := _MeshPeer.new()
	entry.uuid = uuid
	entry.peer_id = uuid_to_peer_id(uuid)
	entry.connection = connection
	entry.initiate = initiate
	entry.generation = _plan.generation if _plan != null else ""
	entry.epoch = _client._get_player_epoch(uuid)
	entry.attempt = attempt
	error = multiplayer_peer.call("add_peer", connection, entry.peer_id)
	if error != OK:
		SFLogScript.error("mesh: add_peer refused (%d)" % error)
		connection.call("close")
		return
	if not _can_open_peer(opening_client, opening_revision, uuid, pair, attempt):
		if multiplayer_peer.call("has_peer", entry.peer_id):
			var added: Dictionary = multiplayer_peer.call("get_peer", entry.peer_id)
			if added.get("connection") == connection:
				multiplayer_peer.call("remove_peer", entry.peer_id)
		connection.call("close")
		return
	# The callables are kept on the entry so `_drop_peer` can disconnect
	# them: each lambda captures `entry`, and `entry.connection` holds the
	# connection, so an undisconnected signal is a RefCounted cycle that
	# leaks every rebuilt peer (issue #86).
	entry.session_cb = func(type: String, sdp: String) -> void:
		_on_peer_session_description(entry, type, sdp)
	var session_created: Signal = connection.get("session_description_created")
	session_created.connect(entry.session_cb)
	entry.ice_cb = func(media: String, index: int, candidate: String) -> void:
		_on_peer_ice_candidate(entry, media, index, candidate)
	var ice_created: Signal = connection.get("ice_candidate_created")
	ice_created.connect(entry.ice_cb)
	_receive_peer_ids.clear()
	_peers[uuid] = entry
	_known_peers[uuid] = true
	if initiate:
		error = connection.call("create_offer")
		_check_peer_result(entry, "create_offer", error)


func _can_open_peer(
	client: SignalFishClientScript, revision: int, uuid: String, pair: Recovery, attempt: int
) -> bool:
	if _client != client or _mesh_revision != revision or _peers.has(uuid):
		return false
	if attempt == 0:
		return pair == null or (not pair.retired and pair.attempt == 0)
	return _recovery_is_current(pair) and pair.attempt == attempt


func _check_peer_result(entry: _MeshPeer, operation: String, error: Error) -> bool:
	if _peers.get(entry.uuid) != entry:
		return false
	if error == OK:
		return true
	var now: int = pair_recovery_clock.call() if _recovery_pair(entry.uuid) != null else 0
	_lose_peer(entry, now)
	SFLogScript.error("mesh: %s refused (%d)" % [operation, error])
	return false


func _drop_peer(uuid: String) -> void:
	var entry: _MeshPeer = _peers.get(uuid)
	if entry == null:
		return
	_receive_peer_ids.clear()
	_peers.erase(uuid)
	if _mp_peer != null and _mp_peer.call("has_peer", entry.peer_id):
		_mp_peer.call("remove_peer", entry.peer_id)
	if entry.session_cb.is_valid():
		var session_created: Signal = entry.connection.get("session_description_created")
		session_created.disconnect(entry.session_cb)
	if entry.ice_cb.is_valid():
		var ice_created: Signal = entry.connection.get("ice_candidate_created")
		ice_created.disconnect(entry.ice_cb)
	entry.session_cb = Callable()
	entry.ice_cb = Callable()
	entry.connection.call("close")


func _reset_mesh() -> void:
	if _safe_mp_peer != null:
		_safe_mp_peer._invalidate()
	_mesh_revision += 1
	_receive_peer_cursor = 0
	_plan = null
	_retired_generations.clear()
	_known_peers.clear()
	_recovery_pairs.clear()
	_recovery_generation = ""
	_ice_servers = []
	for uuid: String in _peers.keys():
		_drop_peer(uuid)
	if _mp_peer != null:
		_mp_peer.call("close")
	_mp_peer = null
	_safe_mp_peer = null
	# Teardown resolves the reported state silently: boundary reports are for
	# observed connected-count changes on a living session, never for a room
	# or connection that is already gone.
	_reported_connected = false
	_status_retry_due_msec = 0


func _update_transport_status() -> void:
	# While the client is dialing/closing the send would be refused with a
	# spurious protocol_error and the report lost (issue #73); teardown
	# resolves the boundary silently instead.
	if not _client_connected():
		return
	var connected := _count_connected_peers()
	var wanted := connected > 0
	if wanted == _reported_connected:
		# The edge resolved itself (e.g. a flap back to the reported state):
		# drop any leftover retry deadline so the next genuine edge reports
		# immediately.
		_status_retry_due_msec = 0
		return
	# The boundary flips only on send success (issue #102): a fresh edge
	# reports immediately; a refused report stays armed and throttles its
	# retries to one per interval.
	var now := Time.get_ticks_msec()
	if _status_retry_due_msec > now:
		return
	var client := _client
	var revision := _mesh_revision
	var sent: Error = client.send_transport_status(
		SFSessionTypesScript.TransportKind.WEBRTC, wanted
	)
	if _client != client or _mesh_revision != revision:
		# A callback replaced the room or plan while the send was in flight.
		return
	if sent == OK:
		_reported_connected = wanted
	else:
		_status_retry_due_msec = now + transport_status_retry_msec


func _peer_is_terminal(entry: _MeshPeer) -> bool:
	var state: int = entry.connection.call("get_connection_state")
	if (
		state == WebRTCPeerConnection.STATE_DISCONNECTED
		or state == WebRTCPeerConnection.STATE_FAILED
		or state == WebRTCPeerConnection.STATE_CLOSED
	):
		return true
	if _mp_peer == null or not _mp_peer.call("has_peer", entry.peer_id):
		return true
	var peer: Dictionary = _mp_peer.call("get_peer", entry.peer_id)
	var channels: Array = peer["channels"]
	for channel: Object in channels:
		var channel_state: int = channel.call("get_ready_state")
		if (
			channel_state == WebRTCDataChannel.STATE_CLOSING
			or channel_state == WebRTCDataChannel.STATE_CLOSED
		):
			return true
	return false


func _peer_is_ready(entry: _MeshPeer) -> bool:
	if entry.connection.call("get_connection_state") != WebRTCPeerConnection.STATE_CONNECTED:
		return false
	if _mp_peer == null or not _mp_peer.call("has_peer", entry.peer_id):
		return false
	# The connection can stay connected after a channel closes (#365).
	var peer: Dictionary = _mp_peer.call("get_peer", entry.peer_id)
	var channels: Array = peer["channels"]
	for channel: Object in channels:
		if channel.call("get_ready_state") != WebRTCDataChannel.STATE_OPEN:
			return false
	return not channels.is_empty()


func _count_connected_peers() -> int:
	var connected := 0
	for uuid: String in _peers:
		var entry: _MeshPeer = _peers[uuid]
		if _peer_is_ready(entry):
			connected += 1
	return connected


func _on_peer_session_description(entry: _MeshPeer, type: String, sdp: String) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	if entry.attempt > 0:
		var expected := "offer" if entry.initiate else "answer"
		if (
			type != expected
			or entry.local_description_claimed
			or not _recovery_accepts_callbacks(entry)
		):
			return
		entry.local_description_claimed = true
	var payload: Dictionary = {}
	if type == "offer":
		payload["Offer"] = sdp
	elif type == "answer":
		payload["Answer"] = sdp
	else:
		return
	var error: Error = entry.connection.call("set_local_description", type, sdp)
	if not _check_peer_result(entry, "set_local_description", error):
		return
	_send_signal_to(entry, payload)
	if entry.attempt > 0 and _peers.get(entry.uuid) == entry:
		entry.local_description_sent = true
		for candidate: String in entry.early_ice:
			_send_signal_to(entry, {"IceCandidate": candidate})
		entry.early_ice.clear()


func _on_peer_ice_candidate(
	entry: _MeshPeer, _media: String, _index: int, candidate: String
) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	if candidate.is_empty():
		return
	if entry.attempt > 0 and not entry.local_description_sent:
		if (
			_recovery_accepts_callbacks(entry)
			and entry.early_ice.size() < Recovery.MAX_EARLY_CANDIDATES
		):
			entry.early_ice.append(candidate)
		return
	_send_signal_to(entry, {"IceCandidate": candidate})


func _recovery_accepts_callbacks(entry: _MeshPeer) -> bool:
	var pair := _recovery_pair(entry.uuid)
	var now: int = pair_recovery_clock.call()
	return (
		_peers.get(entry.uuid) == entry
		and _recovery_is_current(pair)
		and pair.attempt == entry.attempt
		and pair.due < 0
		and (pair.expires < 0 or now < pair.expires)
	)


func _send_signal_to(entry: _MeshPeer, payload: Dictionary) -> void:
	if not _client_connected() or _peers.get(entry.uuid) != entry:
		return
	if entry.attempt > 0:
		if not _recovery_accepts_callbacks(entry):
			return
		var pair: Recovery = _recovery_pairs[entry.uuid]
		var kind: String = payload.keys()[0]
		var body: String = payload[kind]
		payload = pair.envelope(kind, body)
	entry.relay_dropped = false
	# The freshest payload per peer doubles as the rate-limit healing
	# candidate: a server-refused relay re-queues exactly this payload.
	entry.last_relayed = payload
	entry.has_last_relayed = true
	# The flag is re-derived by the queue operations below; a payload that
	# never lands in the queue (cap drop, successful send) stays un-pending.
	entry.last_relayed_pending = false
	if not entry.pending_signals.is_empty():
		# Order matters (an Offer must precede its candidates at the remote),
		# and hammering a backpressured link would spam protocol_error: queue
		# behind the pending head and let the throttled drain deliver it.
		_enqueue_relay(entry, payload)
		return
	_dispatch_relay(entry, payload)


func _dispatch_relay(entry: _MeshPeer, payload: Dictionary) -> void:
	var sent: Error = _client.send_signal(entry.uuid, entry.generation, payload)
	if sent == OK or _peers.get(entry.uuid) != entry:
		return
	entry.relay_attempts += 1
	_enqueue_relay(entry, payload)


func _enqueue_relay(entry: _MeshPeer, payload: Dictionary) -> void:
	if entry.pending_signals.size() >= MAX_PENDING_RELAYS:
		# Order (Offer before candidates) survives by refusing the newest
		# signal instead of evicting the queue head (issue #335).
		SFLogScript.error(
			(
				"mesh: relay queue to %s is at cap %d; signal dropped"
				% [entry.uuid, MAX_PENDING_RELAYS]
			)
		)
		return
	entry.pending_signals.append(payload)
	entry.last_relayed_pending = is_same(payload, entry.last_relayed)
	if entry.pending_signals.size() == 1:
		entry.relay_due_msec = Time.get_ticks_msec() + signal_retry_msec


func _drain_relay(entry: _MeshPeer) -> void:
	if _peers.get(entry.uuid) != entry:
		return
	if entry.pending_signals.is_empty() or not _client_connected():
		return
	if entry.relay_due_msec > Time.get_ticks_msec():
		return
	while not entry.pending_signals.is_empty():
		var payload: Dictionary = entry.pending_signals[0]
		var sent: Error = _client.send_signal(entry.uuid, entry.generation, payload)
		if _peers.get(entry.uuid) != entry or not _client_connected():
			return
		if sent != OK:
			entry.relay_attempts += 1
			if entry.relay_attempts >= signal_retry_budget:
				SFLogScript.error(
					(
						"mesh: signal relay to %s dropped after %d refused attempts"
						% [entry.uuid, entry.relay_attempts]
					)
				)
				entry.pending_signals.clear()
				entry.last_relayed_pending = false
				entry.relay_attempts = 0
				entry.relay_due_msec = 0
				entry.relay_dropped = true
			else:
				entry.relay_due_msec = Time.get_ticks_msec() + signal_retry_msec
			return
		var delivered: Dictionary = entry.pending_signals.pop_front()
		if is_same(delivered, entry.last_relayed):
			entry.last_relayed_pending = false
		entry.relay_attempts = 0


func _on_client_server_error(_message: String, error_code: int) -> void:
	# The error has no target peer, so retry each peer's last relay (issue #127).
	if error_code != SFErrorCodesScript.Code.SIGNAL_RATE_LIMITED:
		return
	if not _client_connected():
		return
	for uuid: String in _peers:
		var entry: _MeshPeer = _peers[uuid]
		if entry.relay_dropped or not entry.has_last_relayed:
			continue
		if entry.last_relayed_pending:
			continue
		if entry.pending_signals.size() >= MAX_PENDING_RELAYS:
			continue
		# The server-refused payload predates the queued local sends.
		entry.pending_signals.push_front(entry.last_relayed)
		entry.last_relayed_pending = true
		entry.relay_due_msec = Time.get_ticks_msec() + signal_retry_msec


func _client_connected() -> bool:
	return _client != null and _client.is_connected_to_server()


func _make_peer_connection() -> Object:
	if peer_connection_factory.is_valid():
		return peer_connection_factory.call()
	return WebRTCPeerConnection.new()


func _make_multiplayer_peer() -> Object:
	if multiplayer_peer_factory.is_valid():
		return multiplayer_peer_factory.call()
	return WebRTCMultiplayerPeer.new()


func _multiplayer_peer() -> Object:
	if _mp_peer == null:
		_mp_peer = _make_multiplayer_peer()
		var my_id := uuid_to_peer_id(_client.get_player_id() if _client != null else "")
		var error: Error = _mp_peer.call("create_mesh", my_id)
		if error != OK:
			SFLogScript.error("mesh: create_mesh refused (%d)" % error)
			_mp_peer.call("close")
			_mp_peer = null
	return _mp_peer


func _rtc_configuration() -> Dictionary:
	var ice_servers: Array[Dictionary] = []
	for server: SFSessionTypesScript.IceServerInfo in _ice_servers:
		var entry: Dictionary = {"urls": Array(server.urls)}
		if not server.username.is_empty():
			entry["username"] = server.username
		if not server.credential.is_empty():
			entry["credential"] = server.credential
		ice_servers.append(entry)
	return {"iceServers": ice_servers}


## A raw packet and its physical-channel metadata. Check error before using data.
class ReceivedPacket:
	extends RefCounted
	var peer_id: int = 0
	var transfer_mode: MultiplayerPeer.TransferMode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	var channel: int = 0
	var data: PackedByteArray = PackedByteArray()
	var error: Error = OK


class _MeshPeer:
	extends RefCounted
	var uuid: String = ""
	var peer_id: int = 0
	var connection: Object = null
	var initiate: bool = false
	var generation: String = ""
	var epoch: int = -1
	var attempt := 0
	var local_description_claimed := false
	var local_description_sent := false
	var remote_description_seen := false
	var early_ice: Array[String] = []
	var receive_channel_cursor: int = 0
	var session_cb: Callable = Callable()
	var ice_cb: Callable = Callable()
	var pending_signals: Array[Dictionary] = []
	var relay_due_msec: int = 0
	var relay_attempts: int = 0
	var relay_dropped: bool = false
	var last_relayed: Dictionary = {}
	var has_last_relayed: bool = false
	# Whether last_relayed is still in pending_signals. Tracked by identity at
	# the queue mutation sites so rate-limit healing never deep-compares the
	# queue (issue #339: peers x queue depth x payload bytes per event).
	# Identity is narrower than the content equality it replaces: a
	# content-equal copy may be re-queued once, which the documented
	# redelivery tolerance (redelivered ICE/SDP are idempotent) covers.
	var last_relayed_pending: bool = false
