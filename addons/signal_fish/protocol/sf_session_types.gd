class_name SFSessionTypes
extends RefCounted

## Protocol v3 session-plan value objects (upstream `SessionPlanPayload`,
## `SessionPeer`, `DirectEndpoint`, `IceServer`, `NewPeer`,
## `PeerTransportStatus` in signal-fish-client-rust `src/protocol.rs`, pinned
## by `tests/fixtures/v3_server_messages.jsonl`). Split from [code]SFTypes[/code]
## to keep that file focused on the v2 surface; the enums and lookup tables
## here are the v3 additions to the protocol's closed token sets.

enum Topology { UNKNOWN = -1, RELAY, HOST, MESH }
enum TransportKind { UNKNOWN = -1, RELAY, DIRECT, WEBRTC }

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")

const U16_MAX := 65535
const U32_MAX := 4294967295

const TOPOLOGY_TO_STRING: Dictionary = {
	Topology.RELAY: "relay",
	Topology.HOST: "host",
	Topology.MESH: "mesh",
}
const TOPOLOGY_FROM_STRING: Dictionary = {
	"relay": Topology.RELAY,
	"host": Topology.HOST,
	"mesh": Topology.MESH,
}
const TRANSPORT_KIND_TO_STRING: Dictionary = {
	TransportKind.RELAY: "relay",
	TransportKind.DIRECT: "direct",
	TransportKind.WEBRTC: "webrtc",
}
const TRANSPORT_KIND_FROM_STRING: Dictionary = {
	"relay": TransportKind.RELAY,
	"direct": TransportKind.DIRECT,
	"webrtc": TransportKind.WEBRTC,
}


