class_name SFMessages
extends RefCounted

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")


static func authenticate(
	app_id: String,
	sdk_version: Variant = null,
	platform: Variant = null,
	game_data_format: Variant = null
) -> Dictionary:
	var data: Dictionary = {}
	data["app_id"] = app_id
	_add_optional_string(data, "sdk_version", sdk_version)
	_add_optional_string(data, "platform", platform)
	_add_optional_game_data_encoding(data, "game_data_format", game_data_format)
	return SFEnvelopeScript.message("Authenticate", data)


static func join_room(
	game_name: String,
	player_name: String,
	room_code: Variant = null,
	max_players: Variant = null,
	supports_authority: Variant = null,
	relay_transport: Variant = null
) -> Dictionary:
	var data: Dictionary = {}
	data["game_name"] = game_name
	_add_optional_string(data, "room_code", room_code)
	data["player_name"] = player_name
	if max_players != null:
		data["max_players"] = int(max_players)
	if supports_authority != null:
		data["supports_authority"] = bool(supports_authority)
	_add_optional_relay_transport(data, "relay_transport", relay_transport)
	return SFEnvelopeScript.message("JoinRoom", data)


static func leave_room() -> Dictionary:
	return SFEnvelopeScript.message("LeaveRoom")


static func game_data(data_payload: Variant) -> Dictionary:
	var data: Dictionary = {}
	data["data"] = data_payload
	return SFEnvelopeScript.message("GameData", data)


static func authority_request(become_authority: bool) -> Dictionary:
	var data: Dictionary = {}
	data["become_authority"] = become_authority
	return SFEnvelopeScript.message("AuthorityRequest", data)


static func player_ready() -> Dictionary:
	return SFEnvelopeScript.message("PlayerReady")


static func provide_connection_info(connection_info: Dictionary) -> Dictionary:
	var data: Dictionary = {}
	data["connection_info"] = connection_info
	return SFEnvelopeScript.message("ProvideConnectionInfo", data)


static func ping() -> Dictionary:
	return SFEnvelopeScript.message("Ping")


static func reconnect(player_id: String, room_id: String, auth_token: String) -> Dictionary:
	var data: Dictionary = {}
	data["player_id"] = player_id
	data["room_id"] = room_id
	data["auth_token"] = auth_token
	return SFEnvelopeScript.message("Reconnect", data)


static func join_as_spectator(
	game_name: String, room_code: String, spectator_name: String
) -> Dictionary:
	var data: Dictionary = {}
	data["game_name"] = game_name
	data["room_code"] = room_code
	data["spectator_name"] = spectator_name
	return SFEnvelopeScript.message("JoinAsSpectator", data)


static func leave_spectator() -> Dictionary:
	return SFEnvelopeScript.message("LeaveSpectator")


static func encode(envelope: Dictionary) -> String:
	return SFEnvelopeScript.encode(envelope)


static func _add_optional_string(data: Dictionary, key: String, value: Variant) -> void:
	if value == null:
		return
	var string_value := String(value)
	if string_value.is_empty():
		return
	data[key] = string_value


static func _add_optional_game_data_encoding(data: Dictionary, key: String, value: Variant) -> void:
	if value == null:
		return
	if typeof(value) == TYPE_INT:
		var encoded := SFTypesScript.game_data_encoding_to_string(int(value))
		if encoded != "unknown":
			data[key] = encoded
		return
	_add_optional_string(data, key, value)


static func _add_optional_relay_transport(data: Dictionary, key: String, value: Variant) -> void:
	if value == null:
		return
	if typeof(value) == TYPE_INT:
		var encoded := SFTypesScript.relay_transport_to_string(int(value))
		if encoded != "unknown":
			data[key] = encoded
		return
	_add_optional_string(data, key, value)
