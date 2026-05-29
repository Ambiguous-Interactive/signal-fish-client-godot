class_name SFTypes
extends RefCounted

enum GameDataEncoding { UNKNOWN = -1, JSON, MESSAGE_PACK, RKYV }
enum LobbyState { UNKNOWN = -1, WAITING, LOBBY, FINALIZED }
enum RelayTransport { UNKNOWN = -1, TCP, UDP, WEBSOCKET, AUTO }
enum SpectatorReason { UNKNOWN = -1, JOINED, VOLUNTARY_LEAVE, DISCONNECTED, REMOVED, ROOM_CLOSED }

const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")

const U8_MAX := 255
const U16_MAX := 65535
const U32_MAX := 4294967295

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
		raw = data.duplicate(true)
		per_minute = int(data.get("per_minute", 0))
		per_hour = int(data.get("per_hour", 0))
		per_day = int(data.get("per_day", 0))

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
		raw = data.duplicate(true)
		max_length = int(data.get("max_length", 0))
		min_length = int(data.get("min_length", 0))
		allow_unicode_alphanumeric = bool(data.get("allow_unicode_alphanumeric", false))
		allow_spaces = bool(data.get("allow_spaces", false))
		allow_leading_trailing_whitespace = bool(
			data.get("allow_leading_trailing_whitespace", false)
		)
		allowed_symbols = _coerce_strings(data.get("allowed_symbols", []))
		var additional_characters: Variant = data.get("additional_allowed_characters", "")
		additional_allowed_characters = (
			"" if additional_characters == null else String(additional_characters)
		)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_strings(values: Variant) -> PackedStringArray:
		var result := PackedStringArray()
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			result.append(String(value))
		return result


