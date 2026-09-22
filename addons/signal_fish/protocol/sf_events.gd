class_name SFEvents
extends RefCounted

## Maximum nesting depth for decoded envelopes, sourced from the shared
## protocol cap (SFTypeUtils.MAX_MESSAGE_DEPTH). Wire-reachable inputs are
## already bounded (the engine's JSON parser rejects overly deep documents,
## and nested Reconnected entries are rejected as non-replayable below); this
## cap is defense in depth for any future recursive message variant, matching
## the spirit of serde's 128-level recursion cap in the Rust client.
const MAX_MESSAGE_DEPTH := SFTypeUtils.MAX_MESSAGE_DEPTH

## Maximum number of Reconnected.missed_events entries decoded per envelope.
## Bounds decode work and the number of per-entry decoded objects against a
## hostile or misbehaving server; excess entries are dropped with a single
## protocol_error entry.
const MAX_MISSED_EVENTS := 256

const SFBinaryCodecScript = preload("res://addons/signal_fish/protocol/sf_binary_codec.gd")
const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")


static func decode_text(text: String) -> RefCounted:
	var decoded := SFEnvelopeScript.decode_text(text)
	if not decoded["ok"]:
		return _protocol_error(decoded["error"])
	return decode_envelope(decoded["envelope"])


static func decode_envelope(envelope: Dictionary, depth := 0) -> RefCounted:
	if depth > MAX_MESSAGE_DEPTH:
		return _protocol_error("message nesting exceeds depth %d" % MAX_MESSAGE_DEPTH, envelope)
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
			# The payload tree is consumer-facing passthrough: bound its
			# nesting and refuse non-finite numbers (issue #88).
			var game_data_payload_error := SFTypeUtils.passthrough_payload_error(data["data"])
			if not game_data_payload_error.is_empty():
				return _protocol_error(game_data_payload_error, envelope)
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
		"Signal":
			return _decode_signal(type_name, data, envelope)
		"NewPeer":
			if not _has_string(data, "peer_id") or not _has_bool(data, "you_initiate"):
				return _protocol_error("NewPeer requires peer_id and you_initiate", envelope)
			return _event(
				type_name,
				&"new_peer",
				[String(data["peer_id"]), bool(data["you_initiate"])],
				envelope
			)
		"SessionPlan":
			var session_plan_error := SFSessionTypesScript.validate_session_plan_info(data)
			if not session_plan_error.is_empty():
				return _protocol_error(session_plan_error, envelope)
			return _event(
				type_name,
				&"session_plan",
				[SFSessionTypesScript.make_session_plan_info(data)],
				envelope
			)
		"PeerTransportStatus":
			if not _has_string(data, "peer_id") or not _has_bool(data, "connected"):
				return _protocol_error(
					"PeerTransportStatus requires peer_id and connected", envelope
				)
			if (
				SFSessionTypesScript.transport_kind_from_string(data.get("transport", ""))
				== SFSessionTypesScript.TransportKind.UNKNOWN
			):
				return _protocol_error("PeerTransportStatus transport is unknown", envelope)
			return _event(
				type_name,
				&"peer_transport_status",
				[
					String(data["peer_id"]),
					SFSessionTypesScript.transport_kind_from_string(data["transport"]),
					bool(data["connected"])
				],
				envelope
			)
		"Reconnected":
			return _decode_reconnected(type_name, data, envelope, depth)
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
	if (
		data.has("organization")
		and data["organization"] != null
		and typeof(data["organization"]) != TYPE_STRING
	):
		return _protocol_error("Authenticated organization must be a string", envelope)
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
			# type_name is RoomJoined or Reconnected: both share the payload
			# shape, so diagnostics must name the envelope they came from.
			return _protocol_error("%s requires %s" % [type_name, key], envelope)
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
	if String(data["encoding"]).is_empty():
		return _protocol_error("GameDataBinary encoding must not be empty", envelope)
	var payload_result := SFBinaryCodecScript.decode_payload(data["payload"])
	if not payload_result["ok"]:
		return _protocol_error(payload_result["error"], envelope)
	var encoding: int = SFTypesScript.game_data_encoding_from_string(data["encoding"])
	return _event(
		type_name,
		&"game_data_binary_received",
		[String(data["from_player"]), encoding, payload_result["bytes"]],
		envelope
	)


