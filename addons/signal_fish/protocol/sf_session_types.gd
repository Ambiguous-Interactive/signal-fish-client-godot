class_name SFSessionTypes
extends RefCounted

## Protocol v3 session-plan value objects (upstream `SessionPlanPayload`,
## `SessionPeer`, `DirectEndpoint`, `IceServer`, `NewPeer`,
## `PeerTransportStatus`, `GoingAway`, `DeliveryReport`,
## `RoomOperationResult` in signal-fish-client-rust `src/protocol.rs`, pinned
## by `tests/fixtures/v3_server_messages.jsonl` and the vendored upstream
## sample corpus). Split from [code]SFTypes[/code]
## to keep that file focused on the v2 surface; the enums and lookup tables
## here are the v3 additions to the protocol's closed token sets.

enum Topology { UNKNOWN = -1, RELAY, HOST, MESH }
enum TransportKind { UNKNOWN = -1, RELAY, DIRECT, WEBRTC }
enum DeliveryGapReason { UNKNOWN = -1, LATEST_SUPERSEDED, LATEST_DROPPED_FULL, VOLATILE_DROPPED, UNSUPPORTED_FORMAT }

const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFDiagnosticsScript = preload("res://addons/signal_fish/protocol/sf_diagnostics.gd")

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

const DELIVERY_GAP_REASON_FROM_STRING: Dictionary = {
	"latest_superseded": DeliveryGapReason.LATEST_SUPERSEDED,
	"latest_dropped_full": DeliveryGapReason.LATEST_DROPPED_FULL,
	"volatile_dropped": DeliveryGapReason.VOLATILE_DROPPED,
	"unsupported_format": DeliveryGapReason.UNSUPPORTED_FORMAT,
}

## Maximum exact omission ranges in one DeliveryReport (upstream
## `DELIVERY_REPORT_MAX_GAPS`): refuse larger hostile arrays.
const MAX_DELIVERY_GAPS := 256

