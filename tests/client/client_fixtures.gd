extends RefCounted

## Shared wire-shape builders for the client test suites. Static and pure:
## suites and runners assemble server payloads from these so fixture shapes
## stay defined in exactly one place.

const PLAYER_A := "10000000-0000-0000-0000-000000000001"
const PLAYER_B := "10000000-0000-0000-0000-000000000002"
const ROOM_ID := "20000000-0000-0000-0000-000000000001"


static func authenticated_data() -> Dictionary:
	return {
		"app_name": "Reef Rally",
		"organization": "",
		"rate_limits": {"per_minute": 60, "per_hour": 1000, "per_day": 10000},
	}


static func protocol_info() -> Dictionary:
	return {
		"platform": "steam",
		"sdk_version": "0.8.0",
		"minimum_version": "0.7.0",
		"recommended_version": "0.8.0",
		"notes": "",
		"capabilities": [],
		"game_data_formats": ["json", "message_pack"],
		"player_name_rules":
		{
			"max_length": 32,
			"min_length": 3,
			"allow_unicode_alphanumeric": true,
			"allow_spaces": true,
			"allow_leading_trailing_whitespace": false,
			"allowed_symbols": ["-", "_"]
		},
	}


static func player(id: String, display_name: String) -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"is_authority": id == PLAYER_A,
		"is_ready": false,
		"connected_at": "2026-05-29T00:00:00Z"
	}


static func spectator(id: String, display_name: String) -> Dictionary:
	return {"id": id, "name": display_name, "connected_at": "2026-05-29T00:00:01Z"}


static func peer_connection() -> Dictionary:
	return {
		"player_id": PLAYER_A,
		"player_name": "Alice",
		"is_authority": true,
		"relay_type": "websocket"
	}


static func room_joined_data(overrides: Dictionary = {}) -> Dictionary:
	var data := {
		"room_id": ROOM_ID,
		"room_code": "ABC123",
		"player_id": PLAYER_A,
		"game_name": "reef-rally",
		"max_players": 4,
		"supports_authority": true,
		"current_players": [player(PLAYER_A, "Alice")],
		"is_authority": true,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket",
		"current_spectators": [spectator(PLAYER_B, "Observer")],
	}
	for key: String in overrides:
		data[key] = overrides[key]
	return data