## A STUN/TURN server for WebRTC ICE negotiation (upstream `IceServer`).
## `username`/`credential` are present only for TURN servers; bare STUN
## entries leave them empty. The credential is a secret: it is excluded from
## [_to_string] and must never be logged (PLAN §12).
class IceServerInfo:
	extends RefCounted
	var urls: PackedStringArray = PackedStringArray()
	var username: String = ""
	var credential: String = ""
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		urls = SFTypeUtils.coerce_string_array(data.get("urls", []))
		username = _string_or_empty(data.get("username"))
		credential = _string_or_empty(data.get("credential"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _to_string() -> String:
		return "IceServerInfo(%s)" % [", ".join(urls)]

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)


## A peer the recipient should connect to within a SessionPlanInfo (upstream
## `SessionPeer`). [code]initiate[/code] is the server-assigned deterministic
## offerer flag: obey it verbatim — the client never computes who offers.
class SessionPeerInfo:
	extends RefCounted
	var player_id: String = ""
	var player_name: String = ""
	var is_authority: bool = false
	var initiate: bool = false
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		player_id = _string_or_empty(data.get("player_id"))
		player_name = _string_or_empty(data.get("player_name"))
		is_authority = SFTypeUtils.bool_or_false(data.get("is_authority"))
		initiate = SFTypeUtils.bool_or_false(data.get("initiate"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)


## A syntactically usable direct host endpoint for a [code]host + direct[/code]
## plan (upstream `DirectEndpoint`). Self-declared by the host: not proof of
## reachability, so the relay fallback always remains.
class DirectEndpointInfo:
	extends RefCounted
	var host: String = ""
	var port: int = 0
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		host = _string_or_empty(data.get("host"))
		# Same gate as ConnectionInfo.port: a magnitude too large for int()
		# takes the 0 absent sentinel instead of collapsing
		# platform-dependently (issues #81/#96).
		var port_value: Variant = data.get("port")
		port = int(port_value) if SFTypeUtils.is_i64_integer(port_value) else 0

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)


## The per-recipient authoritative session directive (upstream
## `SessionPlanPayload`). Emitted at finalization and re-issued on late joins,
## host re-election, relay resets, and reconnect replay; the latest plan wins
## and fully replaces the previous one. [code]peers[/code] excludes the
## recipient; [code]generation[/code] is "" on the legacy Server 0.4 shape;
## [code]host[/code]/[code]direct_endpoint[/code] apply only to host topology.
## ICE server credentials are secrets: redacted from [_to_string] (PLAN §12).
class SessionPlanInfo:
	extends RefCounted
	var generation: String = ""
	var topology: int = Topology.UNKNOWN
	var transport: int = TransportKind.UNKNOWN
	var host: String = ""
	var direct_endpoint: DirectEndpointInfo = null
	var peers: Array = []
	var ice_servers: Array = []
	var fallback: int = TransportKind.UNKNOWN
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		generation = _string_or_empty(data.get("generation"))
		topology = _topology_token(data.get("topology"))
		transport = _transport_kind_token(data.get("transport"))
		host = _string_or_empty(data.get("host"))
		if data.has("direct_endpoint") and typeof(data.get("direct_endpoint")) == TYPE_DICTIONARY:
			direct_endpoint = DirectEndpointInfo.new(data["direct_endpoint"])
		peers = _coerce_objects(data.get("peers", []), SessionPeerInfo)
		ice_servers = _coerce_objects(data.get("ice_servers", []), IceServerInfo)
		fallback = _transport_kind_token(data.get("fallback"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _to_string() -> String:
		# Inner classes cannot call the outer script's static functions, so
		# the wire labels are looked up through the shared constant tables.
		var peer_ids := PackedStringArray()
		for peer in peers:
			peer_ids.append(peer.player_id)
		return (
			"SessionPlanInfo(generation=%s topology=%s transport=%s peers=[%s])"
			% [
				generation,
				String(TOPOLOGY_TO_STRING.get(topology, "unknown")),
				String(TRANSPORT_KIND_TO_STRING.get(transport, "unknown")),
				", ".join(peer_ids),
			]
		)

	func _coerce_objects(values: Variant, object_type: Variant) -> Array:
		var result: Array = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if typeof(value) == TYPE_DICTIONARY:
				result.append(object_type.new(value))
		return result

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)

	func _transport_kind_token(value: Variant) -> int:
		if typeof(value) != TYPE_STRING:
			return TransportKind.UNKNOWN
		return int(TRANSPORT_KIND_FROM_STRING.get(String(value), TransportKind.UNKNOWN))

	func _topology_token(value: Variant) -> int:
		if typeof(value) != TYPE_STRING:
			return Topology.UNKNOWN
		return int(TOPOLOGY_FROM_STRING.get(String(value), Topology.UNKNOWN))


## Compatibility directive for an additive WebRTC peer after finalization
## (upstream `NewPeer`). Current membership changes use complete
## SessionPlanInfo refreshes instead; [code]you_initiate[/code] obeys the same
## server-assigned offerer rule.
class NewPeerInfo:
	extends RefCounted
	var peer_id: String = ""
	var you_initiate: bool = false
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		peer_id = _string_or_empty(data.get("peer_id"))
		you_initiate = SFTypeUtils.bool_or_false(data.get("you_initiate"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)


## A same-room peer's data-path transport state change (upstream
## `PeerTransportStatus`). Informational: never invents a peer and never
## closes the relay floor.
class PeerTransportStatusInfo:
	extends RefCounted
	var peer_id: String = ""
	var transport: int = TransportKind.UNKNOWN
	var connected: bool = false
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		peer_id = _string_or_empty(data.get("peer_id"))
		transport = _transport_kind_token(data.get("transport"))
		connected = SFTypeUtils.bool_or_false(data.get("connected"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _transport_kind_token(value: Variant) -> int:
		if typeof(value) != TYPE_STRING:
			return TransportKind.UNKNOWN
		return int(TRANSPORT_KIND_FROM_STRING.get(String(value), TransportKind.UNKNOWN))

	func _string_or_empty(value: Variant) -> String:
		if typeof(value) != TYPE_STRING:
			return ""
		return String(value)


static func topology_from_string(value: Variant) -> int:
	if typeof(value) != TYPE_STRING:
		return Topology.UNKNOWN
	return int(TOPOLOGY_FROM_STRING.get(String(value), Topology.UNKNOWN))


static func topology_to_string(value: int) -> String:
	return String(TOPOLOGY_TO_STRING.get(value, "unknown"))


static func transport_kind_from_string(value: Variant) -> int:
	if typeof(value) != TYPE_STRING:
		return TransportKind.UNKNOWN
	return int(TRANSPORT_KIND_FROM_STRING.get(String(value), TransportKind.UNKNOWN))


static func transport_kind_to_string(value: int) -> String:
	return String(TRANSPORT_KIND_TO_STRING.get(value, "unknown"))


static func validate_ice_servers_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for index: int in array.size():
		var error := _validate_ice_server(array[index])
		if not error.is_empty():
			return "[%d] %s" % [index, error]
	return ""


static func validate_session_plan_info(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SessionPlanInfo must be an object"
	var dict: Dictionary = data
	# generation/host are upstream Uuid-typed (`SessionGeneration`,
	# `Option<PlayerId>`): present values must be non-empty (issue #149). An
	# absent generation stays legal for the legacy Server 0.4 plan shape.
	if dict.has("generation") and dict["generation"] != null:
		if typeof(dict["generation"]) != TYPE_STRING:
			return "SessionPlanInfo generation must be a string"
		if not _has_id(dict, "generation"):
			return "SessionPlanInfo generation must not be empty"
	if not _has_known_enum_token(dict, "topology", TOPOLOGY_FROM_STRING):
		return "SessionPlanInfo topology is unknown"
	if not _has_known_enum_token(dict, "transport", TRANSPORT_KIND_FROM_STRING):
		return "SessionPlanInfo transport is unknown"
	if not _has_known_enum_token(dict, "fallback", TRANSPORT_KIND_FROM_STRING):
		return "SessionPlanInfo fallback is unknown"
	if dict.has("host") and dict["host"] != null:
		if typeof(dict["host"]) != TYPE_STRING:
			return "SessionPlanInfo host must be a string"
		if not _has_id(dict, "host"):
			return "SessionPlanInfo host must not be empty"
	if dict.has("direct_endpoint") and dict["direct_endpoint"] != null:
		if typeof(dict["direct_endpoint"]) != TYPE_DICTIONARY:
			return "SessionPlanInfo direct_endpoint must be an object"
		var endpoint: Dictionary = dict["direct_endpoint"]
		# Upstream refuses an empty host when constructing a DirectEndpoint
		# (`DirectEndpoint::from_connection_info`, src/protocol/validation.rs).
		if not _has_id(endpoint, "host"):
			return "SessionPlanInfo direct_endpoint requires non-empty string host"
		if not _is_integer_value_in_range(endpoint.get("port", 0), 1, U16_MAX):
			return "SessionPlanInfo direct_endpoint requires port in 1..65535"
	if not _has_dict_array(dict, "peers"):
		return "SessionPlanInfo peers must be an array of objects"
	var peers_error := validate_session_peers_array(dict["peers"])
	if not peers_error.is_empty():
		return "SessionPlanInfo peers: %s" % peers_error
	if dict.has("ice_servers") and dict["ice_servers"] != null:
		var ice_error := validate_ice_servers_array(dict["ice_servers"])
		if not ice_error.is_empty():
			return "SessionPlanInfo ice_servers: %s" % ice_error
	return ""


static func validate_session_peers_array(values: Variant) -> String:
	if typeof(values) != TYPE_ARRAY:
		return "must be an array"
	var array: Array = values
	for index: int in array.size():
		var error := _validate_session_peer(array[index])
		if not error.is_empty():
			return "[%d] %s" % [index, error]
	return ""


static func make_session_plan_info(data: Dictionary) -> SessionPlanInfo:
	return SessionPlanInfo.new(data)


static func _validate_ice_server(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "IceServer must be an object"
	var dict: Dictionary = data
	# Deliberately stricter than the upstream `Vec<String>` type: an empty
	# url list gathers no candidates, so the entry is treated as malformed
	# (decode fails loud, link stays up) instead of silently useless.
	if not _has_string_array(dict, "urls") or (dict["urls"] as Array).is_empty():
		return "IceServer requires a non-empty string array urls"
	for key: String in ["username", "credential"]:
		if dict.has(key) and dict[key] != null and typeof(dict[key]) != TYPE_STRING:
			return "IceServer %s must be a string" % key
	return ""


static func _validate_session_peer(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "SessionPeer must be an object"
	var dict: Dictionary = data
	if not _has_id(dict, "player_id"):
		return "SessionPeer requires non-empty string player_id"
	for key: String in ["player_name"]:
		if not _has_string(dict, key):
			return "SessionPeer requires string %s" % key
	for key: String in ["is_authority", "initiate"]:
		if not _has_bool(dict, key):
			return "SessionPeer requires bool %s" % key
	return ""


static func _has_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING


## A present upstream-UUID identifier (`PlayerId`/`SessionGeneration`) must be
## non-empty: empty cannot deserialize upstream, and it would collide with the
## retired negotiated-rkyv "" sender-unknowable sentinel (issue #149).
static func _has_id(data: Dictionary, key: String) -> bool:
	return _has_string(data, key) and not (data[key] as String).is_empty()


static func _has_bool(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_BOOL


static func _has_string_array(data: Dictionary, key: String) -> bool:
	if not data.has(key) or typeof(data[key]) != TYPE_ARRAY:
		return false
	for value: Variant in data[key]:
		if typeof(value) != TYPE_STRING:
			return false
	return true


static func _has_known_enum_token(data: Dictionary, key: String, table: Dictionary) -> bool:
	return _has_string(data, key) and table.has(String(data[key]))


static func _has_dict_array(data: Dictionary, key: String) -> bool:
	if not data.has(key) or typeof(data[key]) != TYPE_ARRAY:
		return false
	for value: Variant in data[key]:
		if typeof(value) != TYPE_DICTIONARY:
			return false
	return true


static func _is_integer_value_in_range(value: Variant, min_value: int, max_value: int) -> bool:
	if not SFTypeUtils.is_integral_number(value):
		return false
	var number := float(value)
	return number >= float(min_value) and number <= float(max_value)