## The closed upstream `RoomOperationResult` variant set (server
## `src/protocol/messages.rs` @ v0.9.1 wire commit, unchanged through
## v0.10.0). The client never issues RoomOperations yet, so any result is
## unsolicited: decoded and surfaced verbatim, never applied to session
## state.
const ROOM_OPERATION_RESULT_TYPES: Array[String] = [
	"RoomJoined",
	"RoomJoinFailed",
	"RoomLeft",
	"Reconnected",
	"ReconnectionFailed",
	"SpectatorJoined",
	"SpectatorJoinFailed",
	"SpectatorLeft",
	"OperationFailed",
	"PlayerKicked",
	"RoomCodeRegenerated",
	"RoomAccessUpdated",
	"PlayerBanned",
	"PlayerUnbanned",
	"AuthorityTransferred",
]


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
		username = SFTypeUtils.string_or_empty(data.get("username"))
		credential = SFTypeUtils.string_or_empty(data.get("credential"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _to_string() -> String:
		# Urls stay free text after validation (array shape only), so
		# each item is length-bounded like a key (issues #284, #286).
		var shown := PackedStringArray()
		for url: String in SFDiagnosticsScript.bound_items(urls):
			shown.append(SFDiagnosticsScript.bound_item(url))
		return "IceServerInfo(%s)" % ", ".join(shown)


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
		player_id = SFTypeUtils.string_or_empty(data.get("player_id"))
		player_name = SFTypeUtils.string_or_empty(data.get("player_name"))
		is_authority = SFTypeUtils.bool_or_false(data.get("is_authority"))
		initiate = SFTypeUtils.bool_or_false(data.get("initiate"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


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
		host = SFTypeUtils.string_or_empty(data.get("host"))
		# Same gate as ConnectionInfo.port: a magnitude too large for int()
		# takes the 0 absent sentinel instead of collapsing
		# platform-dependently (issues #81/#96).
		port = SFTypeUtils.int_or_zero(data.get("port"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


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
	var peers: Array[SessionPeerInfo] = []
	var ice_servers: Array[IceServerInfo] = []
	var fallback: int = TransportKind.UNKNOWN
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		generation = SFTypeUtils.string_or_empty(data.get("generation"))
		topology = SFTypeUtils.enum_value(
			TOPOLOGY_FROM_STRING, data.get("topology"), Topology.UNKNOWN
		)
		transport = SFTypeUtils.enum_value(
			TRANSPORT_KIND_FROM_STRING, data.get("transport"), TransportKind.UNKNOWN
		)
		host = SFTypeUtils.string_or_empty(data.get("host"))
		var endpoint_value: Variant = data.get("direct_endpoint")
		if endpoint_value is Dictionary:
			var endpoint: Dictionary = endpoint_value
			direct_endpoint = DirectEndpointInfo.new(endpoint)
		peers = _coerce_peers(data.get("peers", []))
		ice_servers = _coerce_ice_servers(data.get("ice_servers", []))
		fallback = SFTypeUtils.enum_value(
			TRANSPORT_KIND_FROM_STRING, data.get("fallback"), TransportKind.UNKNOWN
		)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)

	func _to_string() -> String:
		# Inner classes cannot call the outer script's static functions, so
		# the wire labels are looked up through the shared constant tables.
		# The peer list is wire-derived and count-bounded like every
		# diagnostic sink (issue #284). Ids are validated canonical UUIDs
		# on the decode path, but the constructor is public, so each
		# rendered id is length-bounded at the UUID width and
		# control-escaped (issue #287).
		var raw_ids := PackedStringArray()
		for peer: SessionPeerInfo in peers:
			raw_ids.append(peer.player_id)
		var peer_ids := PackedStringArray()
		for peer_id: String in SFDiagnosticsScript.bound_items(raw_ids):
			peer_ids.append(SFDiagnosticsScript.bound_id(peer_id))
		var topology_text: String = TOPOLOGY_TO_STRING.get(topology, "unknown")
		var transport_text: String = TRANSPORT_KIND_TO_STRING.get(transport, "unknown")
		return (
			"SessionPlanInfo(generation=%s topology=%s transport=%s peers=[%s])"
			% [
				SFDiagnosticsScript.bound_id(generation),
				topology_text,
				transport_text,
				", ".join(peer_ids),
			]
		)

	func _coerce_peers(values: Variant) -> Array[SessionPeerInfo]:
		var result: Array[SessionPeerInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(SessionPeerInfo.new(entry))
		return result

	func _coerce_ice_servers(values: Variant) -> Array[IceServerInfo]:
		var result: Array[IceServerInfo] = []
		if typeof(values) != TYPE_ARRAY:
			return result
		for value: Variant in values:
			if value is Dictionary:
				var entry: Dictionary = value
				result.append(IceServerInfo.new(entry))
		return result


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
		peer_id = SFTypeUtils.string_or_empty(data.get("peer_id"))
		you_initiate = SFTypeUtils.bool_or_false(data.get("you_initiate"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


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
		peer_id = SFTypeUtils.string_or_empty(data.get("peer_id"))
		transport = SFTypeUtils.enum_value(
			TRANSPORT_KIND_FROM_STRING, data.get("transport"), TransportKind.UNKNOWN
		)
		connected = SFTypeUtils.bool_or_false(data.get("connected"))

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


## One exact omission range in a DeliveryReport (upstream `DeliveryGap`).
## [code]from_seq[/code]/[code]to_seq[/code] are the inclusive omitted
## sequence bounds of one sender's stream.
class DeliveryGapInfo:
	extends RefCounted
	var from_player: String = ""
	var epoch: int = 0
	var from_seq: int = 0
	var to_seq: int = 0
	var reason: int = DeliveryGapReason.UNKNOWN
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		from_player = SFTypeUtils.string_or_empty(data.get("from_player"))
		epoch = SFTypeUtils.int_or_zero(data.get("epoch"))
		from_seq = SFTypeUtils.int_or_zero(data.get("from_seq"))
		to_seq = SFTypeUtils.int_or_zero(data.get("to_seq"))
		reason = SFTypeUtils.enum_value(
			DELIVERY_GAP_REASON_FROM_STRING, data.get("reason"), DeliveryGapReason.UNKNOWN
		)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


## Cumulative outcomes for one delivery class (upstream
## `ReliableDeliveryCounters`/`LatestDeliveryCounters`/
## `VolatileDeliveryCounters`). Counters are wire u64, so values above the
## platform int range are refused at validation (issue #73 policy).
class DeliveryClassCountersInfo:
	extends RefCounted
	var counters: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		for key: String in data:
			counters[key] = SFTypeUtils.int_or_zero(data[key])

	func get_count(key: String) -> int:
		return counters.get(key, 0)


## The exact delivery-accountability report (upstream `DeliveryReportPayload`,
## protocol v3 only). Informational: the client surfaces it and never acts on
## it. Known class keys mirror upstream; unknown future classes survive in
## [code]raw[/code].
class DeliveryReportInfo:
	extends RefCounted
	var per_class: Dictionary = {}
	var gaps: Array[DeliveryGapInfo] = []
	var raw: Dictionary = {}

	func _init(data: Dictionary = {}) -> void:
		raw = data
		var wire_classes: Dictionary = data.get("per_class", {})
		for class_key: String in wire_classes:
			var counters: Dictionary = wire_classes[class_key]
			per_class[class_key] = DeliveryClassCountersInfo.new(counters)
		for gap: Dictionary in data.get("gaps", []):
			gaps.append(DeliveryGapInfo.new(gap))

	func counters_for(class_key: String) -> DeliveryClassCountersInfo:
		return per_class.get(class_key, null)

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


## A terminal response carried by a v3 `RoomOperationResult` (upstream
## `RoomOperationResult`, 15 closed variants). [code]result_type[/code] is the
## wire variant name; [code]data[/code] is the validated variant payload.
## Correlation (matching one to a pending operation) lands with the
## RoomOperation sender; until then every result is surfaced verbatim.
class RoomOperationResultInfo:
	extends RefCounted
	var operation_id: String = ""
	var result_type: String = ""
	var data: Dictionary = {}
	var raw: Dictionary = {}

	func _init(data_dict: Dictionary = {}) -> void:
		raw = data_dict
		operation_id = SFTypeUtils.string_or_empty(data_dict.get("operation_id"))
		var result: Variant = data_dict.get("result", {})
		if result is Dictionary:
			var result_dict: Dictionary = result
			result_type = SFTypeUtils.string_or_empty(result_dict.get("type"))
			var result_data: Variant = result_dict.get("data", {})
			if result_data is Dictionary:
				data = result_data

	func to_dict() -> Dictionary:
		return raw.duplicate(true)


static func topology_from_string(value: Variant) -> int:
	return SFTypeUtils.enum_value(TOPOLOGY_FROM_STRING, value, Topology.UNKNOWN)


static func topology_to_string(value: int) -> String:
	var token: String = TOPOLOGY_TO_STRING.get(value, "unknown")
	return token


static func transport_kind_from_string(value: Variant) -> int:
	return SFTypeUtils.enum_value(TRANSPORT_KIND_FROM_STRING, value, TransportKind.UNKNOWN)


static func transport_kind_to_string(value: int) -> String:
	var token: String = TRANSPORT_KIND_TO_STRING.get(value, "unknown")
	return token


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
	# `Option<PlayerId>`): present values must be canonical lowercase
	# hyphenated UUID text (issues #149/#151). Absent or null generation
	# stays legal for the legacy Server 0.4 plan shape.
	if dict.has("generation") and dict["generation"] != null:
		if typeof(dict["generation"]) != TYPE_STRING:
			return "SessionPlanInfo generation must be a string"
		if not _has_id(dict, "generation"):
			return "SessionPlanInfo generation must be a lowercase hyphenated UUID"
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
			return "SessionPlanInfo host must be a lowercase hyphenated UUID"
	if dict.has("direct_endpoint") and dict["direct_endpoint"] != null:
		if typeof(dict["direct_endpoint"]) != TYPE_DICTIONARY:
			return "SessionPlanInfo direct_endpoint must be an object"
		var endpoint: Dictionary = dict["direct_endpoint"]
		# Upstream refuses an empty host when constructing a DirectEndpoint
		# (`DirectEndpoint::from_connection_info`, src/protocol/validation.rs).
		# The host is a free-text address, not a UUID identifier (issue #151
		# keeps it on the #149 non-empty rule).
		if (
			not _has_string(endpoint, "host")
			or SFTypeUtils.string_or_empty(endpoint.get("host")).is_empty()
		):
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


static func validate_delivery_report(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "DeliveryReport data must be an object"
	var dict: Dictionary = data
	if not dict.has("per_class") or typeof(dict["per_class"]) != TYPE_DICTIONARY:
		return "DeliveryReport requires a per_class object"
	var per_class: Dictionary = dict["per_class"]
	for class_key: String in per_class:
		var error := _validate_delivery_counters(per_class[class_key])
		if not error.is_empty():
			return "DeliveryReport per_class.%s: %s" % [class_key, error]
	if dict.has("gaps") and dict["gaps"] != null:
		var gaps_error := _validate_delivery_gaps(dict["gaps"])
		if not gaps_error.is_empty():
			return "DeliveryReport %s" % gaps_error
	return ""


static func make_delivery_report(data: Dictionary) -> DeliveryReportInfo:
	return DeliveryReportInfo.new(data)


static func make_room_operation_result(data: Dictionary) -> RoomOperationResultInfo:
	return RoomOperationResultInfo.new(data)


static func _validate_ice_server(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "IceServer must be an object"
	var dict: Dictionary = data
	# Deliberately stricter than the upstream `Vec<String>` type: an empty
	# url list gathers no candidates, so the entry is treated as malformed
	# (decode fails loud, link stays up) instead of silently useless.
	if not _has_string_array(dict, "urls"):
		return "IceServer requires a non-empty string array urls"
	var urls: Array = dict["urls"]
	if urls.is_empty():
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
		return "SessionPeer requires lowercase hyphenated UUID player_id"
	for key: String in ["player_name"]:
		if not _has_string(dict, key):
			return "SessionPeer requires string %s" % key
	for key: String in ["is_authority", "initiate"]:
		if not _has_bool(dict, key):
			return "SessionPeer requires bool %s" % key
	return ""


static func _has_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING


static func _has_id(data: Dictionary, key: String) -> bool:
	return SFTypeUtils.is_canonical_uuid_text(data.get(key))


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
	if not _has_string(data, key):
		return false
	var token: String = data[key]
	return table.has(token)


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
	var number: float = value
	return number >= float(min_value) and number <= float(max_value)


static func _validate_delivery_counters(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "counters must be an object"
	var counters: Dictionary = value
	for key: String in counters:
		if not is_u64_wire_integer(counters[key]):
			return "counter %s must be a nonnegative integer" % key
	return ""


static func _validate_delivery_gaps(value: Variant) -> String:
	if typeof(value) != TYPE_ARRAY:
		return "gaps must be an array"
	var gaps: Array = value
	if gaps.size() > MAX_DELIVERY_GAPS:
		return "gaps exceed %d entries" % MAX_DELIVERY_GAPS
	for gap: Variant in gaps:
		if typeof(gap) != TYPE_DICTIONARY:
			return "gap entries must be objects"
		var entry: Dictionary = gap
		if not _has_id(entry, "from_player"):
			return "gap requires lowercase hyphenated UUID from_player"
		if not _is_integer_value_in_range(entry.get("epoch"), 0, U32_MAX):
			return "gap epoch must be u32"
		if not is_u64_wire_integer(entry.get("from_seq")):
			return "gap from_seq must be a nonnegative integer"
		if not is_u64_wire_integer(entry.get("to_seq")):
			return "gap to_seq must be a nonnegative integer"
		if not _has_known_enum_token(entry, "reason", DELIVERY_GAP_REASON_FROM_STRING):
			return "gap reason is unknown"
	return ""


## Wire u64: nonnegative and inside the platform int range. Values at or
## above 2^63 are hostile, never collapsed (issue #73 policy).
static func is_u64_wire_integer(value: Variant) -> bool:
	if value is int:
		var integer: int = value
		return integer >= 0
	if not SFTypeUtils.is_i64_integer(value):
		return false
	var number: float = value
	return number >= 0.0
