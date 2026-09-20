class_name SFErrorCodes
extends RefCounted

## Wire tokens mirror upstream `ErrorCode` (SCREAMING_SNAKE_CASE serde rename;
## server `src/protocol/error_codes.rs` @ 24a5d10b, v0.9.1). New upstream codes
## are appended at the end, grouped by their upstream doc category (the wire
## encoding is name-based, so enum order is free). String lookups are derived
## from the enum below — adding a code there is the only edit needed for
## decode/encode; [param _CODE_TO_CATEGORY] (completeness pinned by the
## protocol test suite) is the only other maintenance point.

enum Code {
	UNKNOWN = -1,
	NONE = 0,
	UNAUTHORIZED,
	INVALID_TOKEN,
	AUTHENTICATION_REQUIRED,
	INVALID_APP_ID,
	APP_ID_EXPIRED,
	APP_ID_REVOKED,
	APP_ID_SUSPENDED,
	MISSING_APP_ID,
	AUTHENTICATION_TIMEOUT,
	SDK_VERSION_UNSUPPORTED,
	UNSUPPORTED_GAME_DATA_FORMAT,
	INVALID_INPUT,
	INVALID_GAME_NAME,
	INVALID_ROOM_CODE,
	INVALID_PLAYER_NAME,
	INVALID_MAX_PLAYERS,
	MESSAGE_TOO_LARGE,
	ROOM_NOT_FOUND,
	ROOM_FULL,
	ALREADY_IN_ROOM,
	NOT_IN_ROOM,
	ROOM_CREATION_FAILED,
	MAX_ROOMS_PER_GAME_EXCEEDED,
	INVALID_ROOM_STATE,
	AUTHORITY_NOT_SUPPORTED,
	AUTHORITY_CONFLICT,
	AUTHORITY_DENIED,
	RATE_LIMIT_EXCEEDED,
	TOO_MANY_CONNECTIONS,
	RECONNECTION_FAILED,
	RECONNECTION_TOKEN_INVALID,
	RECONNECTION_EXPIRED,
	PLAYER_ALREADY_CONNECTED,
	SPECTATOR_NOT_ALLOWED,
	TOO_MANY_SPECTATORS,
	NOT_A_SPECTATOR,
	SPECTATOR_JOIN_FAILED,
	INTERNAL_ERROR,
	STORAGE_ERROR,
	SERVICE_UNAVAILABLE,
	# Cloud-compat alias: server/Rust use STORAGE_ERROR; the cloud also exposes
	# DATABASE_ERROR (PLAN §13 item 10).
	DATABASE_ERROR,
	# Signaling errors (8xxx).
	CROSS_ROOM_SIGNAL,
	UNSUPPORTED_TRANSPORT,
	SIGNAL_TARGET_NOT_FOUND,
	SIGNAL_RATE_LIMITED,
	SIGNAL_TOO_LARGE,
	# Connection lifecycle (upstream doc: Authentication 1xxx table).
	CONNECTION_IDLE_TIMEOUT,
	SLOW_CONSUMER,
	ACTIVITY_TIMEOUT,
	# Game-start (upstream doc: Room 3xxx table).
	GAME_START_NOT_READY,
	GAME_START_FORBIDDEN,
	ROOM_SESSION_INCOMPATIBLE,
	SERVER_DRAINING,
	# Delivery-class validation (upstream doc: Validation 2xxx table).
	INVALID_DELIVERY_CLASS,
	# Authentication (1xxx).
	UNSUPPORTED_PROTOCOL_VERSION,
	CONNECT_TOKEN_INVALID,
	CONNECT_TOKEN_REQUIRED,
	# Moderation (upstream doc: Room 3xxx table).
	NOT_ROOM_AUTHORITY,
	KICK_TARGET_NOT_FOUND,
	KICKED,
	PASSWORD_REQUIRED,
	BANNED,
	TRANSFER_TARGET_NOT_FOUND,
}

## Upstream `ErrorCode::NON_EMITTED` (server v0.9.1): decode-compat tokens the
## shipped server never emits. Kept here so old recordings still decode.
const NON_EMITTED_CODES: Array[String] = [
	"INVALID_TOKEN",
	"AUTHENTICATION_REQUIRED",
	"APP_ID_EXPIRED",
	"APP_ID_REVOKED",
	"APP_ID_SUSPENDED",
	"SERVICE_UNAVAILABLE",
]

