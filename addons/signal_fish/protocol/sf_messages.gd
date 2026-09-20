class_name SFMessages
extends RefCounted

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")


static func authenticate(
	app_id: String,
	sdk_version: Variant = null,
	platform: Variant = null,
	game_data_format: Variant = null,
	protocol_version: Variant = null,
	supported_transports: Variant = null,
	supported_topologies: Variant = null,
	requested_capabilities: Variant = null,
	connect_token: Variant = null
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
	error = _add_optional_u16(data, "protocol_version", protocol_version)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	# Absent means relay-only upstream, even on /v3/ws (server docs
	# "Protocol v2 vs v3"): unset lists are omitted, never sent empty.
	error = _add_optional_token_list(
		data,
		"supported_transports",
		supported_transports,
		SFSessionTypesScript.TRANSPORT_KIND_FROM_STRING
	)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	error = _add_optional_token_list(
		data,
		"supported_topologies",
		supported_topologies,
		SFSessionTypesScript.TOPOLOGY_FROM_STRING
	)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	error = _add_optional_string_list(data, "requested_capabilities", requested_capabilities)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	# Tenant credential (upstream `Authenticate.connect_token`, rust SDK
	# 0.14.0). Secret: set in code only, never logged.
	error = _add_optional_string(data, "connect_token", connect_token)
	if not error.is_empty():
		return _invalid_message("Authenticate", error, data)
	return SFEnvelopeScript.message("Authenticate", data)


static func join_room(
	game_name: String,
	player_name: String,
	room_code: Variant = null,
	max_players: Variant = null,
	supports_authority: Variant = null,
	relay_transport: Variant = null,
	password: Variant = null
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
	error = _add_optional_string(data, "password", password)
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
	game_name: String, room_code: String, spectator_name: String, password: Variant = null
) -> Dictionary:
	var data: Dictionary = {}
	data["game_name"] = game_name
	data["room_code"] = room_code
	data["spectator_name"] = spectator_name
	var error := _add_optional_string(data, "password", password)
	if not error.is_empty():
		return _invalid_message("JoinAsSpectator", error, data)
	return SFEnvelopeScript.message("JoinAsSpectator", data)


static func leave_spectator() -> Dictionary:
	return SFEnvelopeScript.message("LeaveSpectator")


## Explicitly finalizes the lobby with its current members (upstream
## `ClientMessage::StartGame`, v2 unit message). Accepted only when every
## current player is ready and the sender may start (authority-designated
## rooms restrict it to the authority); otherwise the server answers
## `Error{GameStartNotReady}` / `Error{GameStartForbidden}`.
static func start_game() -> Dictionary:
	return SFEnvelopeScript.message("StartGame")


## Relay one opaque WebRTC signal to a peer (protocol v3, upstream
## `ClientMessage::Signal`). Named [code]peer_signal[/code] here because
## [code]signal[/code] is a GDScript keyword. The payload is forwarded
## verbatim by the server; by convention it is matchbox-shaped:
## [code]{"Offer": sdp}[/code], [code]{"Answer": sdp}[/code], or
## [code]{"IceCandidate": candidate}[/code]. [param generation] is the
## generation of the sender's latest authoritative session plan; the pinned
## server requires it, legacy Server 0.4 plans have none, so an empty string
## omits the field (rust-client parity). JSON-shape check: nulls inside
## nested arrays/objects are refused locally (send an empty-string sentinel
## or omit the entry) even though upstream forwards them.
static func peer_signal(
	to: String, generation: Variant = null, signal_payload: Variant = null
) -> Dictionary:
	var data: Dictionary = {}
	if to.is_empty():
		return _invalid_message("Signal", "to must not be empty", data)
	data["to"] = to
	var error := _add_optional_string(data, "generation", generation)
	if not error.is_empty():
		return _invalid_message("Signal", error, data)
	if not _is_json_value(signal_payload):
		return _invalid_message("Signal", "signal payload is required and must be JSON data", data)
	data["signal"] = signal_payload
	return SFEnvelopeScript.message("Signal", data)


## Report the current data-path transport state (protocol v3, upstream
## `ClientMessage::TransportStatus`). Informational: the relay floor never
## closes regardless of what is reported.
static func transport_status(transport: Variant, connected: bool) -> Dictionary:
	var token := _transport_kind_token(transport)
	if token.is_empty():
		return _invalid_message("TransportStatus", "transport is unknown", {})
	return SFEnvelopeScript.message("TransportStatus", {"transport": token, "connected": connected})


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
		return "%s must not be empty" % key
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
		return "%s must not be empty" % key
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


static func _add_optional_u16(data: Dictionary, key: String, value: Variant) -> String:
	if value == null:
		return ""
	if not _is_integral_number(value):
		return "%s must be an integer" % key
	var int_value := int(value)
	if int_value < 0 or int_value > SFTypesScript.U16_MAX:
		return "%s must be in range 0..%d" % [key, SFTypesScript.U16_MAX]
	if int_value == 0:
		# 0 is the client-side "unset" convention (v2 default); omit it so the
		# wire bytes stay identical to a v2 handshake.
		return ""
	data[key] = int_value
	return ""


static func _add_optional_token_list(
	data: Dictionary, key: String, values: Variant, from_string: Dictionary
) -> String:
	if values == null:
		return ""
	if typeof(values) != TYPE_ARRAY and not (values is PackedStringArray):
		return "%s must be an array" % key
	var tokens: Array = []
	for value: Variant in values:
		var token := _enum_token(value, from_string)
		if token.is_empty():
			return "%s contains an unknown token" % key
		tokens.append(token)
	if tokens.is_empty():
		return ""
	data[key] = tokens
	return ""


static func _add_optional_string_list(data: Dictionary, key: String, values: Variant) -> String:
	if values == null:
		return ""
	if typeof(values) != TYPE_ARRAY and not (values is PackedStringArray):
		return "%s must be an array" % key
	var tokens: Array = []
	for value: Variant in values:
		if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
			return "%s must contain strings" % key
		var token := String(value)
		if token.is_empty():
			return "%s must not contain empty strings" % key
		tokens.append(token)
	if tokens.is_empty():
		return ""
	data[key] = tokens
	return ""


static func _enum_token(value: Variant, from_string: Dictionary) -> String:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		if not _is_integral_number(value):
			return ""
		for token: String in from_string:
			if int(from_string[token]) == int(value):
				return token
		return ""
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return ""
	var token := String(value)
	return token if from_string.has(token) else ""


static func _transport_kind_token(value: Variant) -> String:
	return _enum_token(value, SFSessionTypesScript.TRANSPORT_KIND_FROM_STRING)


static func _is_json_value(value: Variant) -> bool:
	return _is_json_value_depth(value, 0)


## Recursive JSON-shape check so a payload containing engine-only Variants
## (e.g. a nested Vector2) is refused locally instead of being silently
## stringified onto the wire by JSON.stringify.
static func _is_json_value_depth(value: Variant, depth: int) -> bool:
	if depth > SFTypeUtils.MAX_MESSAGE_DEPTH:
		return false
	match typeof(value):
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			for key: Variant in dict:
				if typeof(key) != TYPE_STRING:
					return false
				if not _is_json_value_depth(dict[key], depth + 1):
					return false
			return true
		TYPE_ARRAY:
			for entry: Variant in value:
				if not _is_json_value_depth(entry, depth + 1):
					return false
			return true
		# Whitelist the JSON-representable scalars; engine-only Variants
		# (Vector2, Color, ...) would be silently stringified by
		# JSON.stringify, and null is refused by the caller (required field).
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return true
		_:
			return false


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
