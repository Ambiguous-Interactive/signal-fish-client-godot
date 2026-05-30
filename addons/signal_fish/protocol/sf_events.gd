class_name SFEvents
extends RefCounted

const SFBinaryCodecScript = preload("res://addons/signal_fish/protocol/sf_binary_codec.gd")
const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")


static func decode_text(text: String) -> RefCounted:
	var decoded := SFEnvelopeScript.decode_text(text)
	if not decoded["ok"]:
		return _protocol_error(decoded["error"])
	return decode_envelope(decoded["envelope"])


static func decode_envelope(envelope: Dictionary) -> RefCounted:
	var decoded := SFEnvelopeScript.decode_envelope(envelope)
	if not decoded["ok"]:
		return _protocol_error(decoded["error"], envelope)
	var type_name := String(envelope["type"])
	var data := SFEnvelopeScript.data_or_empty(envelope)
	match type_name:
		"Authenticated":
			return _decode_authenticated(type_name, data, envelope)
		"ProtocolInfo":
			var protocol_info_error := SFTypesScript.validate_protocol_info(data)
			if not protocol_info_error.is_empty():
				return _protocol_error(protocol_info_error, envelope)
			return _event(
				type_name, &"protocol_info", [SFTypesScript.make_protocol_info(data)], envelope
			)
		"AuthenticationError":
			if not _has_string(data, "error"):
				return _protocol_error("AuthenticationError requires error", envelope)
			var authentication_error_code_error := _validate_required_error_code(
				data, "AuthenticationError"
			)
			if not authentication_error_code_error.is_empty():
				return _protocol_error(authentication_error_code_error, envelope)
			return _event(
				type_name,
				&"authentication_error",
				[String(data["error"]), SFErrorCodesScript.from_string(data["error_code"])],
				envelope
			)
		"RoomJoined":
			return _decode_room_joined(type_name, data, envelope)
		"RoomJoinFailed":
			if not _has_string(data, "reason"):
				return _protocol_error("RoomJoinFailed requires reason", envelope)
			var room_join_error_code_error := _validate_optional_error_code(data, "RoomJoinFailed")
			if not room_join_error_code_error.is_empty():
				return _protocol_error(room_join_error_code_error, envelope)
			return _event(
				type_name,
				&"room_join_failed",
				[String(data["reason"]), SFErrorCodesScript.from_string(data.get("error_code"))],
				envelope
			)
		"RoomLeft":
			return _event(type_name, &"room_left", [], envelope)
		"PlayerJoined":
			if not _has_dict(data, "player"):
				return _protocol_error("PlayerJoined requires player", envelope)
			var player_error := SFTypesScript.validate_player_info(data["player"])
			if not player_error.is_empty():
				return _protocol_error(player_error, envelope)
			return _event(
				type_name,
				&"player_joined",
				[SFTypesScript.make_player_info(data["player"])],
				envelope
			)
		"PlayerLeft":
			if not _has_string(data, "player_id"):
				return _protocol_error("PlayerLeft requires player_id", envelope)
			return _event(type_name, &"player_left", [String(data["player_id"])], envelope)
		"GameData":
			if not _has_string(data, "from_player") or not data.has("data"):
				return _protocol_error("GameData requires from_player and data", envelope)
			return _event(
				type_name,
				&"game_data_received",
				[String(data["from_player"]), data["data"]],
				envelope
			)
		"GameDataBinary":
			return _decode_game_data_binary(type_name, data, envelope)
		"AuthorityChanged":
			if not data.has("authority_player") or not _has_bool(data, "you_are_authority"):
				return _protocol_error(
					"AuthorityChanged requires authority_player and you_are_authority", envelope
				)
			var authority_value: Variant = data["authority_player"]
			if authority_value != null and typeof(authority_value) != TYPE_STRING:
				return _protocol_error(
					"AuthorityChanged authority_player must be a string", envelope
				)
			var authority_player := "" if authority_value == null else String(authority_value)
			return _event(
				type_name,
				&"authority_changed",
				[authority_player, bool(data["you_are_authority"])],
				envelope
			)
		"AuthorityResponse":
			if not _has_bool(data, "granted"):
				return _protocol_error("AuthorityResponse requires granted", envelope)
			if (
				data.has("reason")
				and data["reason"] != null
				and typeof(data["reason"]) != TYPE_STRING
			):
				return _protocol_error("AuthorityResponse reason must be a string", envelope)
			var authority_error_code_error := _validate_optional_error_code(
				data, "AuthorityResponse"
			)
			if not authority_error_code_error.is_empty():
				return _protocol_error(authority_error_code_error, envelope)
			return _event(
				type_name,
				&"authority_response",
				[
					bool(data["granted"]),
					_string_or_empty(data.get("reason")),
					SFErrorCodesScript.from_string(data.get("error_code"))
				],
				envelope
			)
		"LobbyStateChanged":
			return _decode_lobby_state_changed(type_name, data, envelope)
		"GameStarting":
			if not data.has("peer_connections"):
				return _protocol_error("GameStarting requires peer_connections", envelope)
			var peer_connections_error := SFTypesScript.validate_peer_connections_array(
				data["peer_connections"]
			)
			if not peer_connections_error.is_empty():
				return _protocol_error(
					"GameStarting peer_connections: %s" % peer_connections_error, envelope
				)
			return _event(
				type_name,
				&"game_starting",
				[SFTypesScript.peer_connections_from_array(data["peer_connections"])],
				envelope
			)
		"Pong":
			return _event(type_name, &"pong", [], envelope)
		"Reconnected":
			return _decode_reconnected(type_name, data, envelope)
		"ReconnectionFailed":
			if not _has_string(data, "reason"):
				return _protocol_error("ReconnectionFailed requires reason", envelope)
			var reconnection_error_code_error := _validate_required_error_code(
				data, "ReconnectionFailed"
			)
			if not reconnection_error_code_error.is_empty():
				return _protocol_error(reconnection_error_code_error, envelope)
			return _event(
				type_name,
				&"reconnection_failed",
				[String(data["reason"]), SFErrorCodesScript.from_string(data["error_code"])],
				envelope
			)
		"PlayerReconnected":
			if not _has_string(data, "player_id"):
				return _protocol_error("PlayerReconnected requires player_id", envelope)
			return _event(type_name, &"player_reconnected", [String(data["player_id"])], envelope)
		"SpectatorJoined":
			return _decode_spectator_joined(type_name, data, envelope)
		"SpectatorJoinFailed":
			if not _has_string(data, "reason"):
				return _protocol_error("SpectatorJoinFailed requires reason", envelope)
			var spectator_join_error_code_error := _validate_optional_error_code(
				data, "SpectatorJoinFailed"
			)
			if not spectator_join_error_code_error.is_empty():
				return _protocol_error(spectator_join_error_code_error, envelope)
			return _event(
				type_name,
				&"spectator_join_failed",
				[String(data["reason"]), SFErrorCodesScript.from_string(data.get("error_code"))],
				envelope
			)
		"SpectatorLeft":
			if (
				data.has("room_id")
				and data["room_id"] != null
				and typeof(data["room_id"]) != TYPE_STRING
			):
				return _protocol_error("SpectatorLeft room_id must be a string", envelope)
			if (
				data.has("room_code")
				and data["room_code"] != null
				and typeof(data["room_code"]) != TYPE_STRING
			):
				return _protocol_error("SpectatorLeft room_code must be a string", envelope)
			var spectator_left_reason_error := SFTypesScript.validate_optional_spectator_reason(
				data, "reason", "SpectatorLeft"
			)
			if not spectator_left_reason_error.is_empty():
				return _protocol_error(spectator_left_reason_error, envelope)
			var spectator_left_error := SFTypesScript.validate_spectators_array(
				data.get("current_spectators", [])
			)
			if not spectator_left_error.is_empty():
				return _protocol_error(
					"SpectatorLeft current_spectators: %s" % spectator_left_error, envelope
				)
			return _event(
				type_name,
				&"spectator_left",
				[
					_string_or_empty(data.get("room_id")),
					_string_or_empty(data.get("room_code")),
					SFTypesScript.spectator_reason_from_string(data.get("reason", "")),
					SFTypesScript.spectators_from_array(data.get("current_spectators", []))
				],
				envelope
			)
		"NewSpectatorJoined":
			if not _has_dict(data, "spectator"):
				return _protocol_error("NewSpectatorJoined requires spectator", envelope)
			var new_spectator_reason_error := SFTypesScript.validate_optional_spectator_reason(
				data, "reason", "NewSpectatorJoined"
			)
			if not new_spectator_reason_error.is_empty():
				return _protocol_error(new_spectator_reason_error, envelope)
			var new_spectator_error := SFTypesScript.validate_spectator_info(data["spectator"])
			if not new_spectator_error.is_empty():
				return _protocol_error(new_spectator_error, envelope)
			var new_current_spectators_error := SFTypesScript.validate_spectators_array(
				data.get("current_spectators", [])
			)
			if not new_current_spectators_error.is_empty():
				return _protocol_error(
					"NewSpectatorJoined current_spectators: %s" % new_current_spectators_error,
					envelope
				)
			return _event(
				type_name,
				&"new_spectator_joined",
				[
					SFTypesScript.make_spectator_info(data["spectator"]),
					SFTypesScript.spectators_from_array(data.get("current_spectators", [])),
					SFTypesScript.spectator_reason_from_string(data.get("reason", ""))
				],
				envelope
			)
		"SpectatorDisconnected":
			if not _has_string(data, "spectator_id"):
				return _protocol_error("SpectatorDisconnected requires spectator_id", envelope)
			var disconnected_reason_error := SFTypesScript.validate_optional_spectator_reason(
				data, "reason", "SpectatorDisconnected"
			)
			if not disconnected_reason_error.is_empty():
				return _protocol_error(disconnected_reason_error, envelope)
			var disconnected_spectators_error := SFTypesScript.validate_spectators_array(
				data.get("current_spectators", [])
			)
			if not disconnected_spectators_error.is_empty():
				return _protocol_error(
					"SpectatorDisconnected current_spectators: %s" % disconnected_spectators_error,
					envelope
				)
			return _event(
				type_name,
				&"spectator_disconnected",
				[
					String(data["spectator_id"]),
					SFTypesScript.spectator_reason_from_string(data.get("reason", "")),
					SFTypesScript.spectators_from_array(data.get("current_spectators", []))
				],
				envelope
			)
		"Error":
			if not _has_string(data, "message"):
				return _protocol_error("Error requires message", envelope)
			var server_error_code_error := _validate_optional_error_code(data, "Error")
			if not server_error_code_error.is_empty():
				return _protocol_error(server_error_code_error, envelope)
			return _event(
				type_name,
				&"server_error",
				[String(data["message"]), SFErrorCodesScript.from_string(data.get("error_code"))],
				envelope
			)
		_:
			return _protocol_error("unknown message type: %s" % type_name, envelope)


