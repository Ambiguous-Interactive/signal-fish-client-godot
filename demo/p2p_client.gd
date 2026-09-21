extends Control

## P2P demo (PLAN P3): the relayed demo plus the opt-in WebRTC mesh. Connects
## with a v3 config, attaches [SFWebRTCMesh] before joining, then chats over
## mesh RPCs once a webrtc session plan lands. Run two instances against the
## same room to see the peer connection form; the server decides who offers.

const SignalFishClientScript := preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript := preload("res://addons/signal_fish/signal_fish_config.gd")
const SFSessionTypesScript := preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript := preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFWebRTCMeshScript := preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")

@onready var _endpoint: LineEdit = %EndpointEdit
@onready var _app_id: LineEdit = %AppIdEdit
@onready var _game_name: LineEdit = %GameEdit
@onready var _player_name: LineEdit = %PlayerEdit
@onready var _room_code: LineEdit = %RoomCodeEdit
@onready var _chat_text: LineEdit = %ChatTextEdit
@onready var _log: RichTextLabel = %LogLabel
@onready var _client: SignalFishClientScript = $Client
@onready var _mesh: SFWebRTCMeshScript = $Mesh


func _ready() -> void:
	_client.connected.connect(func() -> void: _log_line("connected"))
	_client.disconnected.connect(_on_disconnected)
	_client.connection_failed.connect(
		func(error: String) -> void: _log_line("connection failed: " + error)
	)
	_client.protocol_error.connect(
		func(error: String) -> void: _log_line("protocol error: " + error)
	)
	_client.authenticated.connect(_on_authenticated)
	_client.authentication_error.connect(
		func(error: String, _error_code: int) -> void: _log_line("auth failed: " + error)
	)
	_client.room_joined.connect(_on_room_joined)
	_client.room_join_failed.connect(
		func(reason: String, _error_code: int) -> void: _log_line("join failed: " + reason)
	)
	_client.room_left.connect(func() -> void: _log_line("room left"))
	_client.player_joined.connect(
		func(player: SFTypesScript.PlayerInfo) -> void: _log_line("player joined: " + player.name)
	)
	_client.player_left.connect(
		func(player_id: String) -> void: _log_line("player left: " + player_id)
	)
	_client.protocol_info.connect(_on_protocol_info)
	_client.session_plan.connect(_on_session_plan)
	_client.new_peer.connect(_on_new_peer)
	_client.peer_transport_status.connect(_on_peer_transport_status)
	_client.server_error.connect(
		func(message: String, _error_code: int) -> void: _log_line("server error: " + message)
	)
	var error := _mesh.attach(_client)
	if error != OK:
		_log_line("mesh attach failed: %s" % error_string(error))
	_log_line("v3 P2P demo: fill in endpoint + app id, then Connect")


func _process(_delta: float) -> void:
	var mp_peer: Variant = _mesh.get_multiplayer_peer()
	if mp_peer == multiplayer.multiplayer_peer:
		return
	if mp_peer != null:
		multiplayer.multiplayer_peer = mp_peer
		_log_line("mesh multiplayer peer ready")
	elif multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return
	else:
		multiplayer.multiplayer_peer = null


func _on_connect_pressed() -> void:
	if _endpoint.text.is_empty() or _app_id.text.is_empty():
		_log_line("endpoint and app id are required")
		return
	var config := SignalFishConfigScript.new()
	config.app_id = _app_id.text.strip_edges()
	config.protocol_version = 3
	config.supported_transports = PackedStringArray(["relay", "webrtc"])
	config.supported_topologies = PackedStringArray(["relay", "mesh"])
	var error := _client.configure(config)
	if error != OK:
		_log_line("configure failed: %s" % error_string(error))
		return
	error = _client.connect_to_server(_endpoint.text.strip_edges())
	_log_line("connect: %s" % error_string(error))


func _on_join_pressed() -> void:
	var params := SignalFishClientScript.JoinRoomParams.new()
	params.game_name = _game_name.text.strip_edges()
	params.player_name = _player_name.text.strip_edges()
	params.room_code = _room_code.text.strip_edges()
	var error := _client.join_room(params)
	_log_line("join: %s" % error_string(error))


func _on_send_chat_pressed() -> void:
	var mp_peer: Variant = _mesh.get_multiplayer_peer()
	if mp_peer == null or multiplayer.multiplayer_peer != mp_peer:
		_log_line("no mesh yet: chat needs a webrtc session plan with peers")
		return
	chat.rpc(_player_name.text.strip_edges(), _chat_text.text)


func _on_leave_pressed() -> void:
	_log_line("leave: %s" % error_string(_client.leave_room()))


func _on_disconnect_pressed() -> void:
	_log_line("close: %s" % error_string(_client.close()))


@rpc("any_peer", "call_local", "reliable")
func chat(from_name: String, text: String) -> void:
	_log_line("chat %s: %s" % [from_name, text])


func _on_disconnected(code: int, reason: String) -> void:
	_log_line("disconnected: %d %s" % [code, reason])


func _on_authenticated(app_name: String, organization: String, _rate_limits: Variant) -> void:
	_log_line("authenticated as app '%s' (%s); join or create a room" % [app_name, organization])


func _on_protocol_info(info: SFTypesScript.ProtocolInfo) -> void:
	_log_line("protocol negotiated: v%d" % info.protocol_version)


func _on_room_joined(info: SFTypesScript.RoomJoinedInfo) -> void:
	_log_line("room joined: %s (code %s)" % [info.room_id, info.room_code])


func _on_session_plan(plan: SFSessionTypesScript.SessionPlanInfo) -> void:
	_log_line(
		(
			"session plan gen %s: %s over %s (%d peers)"
			% [
				plan.generation,
				SFSessionTypesScript.topology_to_string(plan.topology),
				SFSessionTypesScript.transport_kind_to_string(plan.transport),
				plan.peers.size(),
			]
		)
	)


func _on_new_peer(peer_id: String, you_initiate: bool) -> void:
	_log_line("new peer %s (we %s)" % [peer_id, "offer" if you_initiate else "answer"])


func _on_peer_transport_status(peer_id: String, transport: int, connected: bool) -> void:
	_log_line(
		(
			"peer %s %s %s"
			% [
				peer_id,
				SFSessionTypesScript.transport_kind_to_string(transport),
				"connected" if connected else "disconnected",
			]
		)
	)


func _log_line(line: String) -> void:
	# Raw text: peer-supplied strings must not parse as BBCode or forge lines.
	_log.add_text(line + "\n")
