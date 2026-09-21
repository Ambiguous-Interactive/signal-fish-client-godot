extends Control

const SignalFishClientScript := preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript := preload("res://addons/signal_fish/signal_fish_config.gd")
const SFTypesScript := preload("res://addons/signal_fish/protocol/sf_types.gd")

@onready var _endpoint: LineEdit = %EndpointEdit
@onready var _app_id: LineEdit = %AppIdEdit
@onready var _game_name: LineEdit = %GameEdit
@onready var _player_name: LineEdit = %PlayerEdit
@onready var _room_code: LineEdit = %RoomCodeEdit
@onready var _send_text: LineEdit = %SendTextEdit
@onready var _log: RichTextLabel = %LogLabel
@onready var _client: SignalFishClientScript = $Client


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
	_client.game_data_received.connect(_on_game_data_received)
	_client.pong.connect(func() -> void: _log_line("pong"))
	_client.server_error.connect(
		func(message: String, _error_code: int) -> void: _log_line("server error: " + message)
	)
	_log_line("fill in endpoint + app id, then Connect")


func _on_connect_pressed() -> void:
	if _endpoint.text.is_empty() or _app_id.text.is_empty():
		_log_line("endpoint and app id are required")
		return
	var config := SignalFishConfigScript.new()
	config.app_id = _app_id.text.strip_edges()
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


func _on_send_pressed() -> void:
	var payload := {"text": _send_text.text, "sent_at": Time.get_ticks_msec()}
	var error := _client.send_game_data(payload)
	_log_line("send: %s" % error_string(error))


func _on_ping_pressed() -> void:
	_log_line("ping: %s" % error_string(_client.ping()))


func _on_leave_pressed() -> void:
	_log_line("leave: %s" % error_string(_client.leave_room()))


func _on_disconnect_pressed() -> void:
	_log_line("close: %s" % error_string(_client.close()))


func _on_disconnected(code: int, reason: String) -> void:
	_log_line("disconnected: %d %s" % [code, reason])


func _on_authenticated(app_name: String, organization: String, _rate_limits: Variant) -> void:
	_log_line("authenticated as app '%s' (%s); join or create a room" % [app_name, organization])


func _on_room_joined(info: SFTypesScript.RoomJoinedInfo) -> void:
	_log_line("room joined: %s (code %s)" % [info.room_id, info.room_code])


func _on_game_data_received(from_player: String, data: Variant) -> void:
	_log_line("game data from %s: %s" % [from_player, str(data)])


func _log_line(line: String) -> void:
	_log.append_text(line + "\n")
