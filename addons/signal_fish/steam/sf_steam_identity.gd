class_name SFSteamIdentity
extends RefCounted

## The role-scoped SteamId64 envelope carried over the room's game-data lane
## (issue #312). The wire shape mirrors the dotnet client's
## [code]SteamIdentityEnvelope[/code] byte for byte, so a room can mix
## bindings in principle: [code]{"signal_fish_steam_host": "<id>" }[/code] is
## the host's id (the host publishes, peers dial it), and
## [code]{"signal_fish_steam_peer": "<id>" }[/code] is a peer's id (the peer
## publishes, the host consumes it into the accept fence). The game-data lane
## is a room broadcast, so the role keys are what keep a peer from reading
## another peer's id as the host's.
##
## An id is a decimal string of 1-20 digits with no leading zero, so a 64-bit
## SteamId survives every JSON decoder losslessly (a raw 64-bit number would
## not). A foreign or malformed payload decodes as absent - never as an
## error - because the lane is shared with the game's own payloads.

## The host lane's key, matched verbatim.
const HOST_LANE_KEY := "signal_fish_steam_host"
## The peer lane's key, matched verbatim.
const PEER_LANE_KEY := "signal_fish_steam_peer"
## The longest SteamId64 the envelope accepts (20 digits covers the full
## unsigned 64-bit range).
const MAX_STEAM_ID_LENGTH := 20


## Whether the id fits the envelope's charset, length, and no-leading-zero
## shape.
static func is_valid_steam_id(steam_id: String) -> bool:
	if steam_id.is_empty() or steam_id.length() > MAX_STEAM_ID_LENGTH:
		return false
	if steam_id.unicode_at(0) < 0x31 or steam_id.unicode_at(0) > 0x39:
		return false
	for index: int in steam_id.length():
		var code := steam_id.unicode_at(index)
		if code < 0x30 or code > 0x39:
			return false
	return true


## The host publish envelope; [code]{}[/code] when the id is invalid.
static func host_envelope(steam_id: String) -> Dictionary:
	return _envelope(HOST_LANE_KEY, steam_id)


## The peer publish envelope; [code]{}[/code] when the id is invalid.
static func peer_envelope(steam_id: String) -> Dictionary:
	return _envelope(PEER_LANE_KEY, steam_id)


## Reads a host id out of a decoded game-data payload; [code]""[/code] when
## the payload carries no host envelope.
static func read_host(payload: Variant) -> String:
	return read_lane(payload, HOST_LANE_KEY)


## Reads a peer id out of a decoded game-data payload; [code]""[/code] when
## the payload carries no peer envelope.
static func read_peer(payload: Variant) -> String:
	return read_lane(payload, PEER_LANE_KEY)


## Reads an id under one lane key out of a decoded game-data payload.
## Unknown fields and non-object payloads decode as absent, and a value that
## fails [method is_valid_steam_id] decodes as absent too - a malformed
## envelope must never surface as an error on a shared lane.
static func read_lane(payload: Variant, lane_key: String) -> String:
	if typeof(payload) != TYPE_DICTIONARY:
		return ""
	var envelope: Dictionary = payload
	if not envelope.has(lane_key):
		return ""
	var value: Variant = envelope[lane_key]
	if typeof(value) != TYPE_STRING:
		return ""
	var steam_id: String = value
	return steam_id if is_valid_steam_id(steam_id) else ""


static func _envelope(lane_key: String, steam_id: String) -> Dictionary:
	if not is_valid_steam_id(steam_id):
		return {}
	return {lane_key: steam_id}
