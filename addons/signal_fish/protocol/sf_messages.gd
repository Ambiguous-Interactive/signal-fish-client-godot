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
	var error := _add_optional_string(data, "sdk_version", sdk_version)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	error = _add_optional_string(data, "platform", platform)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	error = _add_optional_game_data_encoding(data, "game_data_format", game_data_format)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
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
	var error := _add_optional_string(data, "room_code", room_code)
	if not error.is_empty():
		return _invalid_message("JoinRoom", error, data)
	data["player_name"] = player_name
	if max_players != null:
		error = _add_optional_u8(data, "max_players", max_players, 1)
		if not error.is_empty():
			return _invalid_message("JoinRoom", error, data)
	if supports_authority != null:
		error = _add_optional_bool(data, "supports_authority", supports_authority)
		if not error.is_empty():
			return _invalid_message("JoinRoom", error, data)
	error = _add_optional_relay_transport(data, "relay_transport", relay_transport)
	if not error.is_empty():
		return _invalid_message("JoinRoom", error, data)
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
	var error := SFTypesScript.validate_outbound_connection_info(connection_info)
	if not error.is_empty():
		return _invalid_message("ProvideConnectionInfo", error, data)
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


static func is_valid_message(envelope: Dictionary) -> bool:
	return not SFEnvelopeScript.is_invalid_message(envelope)


static func validation_error(envelope: Dictionary) -> String:
	return SFEnvelopeScript.invalid_message_error(envelope)


static func _add_optional_string(data: Dictionary, key: String, value: Variant) -> String:
	if value == null:
		return ""
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return "%s must be a string" % key
	var string_value := String(value)
	if string_value.is_empty():
		return ""
	data[key] = string_value
	return ""


static func _add_optional_game_data_encoding(
	data: Dictionary, key: String, value: Variant
) -> String:
	if value == null:
		return ""
	if typeof(value) == TYPE_INT:
		var encoded := SFTypesScript.game_data_encoding_to_string(int(value))
		if encoded == "unknown":
			return "%s is unknown" % key
		data[key] = encoded
		return ""
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return "%s must be a string or enum value" % key
	var string_value := String(value)
	if string_value.is_empty():
		return ""
	if (
		SFTypesScript.game_data_encoding_from_string(string_value)
		== SFTypesScript.GameDataEncoding.UNKNOWN
	):
		return "%s is unknown" % key
	data[key] = string_value
	return ""


static func _add_optional_relay_transport(data: Dictionary, key: String, value: Variant) -> String:
	if value == null:
		return ""
	if typeof(value) == TYPE_INT:
		var encoded := SFTypesScript.relay_transport_to_string(int(value))
		if encoded == "unknown":
			return "%s is unknown" % key
		data[key] = encoded
		return ""
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return "%s must be a string or enum value" % key
	var string_value := String(value)
	if string_value.is_empty():
		return ""
	if (
		SFTypesScript.relay_transport_from_string(string_value)
		== SFTypesScript.RelayTransport.UNKNOWN
	):
		return "%s is unknown" % key
	data[key] = string_value
	return ""


static func _add_optional_u8(
	data: Dictionary, key: String, value: Variant, min_value: int = 0
) -> String:
	if not _is_integral_number(value):
		return "%s must be an integer" % key
	var int_value := int(value)
	if int_value < min_value or int_value > SFTypesScript.U8_MAX:
		return "%s must be in range %d..%d" % [key, min_value, SFTypesScript.U8_MAX]
	data[key] = int_value
	return ""


static func _add_optional_bool(data: Dictionary, key: String, value: Variant) -> String:
	if typeof(value) != TYPE_BOOL:
		return "%s must be a bool" % key
	data[key] = value
	return ""


static func _invalid_message(type_name: String, error: String, data: Dictionary) -> Dictionary:
	return SFEnvelopeScript.invalid_message(type_name, error, data)


static func _is_integral_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return number == floor(number)