## Relayed opaque WebRTC signal from another peer (protocol v3, upstream
## `ServerMessage::Signal`). The payload is forwarded verbatim from the
## sender's `Signal` client message (matchbox convention:
## [code]{"Offer"|"Answer"|"IceCandidate": ...}[/code]); unknown future shapes
## round-trip untouched, including JSON null (upstream `Value::Null`), so
## consumers must null-check [code]args[2][/code] before indexing.
## [code]generation[/code] is "" when the sender's
## legacy Server 0.4 plan had none.
static func _decode_signal(type_name: String, data: Dictionary, envelope: Dictionary) -> RefCounted:
	if not _has_string(data, "from") or not data.has("signal"):
		return _protocol_error("Signal requires from and signal", envelope)
	if data.has("generation") and data["generation"] != null:
		if typeof(data["generation"]) != TYPE_STRING:
			return _protocol_error("Signal generation must be a string", envelope)
	# The relayed payload is consumer-facing passthrough: bound its nesting
	# and refuse non-finite numbers (issue #88).
	var signal_payload_error := SFTypeUtils.passthrough_payload_error(data["signal"])
	if not signal_payload_error.is_empty():
		return _protocol_error(signal_payload_error, envelope)
	return _event(
		type_name,
		&"signal_received",
		[String(data["from"]), _string_or_empty(data.get("generation")), data["signal"]],
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
	var ready_players: Array = data["ready_players"]
	if (
		typeof(data["lobby_state"]) != TYPE_STRING
		or (
			SFTypesScript.lobby_state_from_string(data["lobby_state"])
			== SFTypesScript.LobbyState.UNKNOWN
		)
	):
		return _protocol_error("LobbyStateChanged lobby_state is unknown", envelope)
	if not _array_contains_only_strings(ready_players):
		return _protocol_error("LobbyStateChanged ready_players must be strings", envelope)
	return _event(
		type_name,
		&"lobby_state_changed",
		[
			SFTypesScript.lobby_state_from_string(data["lobby_state"]),
			_strings_from_array(ready_players),
			bool(data["all_ready"])
		],
		envelope
	)


static func _decode_reconnected(
	type_name: String, data: Dictionary, envelope: Dictionary, depth := 0
) -> RefCounted:
	if not data.has("missed_events") or typeof(data["missed_events"]) != TYPE_ARRAY:
		return _protocol_error("Reconnected requires missed_events", envelope)
	var missed_source: Array = data["missed_events"]
	var room_event := _decode_room_joined(type_name, data, envelope)
	if room_event.signal_name == &"protocol_error":
		return room_event
	var missed_events: Array = []
	var missed_count: int = missed_source.size()
	if missed_count > MAX_MISSED_EVENTS:
		missed_count = MAX_MISSED_EVENTS
	for index: int in missed_count:
		var missed: Variant = missed_source[index]
		if typeof(missed) != TYPE_DICTIONARY:
			missed_events.append(
				_protocol_error("Reconnected missed_events[%d] must be an object" % index, missed)
			)
			continue
		if _is_reconnected_envelope(missed):
			missed_events.append(
				_protocol_error(
					(
						(
							"Reconnected missed_events[%d]: Reconnected is not replayable inside"
							+ " missed_events"
						)
						% index
					),
					missed
				)
			)
			continue
		var decoded_missed := decode_envelope(missed, depth + 1)
		if decoded_missed.signal_name == &"protocol_error":
			missed_events.append(
				_protocol_error(
					"Reconnected missed_events[%d]: %s" % [index, decoded_missed.args[0]], missed
				)
			)
			continue
		missed_events.append(decoded_missed)
	if missed_source.size() > MAX_MISSED_EVENTS:
		missed_events.append(
			_protocol_error(
				(
					"Reconnected missed_events exceeds %d entries; dropped %d"
					% [MAX_MISSED_EVENTS, data["missed_events"].size() - MAX_MISSED_EVENTS]
				),
				envelope
			)
		)
	return _event(
		type_name,
		&"reconnected",
		[SFTypesScript.make_room_joined_info(data), missed_events],
		envelope
	)


static func _is_reconnected_envelope(envelope: Dictionary) -> bool:
	var type_value: Variant = envelope.get("type", null)
	return typeof(type_value) == TYPE_STRING and String(type_value) == "Reconnected"


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
	if String(data["error_code"]).is_empty():
		return "%s error_code must not be empty" % event_name
	return ""


static func _validate_optional_error_code(data: Dictionary, event_name: String) -> String:
	if not data.has("error_code") or data["error_code"] == null:
		return ""
	if typeof(data["error_code"]) != TYPE_STRING:
		return "%s error_code must be a string" % event_name
	if String(data["error_code"]).is_empty():
		return "%s error_code must not be empty" % event_name
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