static func _decode_authenticated(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	if not _has_string(data, "app_name") or not _has_dict(data, "rate_limits"):
		return _protocol_error("Authenticated requires app_name and rate_limits", envelope)
	var rate_limits_error := SFTypesScript.validate_rate_limit_info(data["rate_limits"])
	if not rate_limits_error.is_empty():
		return _protocol_error(rate_limits_error, envelope)
	return _event(
		type_name,
		&"authenticated",
		[
			String(data["app_name"]),
			_string_or_empty(data.get("organization")),
			SFTypesScript.make_rate_limit_info(data["rate_limits"])
		],
		envelope
	)


static func _decode_room_joined(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	var required := [
		"room_id",
		"room_code",
		"player_id",
		"game_name",
		"max_players",
		"supports_authority",
		"current_players",
		"is_authority",
		"lobby_state",
		"ready_players",
		"relay_type"
	]
	for key: String in required:
		if not data.has(key):
			return _protocol_error("RoomJoined requires %s" % key, envelope)
	var room_error := SFTypesScript.validate_room_joined_info(data)
	if not room_error.is_empty():
		return _protocol_error(room_error, envelope)
	return _event(type_name, &"room_joined", [SFTypesScript.make_room_joined_info(data)], envelope)


static func _decode_game_data_binary(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	if (
		not _has_string(data, "from_player")
		or not _has_string(data, "encoding")
		or not data.has("payload")
	):
		return _protocol_error(
			"GameDataBinary requires from_player, encoding, and payload", envelope
		)
	var payload_result := SFBinaryCodecScript.decode_payload(data["payload"])
	if not payload_result["ok"]:
		return _protocol_error(payload_result["error"], envelope)
	var encoding: int = SFTypesScript.game_data_encoding_from_string(data["encoding"])
	if encoding == SFTypesScript.GameDataEncoding.UNKNOWN:
		return _protocol_error("GameDataBinary encoding is unknown", envelope)
	return _event(
		type_name,
		&"game_data_binary_received",
		[String(data["from_player"]), encoding, payload_result["bytes"]],
		envelope
	)


static func _decode_lobby_state_changed(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	if not data.has("lobby_state") or not data.has("ready_players") or not data.has("all_ready"):
		return _protocol_error(
			"LobbyStateChanged requires lobby_state, ready_players, and all_ready", envelope
		)
	if typeof(data["ready_players"]) != TYPE_ARRAY or not _has_bool(data, "all_ready"):
		return _protocol_error("LobbyStateChanged has invalid field types", envelope)
	if (
		typeof(data["lobby_state"]) != TYPE_STRING
		or (
			SFTypesScript.lobby_state_from_string(data["lobby_state"])
			== SFTypesScript.LobbyState.UNKNOWN
		)
	):
		return _protocol_error("LobbyStateChanged lobby_state is unknown", envelope)
	if not _array_contains_only_strings(data["ready_players"]):
		return _protocol_error("LobbyStateChanged ready_players must be strings", envelope)
	return _event(
		type_name,
		&"lobby_state_changed",
		[
			SFTypesScript.lobby_state_from_string(data["lobby_state"]),
			_strings_from_array(data["ready_players"]),
			bool(data["all_ready"])
		],
		envelope
	)


static func _decode_reconnected(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	if not data.has("missed_events") or typeof(data["missed_events"]) != TYPE_ARRAY:
		return _protocol_error("Reconnected requires missed_events", envelope)
	var room_event := _decode_room_joined(type_name, data, envelope)
	if room_event.signal_name == &"protocol_error":
		return room_event
	var missed_events: Array = []
	for missed: Variant in data["missed_events"]:
		if typeof(missed) != TYPE_DICTIONARY:
			return _protocol_error("Reconnected missed_events entries must be objects", envelope)
		var decoded_missed := decode_envelope(missed)
		if decoded_missed.signal_name == &"protocol_error":
			return _protocol_error("Reconnected contains malformed missed event", envelope)
		missed_events.append(decoded_missed)
	return _event(
		type_name,
		&"reconnected",
		[SFTypesScript.make_room_joined_info(data), missed_events],
		envelope
	)


static func _decode_spectator_joined(
	type_name: String, data: Dictionary, envelope: Dictionary
) -> RefCounted:
	var required := [
		"room_id",
		"room_code",
		"spectator_id",
		"game_name",
		"current_players",
		"current_spectators",
		"lobby_state"
	]
	for key: String in required:
		if not data.has(key):
			return _protocol_error("SpectatorJoined requires %s" % key, envelope)
	var spectator_joined_error := SFTypesScript.validate_spectator_joined_info(data)
	if not spectator_joined_error.is_empty():
		return _protocol_error(spectator_joined_error, envelope)
	return _event(
		type_name, &"spectator_joined", [SFTypesScript.make_spectator_joined_info(data)], envelope
	)


static func _event(
	type_name: String, signal_name: StringName, args: Array, envelope: Dictionary
) -> RefCounted:
	return SFTypesScript.make_decoded_event(type_name, signal_name, args, envelope)


static func _protocol_error(message: String, envelope: Variant = null) -> RefCounted:
	var raw: Dictionary = {}
	if typeof(envelope) == TYPE_DICTIONARY:
		raw = envelope
	return SFTypesScript.make_decoded_event("ProtocolError", &"protocol_error", [message], raw)


static func _has_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING


static func _has_bool(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_BOOL


static func _has_dict(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_DICTIONARY


static func _validate_required_error_code(data: Dictionary, event_name: String) -> String:
	if not data.has("error_code") or typeof(data["error_code"]) != TYPE_STRING:
		return "%s requires string error_code" % event_name
	if not SFErrorCodesScript.is_known(data["error_code"]):
		return "%s error_code is unknown" % event_name
	return ""


static func _validate_optional_error_code(data: Dictionary, event_name: String) -> String:
	if not data.has("error_code") or data["error_code"] == null:
		return ""
	if typeof(data["error_code"]) != TYPE_STRING:
		return "%s error_code must be a string" % event_name
	if not SFErrorCodesScript.is_known(data["error_code"]):
		return "%s error_code is unknown" % event_name
	return ""


static func _strings_from_array(values: Array) -> PackedStringArray:
	var result := PackedStringArray()
	for value: Variant in values:
		result.append(String(value))
	return result


static func _string_or_empty(value: Variant) -> String:
	if value == null:
		return ""
	return String(value)


static func _array_contains_only_strings(values: Array) -> bool:
	for value: Variant in values:
		if typeof(value) != TYPE_STRING:
			return false
	return true
