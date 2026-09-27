class_name SFTypes
extends RefCounted

enum GameDataEncoding { UNKNOWN = -1, JSON, MESSAGE_PACK, RKYV }
enum LobbyState { UNKNOWN = -1, WAITING, LOBBY, FINALIZED }
enum RelayTransport { UNKNOWN = -1, TCP, UDP, WEBSOCKET, AUTO }
enum SpectatorReason { UNKNOWN = -1, JOINED, VOLUNTARY_LEAVE, DISCONNECTED, REMOVED, ROOM_CLOSED }
## Completeness of `Reconnected.missed_events` (v3 only; the `replay` wire key
## is absent on v2, which decodes as UNKNOWN — no replay contract was stated).
enum ReplayStatus { UNKNOWN = -1, COMPLETE, TRUNCATED, UNAVAILABLE }

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const TypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SessionTypes = preload("res://addons/signal_fish/protocol/sf_session_types.gd")

const U8_MAX := 255
const U16_MAX := 65535
const U32_MAX := 4294967295
## Wire integers above the platform int range must be rejected, not collapsed:
## int(1e30) is platform-dependent (issue #73).
const I64_MAX := 9223372036854775807

const CONNECTION_INFO_OUTBOUND_NULL_FIELDS := [
	"host",
	"port",
	"transport",
	"allocation_id",
	"connection_data",
	"key",
	"token",
	"client_id",
	"sdp",
	"ice_candidates",
]

const GAME_DATA_ENCODING_TO_STRING: Dictionary = {
	GameDataEncoding.JSON: "json",
	GameDataEncoding.MESSAGE_PACK: "message_pack",
	GameDataEncoding.RKYV: "rkyv",
}
const GAME_DATA_ENCODING_FROM_STRING: Dictionary = {
	"json": GameDataEncoding.JSON,
	"message_pack": GameDataEncoding.MESSAGE_PACK,
	"rkyv": GameDataEncoding.RKYV,
}
const LOBBY_STATE_TO_STRING: Dictionary = {
	LobbyState.WAITING: "waiting",
	LobbyState.LOBBY: "lobby",
	LobbyState.FINALIZED: "finalized",
}
const LOBBY_STATE_FROM_STRING: Dictionary = {
	"waiting": LobbyState.WAITING,
	"lobby": LobbyState.LOBBY,
	"finalized": LobbyState.FINALIZED,
}
const REPLAY_STATUS_FROM_STRING: Dictionary = {
	"complete": ReplayStatus.COMPLETE,
	"truncated": ReplayStatus.TRUNCATED,
	"unavailable": ReplayStatus.UNAVAILABLE,
}
const RELAY_TRANSPORT_TO_STRING: Dictionary = {
	RelayTransport.TCP: "tcp",
	RelayTransport.UDP: "udp",
	RelayTransport.WEBSOCKET: "websocket",
	RelayTransport.AUTO: "auto",
}
const RELAY_TRANSPORT_FROM_STRING: Dictionary = {
	"tcp": RelayTransport.TCP,
	"udp": RelayTransport.UDP,
	"websocket": RelayTransport.WEBSOCKET,
	"auto": RelayTransport.AUTO,
}
## Server message transports (upstream `MessageTransport` enum; currently
## websocket only). Strictly validated wherever the wire carries the list.
const MESSAGE_TRANSPORT_FROM_STRING: Dictionary = {
	"websocket": true,
}
const SPECTATOR_REASON_TO_STRING: Dictionary = {
	SpectatorReason.JOINED: "joined",
	SpectatorReason.VOLUNTARY_LEAVE: "voluntary_leave",
	SpectatorReason.DISCONNECTED: "disconnected",
	SpectatorReason.REMOVED: "removed",
	SpectatorReason.ROOM_CLOSED: "room_closed",
}
const SPECTATOR_REASON_FROM_STRING: Dictionary = {
	"joined": SpectatorReason.JOINED,
	"voluntary_leave": SpectatorReason.VOLUNTARY_LEAVE,
	"disconnected": SpectatorReason.DISCONNECTED,
	"removed": SpectatorReason.REMOVED,
	"room_closed": SpectatorReason.ROOM_CLOSED,
}