class ProtocolInfo:
	extends RefCounted
	var platform: String = ""
	var sdk_version: String = ""
	var minimum_version: String = ""
	var recommended_version: String = ""
	var capabilities: PackedStringArray = PackedStringArray()
	var notes: String = ""
	var game_data_formats: Array = []
	var player_name_rules: PlayerNameRules = null
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data.duplicate(true)
		platform = _string_or_empty(data.get("platform"))
		sdk_version = _string_or_empty(data.get("sdk_version"))
		minimum_version = _string_or_empty(data.get("minimum_version"))
		recommended_version = _string_or_empty(data.get("recommended_version"))
		capabilities = _coerce_strings(data.get("capabilities", []))
		notes = _string_or_empty(data.get("notes"))
		game_data_formats = _coerce_game_data_encodings(data.get("game_data_formats", []))
		if (
			data.has("player_name_rules")
			and typeof(data.get("player_name_rules")) == TYPE_DICTIONARY
		):
			player_name_rules = PlayerNameRules.new(data["player_name_rules"])

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_strings(values: Variant) -> PackedStringArray:
		var result := PackedStringArray()
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			result.append(String(value))
		return result

	func _coerce_game_data_encodings(values: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			match String(value):
				"json":
					result.append(GameDataEncoding.JSON)
				"message_pack":
					result.append(GameDataEncoding.MESSAGE_PACK)
				"rkyv":
					result.append(GameDataEncoding.RKYV)
				_:
					result.append(GameDataEncoding.UNKNOWN)
		return result

	func _string_or_empty(value: Variant) -> String:
		if value == null:
			return ""
		return String(value)


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
		type = _string_or_empty(input.get("type"))
		host = _string_or_empty(input.get("host"))
		port = int(input.get("port", 0))
		transport = _coerce_relay_transport(input.get("transport", ""))
		allocation_id = _string_or_empty(input.get("allocation_id"))
		connection_data = _string_or_empty(input.get("connection_data"))
		key = _string_or_empty(input.get("key"))
		token = _string_or_empty(input.get("token"))
		client_id = int(input.get("client_id", -1))
		sdp = _string_or_empty(input.get("sdp"))
		ice_candidates = _coerce_strings(input.get("ice_candidates", []))
		data = input.get("data")

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_relay_transport(value: Variant) -> int:
		if value == null:
			return RelayTransport.UNKNOWN
		match String(value):
			"tcp":
				return RelayTransport.TCP
			"udp":
				return RelayTransport.UDP
			"websocket":
				return RelayTransport.WEBSOCKET
			"auto":
				return RelayTransport.AUTO
			_:
				return RelayTransport.UNKNOWN

	func _coerce_strings(values: Variant) -> PackedStringArray:
		var result := PackedStringArray()
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			result.append(String(value))
		return result

	func _string_or_empty(value: Variant) -> String:
		if value == null:
			return ""
		return String(value)


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
		raw = data.duplicate(true)
		id = String(data.get("id", ""))
		name = String(data.get("name", ""))
		is_authority = bool(data.get("is_authority", false))
		is_ready = bool(data.get("is_ready", false))
		connected_at = String(data.get("connected_at", ""))
		if data.has("connection_info") and typeof(data.get("connection_info")) == TYPE_DICTIONARY:
			connection_info = ConnectionInfo.new(data["connection_info"])

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


class SpectatorInfo:
	extends RefCounted
	var id: String = ""
	var name: String = ""
	var connected_at: String = ""
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data.duplicate(true)
		id = String(data.get("id", ""))
		name = String(data.get("name", ""))
		connected_at = String(data.get("connected_at", ""))

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
		raw = data.duplicate(true)
		player_id = String(data.get("player_id", ""))
		player_name = String(data.get("player_name", ""))
		is_authority = bool(data.get("is_authority", false))
		relay_type = String(data.get("relay_type", ""))
		if data.has("connection_info") and typeof(data.get("connection_info")) == TYPE_DICTIONARY:
			connection_info = ConnectionInfo.new(data["connection_info"])

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


class RoomJoinedInfo:
	extends RefCounted
	var room_id: String = ""
	var room_code: String = ""
	var player_id: String = ""
	var game_name: String = ""
	var max_players: int = 0
	var supports_authority: bool = false
	var current_players: Array = []
	var is_authority: bool = false
	var lobby_state: int = LobbyState.UNKNOWN
	var ready_players: PackedStringArray = PackedStringArray()
	var relay_type: String = ""
	var current_spectators: Array = []
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data.duplicate(true)
		room_id = String(data.get("room_id", ""))
		room_code = String(data.get("room_code", ""))
		player_id = String(data.get("player_id", ""))
		game_name = String(data.get("game_name", ""))
		max_players = int(data.get("max_players", 0))
		supports_authority = bool(data.get("supports_authority", false))
		current_players = _coerce_players(data.get("current_players", []))
		is_authority = bool(data.get("is_authority", false))
		lobby_state = _coerce_lobby_state(data.get("lobby_state", ""))
		ready_players = _coerce_strings(data.get("ready_players", []))
		relay_type = String(data.get("relay_type", ""))
		current_spectators = _coerce_spectators(data.get("current_spectators", []))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_players(values: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if typeof(value) == TYPE_DICTIONARY:
				result.append(PlayerInfo.new(value))
		return result

	func _coerce_spectators(values: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if typeof(value) == TYPE_DICTIONARY:
				result.append(SpectatorInfo.new(value))
		return result

	func _coerce_strings(values: Variant) -> PackedStringArray:
		var result := PackedStringArray()
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			result.append(String(value))
		return result

	func _coerce_lobby_state(value: Variant) -> int:
		match String(value):
			"waiting":
				return LobbyState.WAITING
			"lobby":
				return LobbyState.LOBBY
			"finalized":
				return LobbyState.FINALIZED
			_:
				return LobbyState.UNKNOWN


class SpectatorJoinedInfo:
	extends RefCounted
	var room_id: String = ""
	var room_code: String = ""
	var spectator_id: String = ""
	var game_name: String = ""
	var current_players: Array = []
	var current_spectators: Array = []
	var lobby_state: int = LobbyState.UNKNOWN
	var reason: int = SpectatorReason.UNKNOWN
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data.duplicate(true)
		room_id = String(data.get("room_id", ""))
		room_code = String(data.get("room_code", ""))
		spectator_id = String(data.get("spectator_id", ""))
		game_name = String(data.get("game_name", ""))
		current_players = _coerce_players(data.get("current_players", []))
		current_spectators = _coerce_spectators(data.get("current_spectators", []))
		lobby_state = _coerce_lobby_state(data.get("lobby_state", ""))
		reason = _coerce_spectator_reason(data.get("reason", ""))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _coerce_players(values: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if typeof(value) == TYPE_DICTIONARY:
				result.append(PlayerInfo.new(value))
		return result

	func _coerce_spectators(values: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if typeof(value) == TYPE_DICTIONARY:
				result.append(SpectatorInfo.new(value))
		return result

	func _coerce_lobby_state(value: Variant) -> int:
		match String(value):
			"waiting":
				return LobbyState.WAITING
			"lobby":
				return LobbyState.LOBBY
			"finalized":
				return LobbyState.FINALIZED
			_:
				return LobbyState.UNKNOWN

	func _coerce_spectator_reason(value: Variant) -> int:
		match String(value):
			"joined":
				return SpectatorReason.JOINED
			"voluntary_leave":
				return SpectatorReason.VOLUNTARY_LEAVE
			"disconnected":
				return SpectatorReason.DISCONNECTED
			"removed":
				return SpectatorReason.REMOVED
			"room_closed":
				return SpectatorReason.ROOM_CLOSED
			_:
				return SpectatorReason.UNKNOWN


class DecodedEvent:
	extends RefCounted
	var type_name: String = ""
	var signal_name: StringName = &""
	var args: Array = []
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
		raw = p_raw.duplicate(true)


static func game_data_encoding_from_string(value: Variant) -> int:
	return int(GAME_DATA_ENCODING_FROM_STRING.get(String(value), GameDataEncoding.UNKNOWN))


static func game_data_encoding_to_string(value: int) -> String:
	return String(GAME_DATA_ENCODING_TO_STRING.get(value, "unknown"))


static func lobby_state_from_string(value: Variant) -> int:
	return int(LOBBY_STATE_FROM_STRING.get(String(value), LobbyState.UNKNOWN))


static func lobby_state_to_string(value: int) -> String:
	return String(LOBBY_STATE_TO_STRING.get(value, "unknown"))


static func relay_transport_from_string(value: Variant) -> int:
	return int(RELAY_TRANSPORT_FROM_STRING.get(String(value), RelayTransport.UNKNOWN))


static func relay_transport_to_string(value: int) -> String:
	return String(RELAY_TRANSPORT_TO_STRING.get(value, "unknown"))


static func spectator_reason_from_string(value: Variant) -> int:
	return int(SPECTATOR_REASON_FROM_STRING.get(String(value), SpectatorReason.UNKNOWN))


static func spectator_reason_to_string(value: int) -> String:
	return String(SPECTATOR_REASON_TO_STRING.get(value, "unknown"))


static func error_code_from_variant(value: Variant) -> int:
	return SFErrorCodesScript.from_string(value)


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
			if (
				typeof(value) != TYPE_STRING
				or game_data_encoding_from_string(value) == GameDataEncoding.UNKNOWN
			):
				return "ProtocolInfo game_data_formats contains unknown encoding"
	if dict.has("player_name_rules") and dict["player_name_rules"] != null:
		var error := validate_player_name_rules(dict["player_name_rules"])
		if not error.is_empty():
			return error
	return ""


static func validate_player_name_rules(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "player_name_rules must be an object"
	var dict: Dictionary = data
	for key: String in ["max_length", "min_length"]:
		if not _has_nonnegative_integer(dict, key):
			return "player_name_rules requires nonnegative integer %s" % key
	for key: String in [
		"allow_unicode_alphanumeric", "allow_spaces", "allow_leading_trailing_whitespace"
	]:
		if not _has_bool(dict, key):
			return "player_name_rules requires bool %s" % key
	if dict.has("allowed_symbols") and dict["allowed_symbols"] != null:
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
	for key: String in ["id", "name", "connected_at"]:
		if not _has_string(dict, key):
			return "PlayerInfo requires string %s" % key
	for key: String in ["is_authority", "is_ready"]:
		if not _has_bool(dict, key):
			return "PlayerInfo requires bool %s" % key
	if dict.has("connection_info"):
		var error := validate_connection_info(dict["connection_info"])
		if not error.is_empty():
			return error
	return ""


static func validate_spectator_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SpectatorInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["id", "name", "connected_at"]:
		if not _has_string(dict, key):
			return "SpectatorInfo requires string %s" % key
	return ""


static func validate_peer_connection_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "PeerConnectionInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["player_id", "player_name", "relay_type"]:
		if not _has_string(dict, key):
			return "PeerConnectionInfo requires string %s" % key
	if not _has_bool(dict, "is_authority"):
		return "PeerConnectionInfo requires bool is_authority"
	if dict.has("connection_info") and dict["connection_info"] != null:
		var error := validate_connection_info(dict["connection_info"])
		if not error.is_empty():
			return error
	return ""


static func validate_room_joined_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "RoomJoinedInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["room_id", "room_code", "player_id", "game_name", "relay_type"]:
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
	if not _has_string_array(dict, "ready_players"):
		return "RoomJoinedInfo requires string array ready_players"
	if dict.has("current_spectators"):
		var spectators_error := validate_spectators_array(dict["current_spectators"])
		if not spectators_error.is_empty():
			return "RoomJoinedInfo current_spectators: %s" % spectators_error
	return ""


static func validate_spectator_joined_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SpectatorJoinedInfo must be an object"
	var dict: Dictionary = data
	for key: String in ["room_id", "room_code", "spectator_id", "game_name"]:
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
	if dict.has("reason") and not _has_known_spectator_reason(dict, "reason"):
		return "SpectatorJoinedInfo reason is unknown"
	return ""


static func validate_players_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for value: Variant in array:
		var error := validate_player_info(value)
		if not error.is_empty():
			return error
	return ""


static func validate_spectators_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for value: Variant in array:
		var error := validate_spectator_info(value)
		if not error.is_empty():
			return error
	return ""


static func validate_peer_connections_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for value: Variant in array:
		var error := validate_peer_connection_info(value)
		if not error.is_empty():
			return error
	return ""


static func validate_connection_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "connection_info must be an object"
	var dict: Dictionary = data
	if not _has_string(dict, "type"):
		return "connection_info requires string type"
	match String(dict["type"]):
		"direct":
			if not _has_string(dict, "host"):
				return "direct connection_info requires host"
			if not _has_integer_in_range(dict, "port", 0, U16_MAX):
				return "direct connection_info requires u16 port"
		"unity_relay":
			for key: String in ["allocation_id", "connection_data", "key"]:
				if not _has_string(dict, key):
					return "unity_relay connection_info requires %s" % key
		"relay":
			for key: String in ["host", "allocation_id", "token"]:
				if not _has_string(dict, key):
					return "relay connection_info requires %s" % key
			if not _has_integer_in_range(dict, "port", 0, U16_MAX):
				return "relay connection_info requires u16 port"
			if (
				dict.has("transport")
				and dict["transport"] != null
				and (
					typeof(dict["transport"]) != TYPE_STRING
					or relay_transport_from_string(dict["transport"]) == RelayTransport.UNKNOWN
				)
			):
				return "relay connection_info transport is unknown"
			if (
				dict.has("client_id")
				and dict["client_id"] != null
				and not _is_integer_value_in_range(dict["client_id"], 0, U16_MAX)
			):
				return "relay connection_info client_id must be u16"
		"webrtc":
			if dict.has("sdp") and dict["sdp"] != null and typeof(dict["sdp"]) != TYPE_STRING:
				return "webrtc connection_info sdp must be a string"
			if not _has_string_array(dict, "ice_candidates"):
				return "webrtc connection_info requires ice_candidates"
		"custom":
			if not dict.has("data"):
				return "custom connection_info requires data"
		_:
			return "connection_info type is unknown"
	return _validate_common_connection_info_fields(dict)


static func _validate_common_connection_info_fields(dict: Dictionary) -> String:
	if dict.has("host") and dict["host"] != null and typeof(dict["host"]) != TYPE_STRING:
		return "connection_info host must be a string"
	if (
		dict.has("port")
		and dict["port"] != null
		and not _is_integer_value_in_range(dict["port"], 0, U16_MAX)
	):
		return "connection_info port must be u16"
	if dict.has("transport"):
		if (
			dict["transport"] != null
			and (
				typeof(dict["transport"]) != TYPE_STRING
				or relay_transport_from_string(dict["transport"]) == RelayTransport.UNKNOWN
			)
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


static func players_from_array(values: Variant) -> Array:
	var result: Array = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if typeof(value) == TYPE_DICTIONARY:
			result.append(PlayerInfo.new(value))
	return result


static func spectators_from_array(values: Variant) -> Array:
	var result: Array = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if typeof(value) == TYPE_DICTIONARY:
			result.append(SpectatorInfo.new(value))
	return result


static func peer_connections_from_array(values: Variant) -> Array:
	var result: Array = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		if typeof(value) == TYPE_DICTIONARY:
			result.append(PeerConnectionInfo.new(value))
	return result


static func game_data_encodings_from_array(values: Variant) -> Array:
	var result: Array = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		result.append(game_data_encoding_from_string(value))
	return result


static func _strings_from_array(values: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		result.append(String(value))
	return result


static func _local_strings_from_array(values: Variant) -> PackedStringArray:
	return _strings_from_array(values)


static func _local_game_data_encodings_from_array(values: Variant) -> Array:
	return game_data_encodings_from_array(values)


static func _local_relay_transport_from_string(value: Variant) -> int:
	return relay_transport_from_string(value)


static func _local_lobby_state_from_string(value: Variant) -> int:
	return lobby_state_from_string(value)


static func _local_spectator_reason_from_string(value: Variant) -> int:
	return spectator_reason_from_string(value)


static func _local_players_from_array(values: Variant) -> Array:
	return players_from_array(values)


static func _local_spectators_from_array(values: Variant) -> Array:
	return spectators_from_array(values)


static func _has_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING


static func _has_bool(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_BOOL


static func _has_number(data: Dictionary, key: String) -> bool:
	return data.has(key) and _is_number(data[key])


static func _has_nonnegative_integer(data: Dictionary, key: String) -> bool:
	return data.has(key) and _is_integer_value_at_least(data[key], 0)


static func _has_integer_in_range(
	data: Dictionary, key: String, min_value: int, max_value: int
) -> bool:
	return data.has(key) and _is_integer_value_in_range(data[key], min_value, max_value)


static func _has_string_array(data: Dictionary, key: String) -> bool:
	return data.has(key) and _is_string_array_value(data[key])


static func _has_known_lobby_state(data: Dictionary, key: String) -> bool:
	return _has_string(data, key) and lobby_state_from_string(data[key]) != LobbyState.UNKNOWN


static func _has_known_spectator_reason(data: Dictionary, key: String) -> bool:
	return (
		_has_string(data, key)
		and spectator_reason_from_string(data[key]) != SpectatorReason.UNKNOWN
	)


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _is_integer_value_at_least(value: Variant, min_value: int) -> bool:
	if not _is_integral_number(value):
		return false
	return float(value) >= float(min_value)


static func _is_integer_value_in_range(value: Variant, min_value: int, max_value: int) -> bool:
	if not _is_integer_value_at_least(value, min_value):
		return false
	return float(value) <= float(max_value)


static func _is_integral_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return number == floor(number)


static func _is_string_array_value(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	for entry: Variant in value:
		if typeof(entry) != TYPE_STRING:
			return false
	return true