## Category per code, following the upstream `docs/reference/error-codes.md`
## tables (category ranges 1xxx–9xxx). NON_EMITTED tokens and the cloud-only
## DATABASE_ERROR alias sit in their historic groups. Completeness (every enum
## member except UNKNOWN/NONE present) is pinned by the protocol test suite.
const _CODE_TO_CATEGORY: Dictionary = {
	Code.UNAUTHORIZED: "authentication",
	Code.INVALID_TOKEN: "authentication",
	Code.AUTHENTICATION_REQUIRED: "authentication",
	Code.INVALID_APP_ID: "authentication",
	Code.APP_ID_EXPIRED: "authentication",
	Code.APP_ID_REVOKED: "authentication",
	Code.APP_ID_SUSPENDED: "authentication",
	Code.MISSING_APP_ID: "authentication",
	Code.AUTHENTICATION_TIMEOUT: "authentication",
	Code.SDK_VERSION_UNSUPPORTED: "authentication",
	Code.UNSUPPORTED_GAME_DATA_FORMAT: "authentication",
	Code.CONNECTION_IDLE_TIMEOUT: "authentication",
	Code.SLOW_CONSUMER: "authentication",
	Code.ACTIVITY_TIMEOUT: "authentication",
	Code.UNSUPPORTED_PROTOCOL_VERSION: "authentication",
	Code.CONNECT_TOKEN_INVALID: "authentication",
	Code.CONNECT_TOKEN_REQUIRED: "authentication",
	Code.INVALID_INPUT: "validation",
	Code.INVALID_GAME_NAME: "validation",
	Code.INVALID_ROOM_CODE: "validation",
	Code.INVALID_PLAYER_NAME: "validation",
	Code.INVALID_MAX_PLAYERS: "validation",
	Code.MESSAGE_TOO_LARGE: "validation",
	Code.INVALID_DELIVERY_CLASS: "validation",
	Code.ROOM_NOT_FOUND: "room",
	Code.ROOM_FULL: "room",
	Code.ALREADY_IN_ROOM: "room",
	Code.NOT_IN_ROOM: "room",
	Code.ROOM_CREATION_FAILED: "room",
	Code.MAX_ROOMS_PER_GAME_EXCEEDED: "room",
	Code.INVALID_ROOM_STATE: "room",
	Code.GAME_START_NOT_READY: "room",
	Code.GAME_START_FORBIDDEN: "room",
	Code.ROOM_SESSION_INCOMPATIBLE: "room",
	Code.NOT_ROOM_AUTHORITY: "room",
	Code.KICK_TARGET_NOT_FOUND: "room",
	Code.KICKED: "room",
	Code.PASSWORD_REQUIRED: "room",
	Code.BANNED: "room",
	Code.TRANSFER_TARGET_NOT_FOUND: "room",
	Code.AUTHORITY_NOT_SUPPORTED: "authority",
	Code.AUTHORITY_CONFLICT: "authority",
	Code.AUTHORITY_DENIED: "authority",
	Code.RATE_LIMIT_EXCEEDED: "ratelimit",
	Code.TOO_MANY_CONNECTIONS: "ratelimit",
	Code.RECONNECTION_FAILED: "reconnection",
	Code.RECONNECTION_TOKEN_INVALID: "reconnection",
	Code.RECONNECTION_EXPIRED: "reconnection",
	Code.PLAYER_ALREADY_CONNECTED: "reconnection",
	Code.SPECTATOR_NOT_ALLOWED: "spectator",
	Code.TOO_MANY_SPECTATORS: "spectator",
	Code.NOT_A_SPECTATOR: "spectator",
	Code.SPECTATOR_JOIN_FAILED: "spectator",
	Code.CROSS_ROOM_SIGNAL: "signaling",
	Code.UNSUPPORTED_TRANSPORT: "signaling",
	Code.SIGNAL_TARGET_NOT_FOUND: "signaling",
	Code.SIGNAL_RATE_LIMITED: "signaling",
	Code.SIGNAL_TOO_LARGE: "signaling",
	Code.INTERNAL_ERROR: "server",
	Code.STORAGE_ERROR: "server",
	Code.SERVICE_UNAVAILABLE: "server",
	Code.DATABASE_ERROR: "server",
	Code.SERVER_DRAINING: "server",
}


static func from_string(error_code: Variant) -> int:
	if error_code == null:
		return Code.NONE
	if typeof(error_code) != TYPE_STRING:
		return Code.UNKNOWN
	var token := String(error_code)
	if token.is_empty():
		return Code.NONE
	if token == "UNKNOWN" or token == "NONE" or not Code.has(token):
		return Code.UNKNOWN
	return int(Code[token])


static func to_wire_string(error_code: int) -> String:
	if error_code == Code.NONE:
		return ""
	for token: String in Code:
		if Code[token] == error_code:
			return token
	return "UNKNOWN"


static func is_known(error_code: Variant) -> bool:
	if typeof(error_code) != TYPE_STRING:
		return false
	var token := String(error_code)
	return Code.has(token) and token != "UNKNOWN" and token != "NONE"


static func category(error_code: int) -> String:
	if error_code == Code.NONE:
		return "none"
	return String(_CODE_TO_CATEGORY.get(error_code, "unknown"))