class RateLimitInfo:
	extends RefCounted
	var per_minute: int = 0
	var per_hour: int = 0
	var per_day: int = 0
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		per_minute = TypeUtils.int_or_zero(data.get("per_minute"))
		per_hour = TypeUtils.int_or_zero(data.get("per_hour"))
		per_day = TypeUtils.int_or_zero(data.get("per_day"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


class PlayerNameRules:
	extends RefCounted
	var max_length: int = 0
	var min_length: int = 0
	var allow_unicode_alphanumeric: bool = false
	var allow_spaces: bool = false
	var allow_leading_trailing_whitespace: bool = false
	var allowed_symbols: PackedStringArray = PackedStringArray()
	var additional_allowed_characters: String = ""
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		max_length = TypeUtils.int_or_zero(data.get("max_length"))
		min_length = TypeUtils.int_or_zero(data.get("min_length"))
		allow_unicode_alphanumeric = TypeUtils.bool_or_false(data.get("allow_unicode_alphanumeric"))
		allow_spaces = TypeUtils.bool_or_false(data.get("allow_spaces"))
		allow_leading_trailing_whitespace = TypeUtils.bool_or_false(
			data.get("allow_leading_trailing_whitespace")
		)
		allowed_symbols = TypeUtils.coerce_string_array(data.get("allowed_symbols", []))
		additional_allowed_characters = TypeUtils.string_or_empty(
			data.get("additional_allowed_characters", "")
		)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


class ProtocolInfo:
	extends RefCounted
	var platform: String = ""
	var sdk_version: String = ""
	var minimum_version: String = ""
	var recommended_version: String = ""
	var capabilities: PackedStringArray = PackedStringArray()
	var notes: String = ""
	var game_data_formats: Array[int] = []
	var player_name_rules: PlayerNameRules = null
	## Negotiated protocol version (v3+ only; 0 = absent on negotiated v2).
	var protocol_version: int = 0
	## Lowest accepted protocol version (v3+ only; 0 = absent).
	var min_protocol_version: int = 0
	## Highest spoken protocol version (v3+ only; 0 = absent).
	var max_protocol_version: int = 0
	## Server message transports available to this connection (v3 only).
	var transports: PackedStringArray = PackedStringArray()
	## Maximum complete encoded outbound payload in bytes (v3+ only; 0 = absent).
	var max_outbound_message_size: int = 0
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		platform = TypeUtils.string_or_empty(data.get("platform"))
		sdk_version = TypeUtils.string_or_empty(data.get("sdk_version"))
		minimum_version = TypeUtils.string_or_empty(data.get("minimum_version"))
		recommended_version = TypeUtils.string_or_empty(data.get("recommended_version"))
		capabilities = TypeUtils.coerce_string_array(data.get("capabilities", []))
		notes = TypeUtils.string_or_empty(data.get("notes"))
		game_data_formats = _coerce_game_data_encodings(data.get("game_data_formats", []))
		var rules_value: Variant = data.get("player_name_rules")
		if rules_value is Dictionary:
			var rules: Dictionary = rules_value
			player_name_rules = PlayerNameRules.new(rules)
		protocol_version = TypeUtils.int_or_zero(data.get("protocol_version"))
		min_protocol_version = TypeUtils.int_or_zero(data.get("min_protocol_version"))
		max_protocol_version = TypeUtils.int_or_zero(data.get("max_protocol_version"))
		transports = TypeUtils.coerce_string_array(data.get("transports", []))
		max_outbound_message_size = TypeUtils.int_or_zero(data.get("max_outbound_message_size"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_game_data_encodings(values: Variant) -> Array[int]:
		var result: Array[int] = []
		if not values is Array:
			return result
		for value: Variant in values:
			if value is String:
				result.append(
					TypeUtils.enum_value(
						GAME_DATA_ENCODING_FROM_STRING, value, GameDataEncoding.UNKNOWN
					)
				)
		return result


class ConnectionInfo:
	extends RefCounted
	var type: String = ""
	var host: String = ""
	var port: int = 0
	var transport: int = RelayTransport.UNKNOWN
	var allocation_id: String = ""
	var connection_data: String = ""
	var key: String = ""
	var token: String = ""
	var client_id: int = -1
	var sdp: String = ""
	var ice_candidates: PackedStringArray = PackedStringArray()
	var data: Variant = null
	var raw: Dictionary = {}

	func _init(input: Dictionary = {}) -> void:
		raw = input.duplicate(true)
		type = TypeUtils.string_or_empty(input.get("type"))
		host = TypeUtils.string_or_empty(input.get("host"))
		# A present-null port must read like an absent one: `int(null)` raises
		# and would abort the constructor, silently defaulting every field
		# assigned after it (issue #81). An out-of-i64-range magnitude must
		# not collapse into a platform-dependent value (issue #96).
		port = TypeUtils.int_or_zero(input.get("port"))
		if type == "relay" and (not input.has("transport") or input["transport"] == null):
			transport = RelayTransport.AUTO
		else:
			transport = TypeUtils.enum_value(
				RELAY_TRANSPORT_FROM_STRING, input.get("transport", ""), RelayTransport.UNKNOWN
			)
		allocation_id = TypeUtils.string_or_empty(input.get("allocation_id"))
		connection_data = TypeUtils.string_or_empty(input.get("connection_data"))
		key = TypeUtils.string_or_empty(input.get("key"))
		token = TypeUtils.string_or_empty(input.get("token"))
		# A present-null client_id must read like an absent one, and a
		# non-integral value must not launder through int() truncation into a
		# different relay slot (issue #89) — same gate as `port` above
		# (issues #81/#96).
		var client_id_value: Variant = input.get("client_id")
		if TypeUtils.is_i64_integer(client_id_value):
			client_id = TypeUtils.int_or_zero(client_id_value)
		else:
			client_id = -1
		sdp = TypeUtils.string_or_empty(input.get("sdp"))
		ice_candidates = TypeUtils.coerce_string_array(input.get("ice_candidates", []))
		# `data` views this object's own snapshot (raw), never the caller's
		# tree: one object must not hold two divergent views (issue #73).
		data = raw.get("data")

	func to_dict() -> Dictionary:
		if type.is_empty():
			return raw.duplicate(true)
		var result: Dictionary = {"type": type}
		match type:
			"direct":
				result["host"] = host
				result["port"] = port
			"unity_relay":
				result["allocation_id"] = allocation_id
				result["connection_data"] = connection_data
				result["key"] = key
			"relay":
				result["host"] = host
				result["port"] = port
				result["allocation_id"] = allocation_id
				result["token"] = token
				if transport == RelayTransport.UNKNOWN:
					result.erase("transport")
				else:
					var transport_text: String = RELAY_TRANSPORT_TO_STRING.get(transport, "unknown")
					result["transport"] = transport_text
				if client_id >= 0:
					result["client_id"] = client_id
				else:
					result.erase("client_id")
			"webrtc":
				# Candidates round-trip raw-verbatim (issue #97): rebuilding
				# from the typed field would silently launder a shorter,
				# valid-looking array onto the documented resend path, while
				# the verbatim array lets the outbound validation refuse the
				# message loudly instead.
				var candidates: Variant = raw.get("ice_candidates")
				if candidates is Array:
					var candidate_array: Array = candidates
					result["ice_candidates"] = candidate_array.duplicate(true)
				else:
					result["ice_candidates"] = Array(ice_candidates)
				if sdp.is_empty() and (not raw.has("sdp") or raw["sdp"] == null):
					result.erase("sdp")
				else:
					result["sdp"] = sdp
			"custom":
				result["data"] = _copied_data(data)
			_:
				return raw.duplicate(true)
		_normalize_common_wire_fields(result)
		return result

	func _copied_data(value: Variant) -> Variant:
		if value is Dictionary:
			var dictionary: Dictionary = value
			return dictionary.duplicate(true)
		if value is Array:
			var array: Array = value
			return array.duplicate(true)
		return value

	func _normalize_common_wire_fields(result: Dictionary) -> void:
		for field: String in CONNECTION_INFO_OUTBOUND_NULL_FIELDS:
			if result.has(field) and result[field] == null:
				result.erase(field)
		if result.has("transport"):
			var transport_value := TypeUtils.enum_value(
				RELAY_TRANSPORT_FROM_STRING, result["transport"], RelayTransport.UNKNOWN
			)
			if transport_value == RelayTransport.UNKNOWN:
				result.erase("transport")
		for field: String in ["port", "client_id"]:
			if result.has(field) and TypeUtils.is_integral_number(result[field]):
				var numeric_value: Variant = result[field]
				if numeric_value is int:
					result[field] = numeric_value
				elif numeric_value is float:
					var number: float = numeric_value
					result[field] = int(number)


class PlayerInfo:
	extends RefCounted
	var id: String = ""
	var name: String = ""
	var is_authority: bool = false
	var is_ready: bool = false
	var connected_at: String = ""
	var connection_info: ConnectionInfo = null
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		id = TypeUtils.string_or_empty(data.get("id"))
		name = TypeUtils.string_or_empty(data.get("name"))
		is_authority = TypeUtils.bool_or_false(data.get("is_authority"))
		is_ready = TypeUtils.bool_or_false(data.get("is_ready"))
		connected_at = TypeUtils.string_or_empty(data.get("connected_at"))
		var connection_value: Variant = data.get("connection_info")
		if connection_value is Dictionary:
			var connection_data: Dictionary = connection_value
			connection_info = ConnectionInfo.new(connection_data)

	func to_dict() -> Dictionary:
		var result := raw.duplicate(true)
		if connection_info != null:
			result["connection_info"] = connection_info.to_dict()
		return result


class SpectatorInfo:
	extends RefCounted
	var id: String = ""
	var name: String = ""
	var connected_at: String = ""
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		id = TypeUtils.string_or_empty(data.get("id"))
		name = TypeUtils.string_or_empty(data.get("name"))
		connected_at = TypeUtils.string_or_empty(data.get("connected_at"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


class PeerConnectionInfo:
	extends RefCounted
	var player_id: String = ""
	var player_name: String = ""
	var is_authority: bool = false
	var relay_type: String = ""
	var connection_info: ConnectionInfo = null
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		player_id = TypeUtils.string_or_empty(data.get("player_id"))
		player_name = TypeUtils.string_or_empty(data.get("player_name"))
		is_authority = TypeUtils.bool_or_false(data.get("is_authority"))
		relay_type = TypeUtils.string_or_empty(data.get("relay_type"))
		var connection_value: Variant = data.get("connection_info")
		if connection_value is Dictionary:
			var connection_data: Dictionary = connection_value
			connection_info = ConnectionInfo.new(connection_data)

	func to_dict() -> Dictionary:
		var result := raw.duplicate(true)
		if connection_info != null:
			result["connection_info"] = connection_info.to_dict()
		return result


## A v3 reconnect baseline for one current room member's relayed game-data
## stream (upstream server messages.rs `SenderWatermark`: `player_id`, u32
## `epoch`, u64 `seq`). The reconnecting client never receives missed
## `GameData`; these watermarks are the `(epoch, seq)` tail per sender so a
## post-reconnect gap can be attributed to the client's absence or replay
## truncation instead of silent relay loss.
class SenderWatermark:
	extends RefCounted
	var player_id: String = ""
	var epoch: int = 0
	var seq: int = 0
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		player_id = data["player_id"] if _has_string(data, "player_id") else ""
		# Constructors cannot report errors: a hostile negative takes the 0
		# absent sentinel instead of reading as valid (issue #73 class).
		epoch = (
			TypeUtils.int_or_zero(data.get("epoch"))
			if _is_non_negative_integer(data.get("epoch"))
			else 0
		)
		seq = (
			TypeUtils.int_or_zero(data.get("seq"))
			if _is_non_negative_integer(data.get("seq"))
			else 0
		)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _has_string(data: Dictionary, key: String) -> bool:
		return typeof(data.get(key)) == TYPE_STRING

	func _is_non_negative_integer(value: Variant) -> bool:
		return TypeUtils.is_i64_integer(value) and value >= 0


class RoomJoinedInfo:
	extends RefCounted
	var room_id: String = ""
	var room_code: String = ""
	var player_id: String = ""
	var game_name: String = ""
	var max_players: int = 0
	var supports_authority: bool = false
	var current_players: Array[PlayerInfo] = []
	var is_authority: bool = false
	var lobby_state: int = LobbyState.UNKNOWN
	var ready_players: PackedStringArray = PackedStringArray()
	var relay_type: String = ""
	var current_spectators: Array[SpectatorInfo] = []
	## ICE (STUN/TURN) servers for early candidate gathering (v3 ICE
	## pre-gather, upstream `RoomJoinedPayload.ice_servers`). Empty for v2
	## connections; the latest SFSessionTypes.SessionPlanInfo list supersedes
	## this one (pre-gather TURN credentials may expire during a long lobby).
	var ice_servers: Array[SessionTypes.IceServerInfo] = []
	## Server-issued reconnection token (server messages.rs
	## `RoomJoinedPayload.reconnection_token` / `ReconnectedPayload.reconnection_token`).
	## Empty when the server omitted it or sent JSON null. Handle as a secret.
	var reconnection_token: String = ""
	## Completeness of `Reconnected.missed_events` (v3 only, upstream
	## `ReconnectedPayload.replay`). UNKNOWN when absent (v2 sessions) — no
	## replay contract was stated. TRUNCATED/UNAVAILABLE mean `missed_events`
	## is a suffix or empty: resync from the snapshot fields.
	var replay_status: int = ReplayStatus.UNKNOWN
	## Per-sender relayed game-data baseline (v3 only, upstream
	## `ReconnectedPayload.sender_watermarks`). Empty for v2 sessions.
	var sender_watermarks: Array[SenderWatermark] = []
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		room_id = TypeUtils.string_or_empty(data.get("room_id"))
		room_code = TypeUtils.string_or_empty(data.get("room_code"))
		player_id = TypeUtils.string_or_empty(data.get("player_id"))
		game_name = TypeUtils.string_or_empty(data.get("game_name"))
		max_players = TypeUtils.int_or_zero(data.get("max_players"))
		supports_authority = TypeUtils.bool_or_false(data.get("supports_authority"))
		current_players = _coerce_players(data.get("current_players", []))
		is_authority = TypeUtils.bool_or_false(data.get("is_authority"))
		lobby_state = TypeUtils.enum_value(
			LOBBY_STATE_FROM_STRING, data.get("lobby_state", ""), LobbyState.UNKNOWN
		)
		ready_players = TypeUtils.coerce_string_array(data.get("ready_players", []))
		relay_type = TypeUtils.string_or_empty(data.get("relay_type"))
		current_spectators = _coerce_spectators(data.get("current_spectators", []))
		ice_servers = _coerce_ice_servers(data.get("ice_servers", []))
		reconnection_token = TypeUtils.string_or_empty(data.get("reconnection_token"))
		replay_status = TypeUtils.enum_value(
			REPLAY_STATUS_FROM_STRING, data.get("replay"), ReplayStatus.UNKNOWN
		)
		sender_watermarks = _coerce_watermarks(data.get("sender_watermarks", []))

	func to_dict() -> Dictionary:
		var result := raw.duplicate(true)
		result["current_players"] = TypeUtils.roster_to_dicts(
			raw, "current_players", current_players
		)
		if current_spectators.size() > 0 or raw.has("current_spectators"):
			result["current_spectators"] = TypeUtils.roster_to_dicts(
				raw, "current_spectators", current_spectators
			)
		return result

	func _coerce_players(values: Variant) -> Array[PlayerInfo]:
		var result: Array[PlayerInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(PlayerInfo.new(entry))
		return result

	func _coerce_ice_servers(values: Variant) -> Array[SessionTypes.IceServerInfo]:
		var result: Array[SessionTypes.IceServerInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(SessionTypes.IceServerInfo.new(entry))
		return result

	func _coerce_spectators(values: Variant) -> Array[SpectatorInfo]:
		var result: Array[SpectatorInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(SpectatorInfo.new(entry))
		return result

	func _coerce_watermarks(values: Variant) -> Array[SenderWatermark]:
		var result: Array[SenderWatermark] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(SenderWatermark.new(entry))
		return result


class SpectatorJoinedInfo:
	extends RefCounted
	var room_id: String = ""
	var room_code: String = ""
	var spectator_id: String = ""
	var game_name: String = ""
	var current_players: Array[PlayerInfo] = []
	var current_spectators: Array[SpectatorInfo] = []
	var lobby_state: int = LobbyState.UNKNOWN
	var reason: int = SpectatorReason.UNKNOWN
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		room_id = TypeUtils.string_or_empty(data.get("room_id"))
		room_code = TypeUtils.string_or_empty(data.get("room_code"))
		spectator_id = TypeUtils.string_or_empty(data.get("spectator_id"))
		game_name = TypeUtils.string_or_empty(data.get("game_name"))
		current_players = _coerce_players(data.get("current_players", []))
		current_spectators = _coerce_spectators(data.get("current_spectators", []))
		lobby_state = TypeUtils.enum_value(
			LOBBY_STATE_FROM_STRING, data.get("lobby_state", ""), LobbyState.UNKNOWN
		)
		reason = _coerce_spectator_reason(data.get("reason", ""))

	func to_dict() -> Dictionary:
		var result := raw.duplicate(true)
		result["current_players"] = TypeUtils.roster_to_dicts(
			raw, "current_players", current_players
		)
		result["current_spectators"] = TypeUtils.roster_to_dicts(
			raw, "current_spectators", current_spectators
		)
		return result

	func _coerce_players(values: Variant) -> Array[PlayerInfo]:
		var result: Array[PlayerInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(PlayerInfo.new(entry))
		return result

	func _coerce_spectators(values: Variant) -> Array[SpectatorInfo]:
		var result: Array[SpectatorInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(SpectatorInfo.new(entry))
		return result

	func _coerce_spectator_reason(value: Variant) -> int:
		return TypeUtils.enum_value(SPECTATOR_REASON_FROM_STRING, value, SpectatorReason.UNKNOWN)


class DecodedEvent:
	extends RefCounted
	var type_name: String = ""
	var signal_name: StringName = &""
	var args: Array = []
	## Read-only view aliasing the freshly parsed wire envelope (issue #48):
	## the client never mutates decode output, and all decode output from one
	## envelope shares its tree (e.g. a missed_events entry's raw is visible
	## through the parent event's raw). Use [code]to_dict()[/code] for an
	## independent mutable copy.
	var raw: Dictionary = {}

	func _init(
		p_type_name: String = "",
		p_signal_name: StringName = &"",
		p_args: Array = [],
		p_raw: Dictionary = {}
	) -> void:
		type_name = p_type_name
		signal_name = p_signal_name
		args = p_args
		raw = p_raw


static func game_data_encoding_from_string(value: Variant) -> int:
	return TypeUtils.enum_value(GAME_DATA_ENCODING_FROM_STRING, value, GameDataEncoding.UNKNOWN)


static func game_data_encoding_to_string(value: int) -> String:
	var text: String = GAME_DATA_ENCODING_TO_STRING.get(value, "unknown")
	return text


static func lobby_state_from_string(value: Variant) -> int:
	return TypeUtils.enum_value(LOBBY_STATE_FROM_STRING, value, LobbyState.UNKNOWN)


static func lobby_state_to_string(value: int) -> String:
	var text: String = LOBBY_STATE_TO_STRING.get(value, "unknown")
	return text


static func relay_transport_from_string(value: Variant) -> int:
	return TypeUtils.enum_value(RELAY_TRANSPORT_FROM_STRING, value, RelayTransport.UNKNOWN)


static func relay_transport_to_string(value: int) -> String:
	var text: String = RELAY_TRANSPORT_TO_STRING.get(value, "unknown")
	return text


static func spectator_reason_from_string(value: Variant) -> int:
	return TypeUtils.enum_value(SPECTATOR_REASON_FROM_STRING, value, SpectatorReason.UNKNOWN)


static func spectator_reason_to_string(value: int) -> String:
	var text: String = SPECTATOR_REASON_TO_STRING.get(value, "unknown")
	return text


static func error_code_from_variant(value: Variant) -> int:
	return SFErrorCodesScript.from_string(value)


static func validate_optional_spectator_reason(
	data: Dictionary, key: String, context: String
) -> String:
	if not data.has(key) or data[key] == null:
		return ""
	var reason_value: Variant = data[key]
	if not reason_value is String:
		return "%s %s must be a string" % [context, key]
	var reason: String = reason_value
	if reason.is_empty():
		return "%s %s must not be empty" % [context, key]
	return ""


static func validate_rate_limit_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "rate_limits must be an object"
	var dict: Dictionary = data
	for key: String in ["per_minute", "per_hour", "per_day"]:
		if not _has_integer_in_range(dict, key, 0, U32_MAX):
			return "rate_limits requires u32 %s" % key
	return ""


static func validate_protocol_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "ProtocolInfo data must be an object"
	var dict: Dictionary = data
	for key: String in [
		"platform", "sdk_version", "minimum_version", "recommended_version", "notes"
	]:
		if dict.has(key) and dict[key] != null and typeof(dict[key]) != TYPE_STRING:
			return "ProtocolInfo %s must be a string" % key
	if dict.has("capabilities") and not _is_string_array_value(dict["capabilities"]):
		return "ProtocolInfo capabilities must be a string array"
	if dict.has("game_data_formats"):
		if typeof(dict["game_data_formats"]) != TYPE_ARRAY:
			return "ProtocolInfo game_data_formats must be an array"
		for value: Variant in dict["game_data_formats"]:
			if not value is String:
				return "ProtocolInfo game_data_formats must contain strings"
			var encoding: String = value
			if encoding.is_empty():
				return "ProtocolInfo game_data_formats must not contain empty strings"
	if dict.has("player_name_rules") and dict["player_name_rules"] != null:
		var error := validate_player_name_rules(dict["player_name_rules"])
		if not error.is_empty():
			return error
	for key: String in ["protocol_version", "min_protocol_version", "max_protocol_version"]:
		if dict.has(key) and dict[key] != null:
			if not _is_integer_value_in_range(dict[key], 0, U16_MAX):
				return "ProtocolInfo %s must be u16" % key
	if dict.has("max_outbound_message_size") and dict["max_outbound_message_size"] != null:
		if not _is_i64_integer(dict["max_outbound_message_size"]):
			return "ProtocolInfo max_outbound_message_size must be a non-negative integer"
	if dict.has("transports") and dict["transports"] != null:
		if not _is_string_array_value(dict["transports"]):
			return "ProtocolInfo transports must be a string array"
		for token: Variant in dict["transports"]:
			var transport: String = token
			if not MESSAGE_TRANSPORT_FROM_STRING.has(transport):
				return "ProtocolInfo transports contains an unknown token"
	return ""


static func validate_player_name_rules(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "player_name_rules must be an object"
	var dict: Dictionary = data
	for key: String in ["max_length", "min_length"]:
		# Strict i64 representability (issue #73 policy): a present-as-float
		# value at or above 2^63 is hostile, never a real length cap —
		# int() would collapse it platform-dependently.
		if not _has_i64_integer(dict, key):
			return "player_name_rules requires nonnegative integer %s" % key
	for key: String in [
		"allow_unicode_alphanumeric", "allow_spaces", "allow_leading_trailing_whitespace"
	]:
		if not _has_bool(dict, key):
			return "player_name_rules requires bool %s" % key
	if dict.has("allowed_symbols"):
		if not _is_string_array_value(dict["allowed_symbols"]):
			return "player_name_rules allowed_symbols must be a string array"
	if (
		dict.has("additional_allowed_characters")
		and dict["additional_allowed_characters"] != null
		and typeof(dict["additional_allowed_characters"]) != TYPE_STRING
	):
		return "player_name_rules additional_allowed_characters must be a string"
	return ""


static func validate_player_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "PlayerInfo must be an object"
	var dict: Dictionary = data
	if not _has_id(dict, "id"):
		return "PlayerInfo requires lowercase hyphenated UUID id"
	for key: String in ["name"]:
		if not _has_string(dict, key):
			return "PlayerInfo requires string %s" % key
	# connected_at is optional: protocol-v3 room snapshots trim it for
	# privacy (upstream serde(default); signal-fish-server #539). Absent or
	# null decodes to the "" sentinel; a present value must be a string.
	if not _is_optional_string(dict, "connected_at"):
		return "PlayerInfo connected_at must be a string"
	for key: String in ["is_authority", "is_ready"]:
		if not _has_bool(dict, key):
			return "PlayerInfo requires bool %s" % key
	if dict.has("connection_info") and dict["connection_info"] != null:
		var error := validate_connection_info(dict["connection_info"])
		if not error.is_empty():
			return "PlayerInfo connection_info: %s" % error
	return ""


static func validate_spectator_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SpectatorInfo must be an object"
	var dict: Dictionary = data
	if not _has_id(dict, "id"):
		return "SpectatorInfo requires lowercase hyphenated UUID id"
	for key: String in ["name"]:
		if not _has_string(dict, key):
			return "SpectatorInfo requires string %s" % key
	if not _is_optional_string(dict, "connected_at"):
		return "SpectatorInfo connected_at must be a string"
	return ""


static func validate_peer_connection_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "PeerConnectionInfo must be an object"
	var dict: Dictionary = data
	if not _has_id(dict, "player_id"):
		return "PeerConnectionInfo requires lowercase hyphenated UUID player_id"
	for key: String in ["player_name", "relay_type"]:
		if not _has_string(dict, key):
			return "PeerConnectionInfo requires string %s" % key
	if not _has_bool(dict, "is_authority"):
		return "PeerConnectionInfo requires bool is_authority"
	if dict.has("connection_info") and dict["connection_info"] != null:
		var error := validate_connection_info(dict["connection_info"])
		if not error.is_empty():
			return "PeerConnectionInfo connection_info: %s" % error
	return ""


static func validate_room_joined_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "RoomJoinedInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["room_id", "player_id"]:
		if not _has_id(dict, key):
			return "RoomJoinedInfo requires lowercase hyphenated UUID %s" % key
	for key: String in ["room_code", "game_name", "relay_type"]:
		if not _has_string(dict, key):
			return "RoomJoinedInfo requires string %s" % key
	if not _has_integer_in_range(dict, "max_players", 0, U8_MAX):
		return "RoomJoinedInfo requires u8 max_players"
	for key: String in ["supports_authority", "is_authority"]:
		if not _has_bool(dict, key):
			return "RoomJoinedInfo requires bool %s" % key
	if not _has_known_lobby_state(dict, "lobby_state"):
		return "RoomJoinedInfo lobby_state is unknown"
	var players_error := validate_players_array(dict.get("current_players"))
	if not players_error.is_empty():
		return "RoomJoinedInfo current_players: %s" % players_error
	# ready_players carries upstream PlayerId UUIDs: entries must be
	# canonical UUID text (issues #149/#151).
	if not _has_uuid_string_array(dict, "ready_players"):
		return "RoomJoinedInfo requires lowercase hyphenated UUID array ready_players"
	# Server-issued on RoomJoined/Reconnected baselines; the client echoes it
	# back on Reconnect, so a present value must be a string (issue #72).
	if not _is_optional_string(dict, "reconnection_token"):
		return "RoomJoinedInfo reconnection_token must be a string"
	# v3-only Reconnected additions: optional upstream (`Option` / serde
	# default), so absent or null stays legal, but a present value must match
	# the wire shape (issue #114).
	if not _is_optional_replay_status(dict):
		return "RoomJoinedInfo replay is unknown"
	if not _is_optional_watermarks_array(dict):
		return "RoomJoinedInfo sender_watermarks must be lowercase hyphenated UUID watermarks"
	if dict.has("current_spectators"):
		var spectators_error := validate_spectators_array(dict["current_spectators"])
		if not spectators_error.is_empty():
			return "RoomJoinedInfo current_spectators: %s" % spectators_error
	if dict.has("ice_servers") and dict["ice_servers"] != null:
		var ice_error := SessionTypes.validate_ice_servers_array(dict["ice_servers"])
		if not ice_error.is_empty():
			return "RoomJoinedInfo ice_servers: %s" % ice_error
	return ""


static func validate_spectator_joined_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SpectatorJoinedInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["room_id", "spectator_id"]:
		if not _has_id(dict, key):
			return "SpectatorJoinedInfo requires lowercase hyphenated UUID %s" % key
	for key: String in ["room_code", "game_name"]:
		if not _has_string(dict, key):
			return "SpectatorJoinedInfo requires string %s" % key
	var players_error := validate_players_array(dict.get("current_players"))
	if not players_error.is_empty():
		return "SpectatorJoinedInfo current_players: %s" % players_error
	var spectators_error := validate_spectators_array(dict.get("current_spectators"))
	if not spectators_error.is_empty():
		return "SpectatorJoinedInfo current_spectators: %s" % spectators_error
	if not _has_known_lobby_state(dict, "lobby_state"):
		return "SpectatorJoinedInfo lobby_state is unknown"
	var reason_error := validate_optional_spectator_reason(dict, "reason", "SpectatorJoinedInfo")
	if not reason_error.is_empty():
		return reason_error
	return ""


static func validate_players_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for index: int in array.size():
		var value: Variant = array[index]
		var error := validate_player_info(value)
		if not error.is_empty():
			return "[%d] %s" % [index, error]
	return ""


static func validate_spectators_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for index: int in array.size():
		var value: Variant = array[index]
		var error := validate_spectator_info(value)
		if not error.is_empty():
			return "[%d] %s" % [index, error]
	return ""


static func validate_peer_connections_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for index: int in array.size():
		var value: Variant = array[index]
		var error := validate_peer_connection_info(value)
		if not error.is_empty():
			return "[%d] %s" % [index, error]
	return ""


static func validate_connection_info(data: Variant, allow_unknown_strings: bool = true) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "connection_info must be an object"
	var dict: Dictionary = data
	if not _has_string(dict, "type"):
		return "connection_info requires string type"
	var connection_type: String = dict["type"]
	if connection_type.is_empty():
		return "connection_info type must not be empty"
	match connection_type:
		"direct":
			var direct_error := _require_connection_info_fields(
				dict, "direct", PackedStringArray(["host", "port"])
			)
			if not direct_error.is_empty():
				return direct_error
		"unity_relay":
			var unity_relay_error := _require_connection_info_fields(
				dict, "unity_relay", PackedStringArray(["allocation_id", "connection_data", "key"])
			)
			if not unity_relay_error.is_empty():
				return unity_relay_error
		"relay":
			var relay_error := _require_connection_info_fields(
				dict, "relay", PackedStringArray(["host", "port", "allocation_id", "token"])
			)
			if not relay_error.is_empty():
				return relay_error
		"webrtc":
			if dict.has("sdp") and dict["sdp"] != null and typeof(dict["sdp"]) != TYPE_STRING:
				return "webrtc connection_info sdp must be a string"
			var webrtc_error := _require_connection_info_fields(
				dict, "webrtc", PackedStringArray(["ice_candidates"])
			)
			if not webrtc_error.is_empty():
				return webrtc_error
		"custom":
			if not dict.has("data"):
				return "custom connection_info requires data"
		_:
			if not allow_unknown_strings:
				return "connection_info type is unknown"
	return _validate_common_connection_info_fields(dict, allow_unknown_strings)


static func validate_outbound_connection_info(data: Variant) -> String:
	var error := validate_connection_info(data, false)
	if not error.is_empty():
		return error
	var dict: Dictionary = data
	for key: String in CONNECTION_INFO_OUTBOUND_NULL_FIELDS:
		if dict.has(key) and dict[key] == null:
			return "connection_info %s must not be null" % key
	for key: String in ["port", "client_id"]:
		if dict.has(key) and typeof(dict[key]) != TYPE_INT:
			return "connection_info %s must be an integer" % key
	return ""


static func _validate_common_connection_info_fields(
	dict: Dictionary, allow_unknown_strings: bool
) -> String:
	if dict.has("host") and dict["host"] != null and typeof(dict["host"]) != TYPE_STRING:
		return "connection_info host must be a string"
	if (
		dict.has("port")
		and dict["port"] != null
		and not _is_integer_value_in_range(dict["port"], 0, U16_MAX)
	):
		return "connection_info port must be u16"
	if dict.has("transport"):
		var transport_value: Variant = dict["transport"]
		if (
			transport_value != null
			and (
				not transport_value is String
				or TypeUtils.string_or_empty(transport_value).is_empty()
			)
		):
			return "connection_info transport must be a non-empty string"
		if (
			dict["transport"] != null
			and not allow_unknown_strings
			and relay_transport_from_string(dict["transport"]) == RelayTransport.UNKNOWN
		):
			return "connection_info transport is unknown"
	for key: String in ["allocation_id", "connection_data", "key", "token"]:
		if dict.has(key) and dict[key] != null and typeof(dict[key]) != TYPE_STRING:
			return "connection_info %s must be a string" % key
	if (
		dict.has("client_id")
		and dict["client_id"] != null
		and not _is_integer_value_in_range(dict["client_id"], 0, U16_MAX)
	):
		return "connection_info client_id must be u16"
	if dict.has("sdp") and dict["sdp"] != null and typeof(dict["sdp"]) != TYPE_STRING:
		return "connection_info sdp must be a string"
	if dict.has("ice_candidates") and not _is_string_array_value(dict["ice_candidates"]):
		return "connection_info ice_candidates must be a string array"
	return ""


static func _require_connection_info_fields(
	dict: Dictionary, type_name: String, required_keys: PackedStringArray
) -> String:
	for key: String in required_keys:
		if not dict.has(key) or dict[key] == null:
			return "%s connection_info requires %s" % [type_name, key]
	return ""


static func make_rate_limit_info(data: Dictionary) -> RateLimitInfo:
	return RateLimitInfo.new(data)


static func make_protocol_info(data: Dictionary) -> ProtocolInfo:
	return ProtocolInfo.new(data)


static func make_player_info(data: Dictionary) -> PlayerInfo:
	return PlayerInfo.new(data)


static func make_spectator_info(data: Dictionary) -> SpectatorInfo:
	return SpectatorInfo.new(data)


static func make_room_joined_info(data: Dictionary) -> RoomJoinedInfo:
	return RoomJoinedInfo.new(data)


static func make_spectator_joined_info(data: Dictionary) -> SpectatorJoinedInfo:
	return SpectatorJoinedInfo.new(data)


static func make_decoded_event(
	type_name: String, signal_name: StringName, args: Array, raw: Dictionary
) -> DecodedEvent:
	return DecodedEvent.new(type_name, signal_name, args, raw)


static func players_from_array(values: Variant) -> Array[PlayerInfo]:
	var result: Array[PlayerInfo] = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if value is Dictionary:
			var entry: Dictionary = value
			result.append(PlayerInfo.new(entry))
	return result


static func spectators_from_array(values: Variant) -> Array[SpectatorInfo]:
	var result: Array[SpectatorInfo] = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if value is Dictionary:
			var entry: Dictionary = value
			result.append(SpectatorInfo.new(entry))
	return result


static func peer_connections_from_array(values: Variant) -> Array[PeerConnectionInfo]:
	var result: Array[PeerConnectionInfo] = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if value is Dictionary:
			var entry: Dictionary = value
			result.append(PeerConnectionInfo.new(entry))
	return result


static func objects_to_dicts(values: Array) -> Array:
	return TypeUtils.objects_to_dicts(values)


static func game_data_encodings_from_array(values: Variant) -> Array[int]:
	var result: Array[int] = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		result.append(game_data_encoding_from_string(value))
	return result


static func _has_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING


static func _has_id(data: Dictionary, key: String) -> bool:
	return TypeUtils.is_canonical_uuid_text(data.get(key))


static func _has_bool(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_BOOL


static func _has_i64_integer(data: Dictionary, key: String) -> bool:
	return data.has(key) and _is_i64_integer(data[key])


static func _has_integer_in_range(
	data: Dictionary, key: String, min_value: int, max_value: int
) -> bool:
	return data.has(key) and _is_integer_value_in_range(data[key], min_value, max_value)


static func _has_uuid_string_array(data: Dictionary, key: String) -> bool:
	if not data.has(key) or not _is_string_array_value(data[key]):
		return false
	for value: Variant in data[key]:
		if not TypeUtils.is_canonical_uuid_text(value):
			return false
	return true


static func _is_optional_string(data: Dictionary, key: String) -> bool:
	if not data.has(key) or data[key] == null:
		return true
	return typeof(data[key]) == TYPE_STRING


static func _is_optional_replay_status(data: Dictionary) -> bool:
	if not data.has("replay") or data["replay"] == null:
		return true
	var replay_value: Variant = data["replay"]
	if not replay_value is String:
		return false
	var replay: String = replay_value
	return REPLAY_STATUS_FROM_STRING.has(replay)


static func _is_optional_watermarks_array(data: Dictionary) -> bool:
	if not data.has("sender_watermarks") or data["sender_watermarks"] == null:
		return true
	if typeof(data["sender_watermarks"]) != TYPE_ARRAY:
		return false
	for watermark: Variant in data["sender_watermarks"]:
		if not watermark is Dictionary:
			return false
		var entry: Dictionary = watermark
		if not _has_id(entry, "player_id"):
			return false
		if not _has_integer_in_range(entry, "epoch", 0, U32_MAX):
			return false
		if not _has_i64_integer(entry, "seq"):
			return false
	return true


static func _is_i64_integer(value: Variant) -> bool:
	if value is int:
		var integer: int = value
		return integer >= 0
	if not value is float or not TypeUtils.is_integral_number(value):
		return false
	var number: float = value
	return number >= 0.0 and number < 9223372036854775808.0


static func _has_known_lobby_state(data: Dictionary, key: String) -> bool:
	return _has_string(data, key) and lobby_state_from_string(data[key]) != LobbyState.UNKNOWN


static func _is_integer_value_at_least(value: Variant, min_value: int) -> bool:
	if not TypeUtils.is_integral_number(value):
		return false
	var number: float = value
	return number >= float(min_value)


static func _is_integer_value_in_range(value: Variant, min_value: int, max_value: int) -> bool:
	if not _is_integer_value_at_least(value, min_value):
		return false
	var number: float = value
	return number <= float(max_value)


static func _is_string_array_value(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	for entry: Variant in value:
		if typeof(entry) != TYPE_STRING:
			return false
	return true
