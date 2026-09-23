class_name SignalFishConfig
extends Resource

## Connection settings for [SignalFishClient]. Author as a Resource in the
## editor or build in code, then pass to [method SignalFishClient.configure].
##
## ## Credential hygiene (PLAN §12)
## [member credential] carries the upstream [code]connect_token[/code]
## tenant credential (rust SDK 0.14.0, upstream issue #517): it is sent only
## as that [code]Authenticate[/code] wire field — never stitched into URLs,
## never included in [method _to_string], and redacted by
## [code]sf_log.gd[/code] when the client logs. Do not save a config
## Resource containing a credential to a committed file.

const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")

## Public application identifier. Safe to ship in game builds.
@export var app_id: String = ""

## Optional SDK version reported to the server. Empty = omitted from the wire.
@export var sdk_version: String = ""

## Optional platform identifier reported to the server. Empty = omitted.
@export var platform: String = ""

## Game data format preference sent with [code]Authenticate[/code].
## Empty = server-default JSON. [code]message_pack[/code] negotiates binary
## game-data frames (PLAN P2): received frames surface as bytes through
## [signal SignalFishClient.game_data_binary_received], or decoded through
## [signal SignalFishClient.game_data_received] when
## [member decode_msgpack_payloads] is on. [code]rkyv[/code] negotiates raw
## pass-through bytes this client can never decode — only pick it when your
## game brings its own rkyv reader (PLAN §4.6).
@export var game_data_format: String = ""

## Opt-in MessagePack payload decode: with [code]message_pack[/code] game data
## negotiated, received payloads are decoded to Godot values and surfaced
## through [signal SignalFishClient.game_data_received]; decode failures fall
## back to the bytes path. Default off (raw bytes, no transcode).
@export var decode_msgpack_payloads: bool = false

## Default endpoint used when [method SignalFishClient.connect_to_server] is
## called without an explicit URL.
@export var endpoint_url: String = ""

## Call [method SignalFishClient.poll] automatically from [code]_process[/code].
## Disable to drive polling manually (headless tests, custom loops).
@export var auto_poll: bool = true

## Drop inbound frames larger than this before any decode work.
@export var max_inbound_frame_bytes: int = 262144

## Refuse to send when the transport has more than this many bytes queued.
@export var max_buffered_bytes: int = 262144

## Upper bound on packets drained per [method SignalFishClient.poll]; overflow
## is picked up on the next poll.
@export var max_inbound_packets_per_poll: int = 64

## Budget of automatic reconnection attempts per lost session
## ([method SignalFishClient.set_auto_reconnect]). Manual
## [method SignalFishClient.reconnect] calls ignore this.
@export var reconnect_max_attempts: int = 5

## Optional dead-link heartbeat (PLAN §4.7): seconds between automatic
## [code]Ping[/code]s while the session is authenticated and connected.
## [code]0[/code] (default) disables the heartbeat entirely. Silent link
## death (NAT rebinding, radio loss) produces no WebSocket close, so without
## this the client stays "connected" forever and auto-reconnect never fires.
## Runs from [code]_process[/code] like the reconnect backoff: the client
## node must be in the tree (or the ticks driven manually).
@export var heartbeat_interval_sec: float = 0.0

## Grace period for a [signal SignalFishClient.pong] reply after a heartbeat
## ping. A silent link past this deadline is treated as dead: the client
## tears the link down through the transport-failure path
## ([signal SignalFishClient.connection_failed]), so opt-in auto-reconnect
## engages. The same silence deadline covers the AUTHENTICATING window,
## where protocol Ping is not allowed but a link that never delivers
## [code]Authenticated[/code] is just as dead (issue #121). Used only when
## [member heartbeat_interval_sec] is on.
@export var pong_timeout_sec: float = 10.0

## Highest protocol version advertised with [code]Authenticate[/code]
## (upstream `Authenticate.protocol_version`). [code]0[/code] = omit: the
## client stays on the v2 relay floor and v3-only messages never appear.
## Advertise [code]3[/code] (plus the lists below) to opt into peer-to-peer
## session plans; the negotiated result arrives through
## [signal SignalFishClient.protocol_info].
@export var protocol_version: int = 0

## Data-path transports this client can actually fulfill, as wire tokens
## ([code]relay[/code], [code]direct[/code], [code]webrtc[/code]). Absent
## means relay-only upstream, even on [code]/v3/ws[/code]. Always include
## [code]relay[/code] so the connection keeps the universal relay floor.
@export var supported_transports: PackedStringArray = PackedStringArray()

## Session topologies this client can participate in, as wire tokens
## ([code]relay[/code], [code]host[/code], [code]mesh[/code]). Absent means
## relay-only upstream.
@export var supported_topologies: PackedStringArray = PackedStringArray()

## Additive protocol capability tokens the client is prepared to use (e.g.
## [code]room_operation_ids[/code]). A requested token may be used only after
## the server echoes it in [code]ProtocolInfo.capabilities[/code].
@export var requested_capabilities: PackedStringArray = PackedStringArray()

## Tenant credential sent as the [code]connect_token[/code] field of
## [code]Authenticate[/code] (upstream [code]sfct_v1.[/code] Ed25519 tenant
## token, rust SDK 0.14.0). Empty = omitted from the wire.
## Deliberately NOT an [code]@export[/code]: secrets must be set in code only,
## so the Resource pipeline (.tres/.tscn saves) can never persist it, and it is
## excluded from [method _to_string] and redacted by the logger (issue #33).
var credential: String = ""


func _to_string() -> String:
	var fields := PackedStringArray()
	fields.append("app_id=%s" % app_id)
	fields.append("endpoint_url=%s" % endpoint_url)
	fields.append("game_data_format=%s" % game_data_format)
	fields.append("max_inbound_frame_bytes=%d" % max_inbound_frame_bytes)
	fields.append("max_buffered_bytes=%d" % max_buffered_bytes)
	fields.append("max_inbound_packets_per_poll=%d" % max_inbound_packets_per_poll)
	return "<%s %s>" % [get_class(), " ".join(fields)]


func validation_error() -> String:
	if app_id.is_empty():
		return "app_id is required"
	if not game_data_format.is_empty():
		var format_error := _game_data_format_error()
		if not format_error.is_empty():
			return format_error
	for cap: Array in [
		["max_inbound_frame_bytes", max_inbound_frame_bytes],
		["max_buffered_bytes", max_buffered_bytes],
		["max_inbound_packets_per_poll", max_inbound_packets_per_poll],
		["reconnect_max_attempts", reconnect_max_attempts],
	]:
		if cap[1] <= 0:
			return "%s must be positive" % cap[0]
	if heartbeat_interval_sec < 0.0:
		return "heartbeat_interval_sec must not be negative"
	if heartbeat_interval_sec > 0.0 and pong_timeout_sec <= 0.0:
		return "pong_timeout_sec must be positive when the heartbeat is on"
	return _v3_capabilities_error()


func _v3_capabilities_error() -> String:
	if protocol_version < 0 or protocol_version > SFSessionTypesScript.U16_MAX:
		return "protocol_version must be in range 0..%d" % SFSessionTypesScript.U16_MAX
	for token: String in supported_transports:
		if (
			SFSessionTypesScript.transport_kind_from_string(token)
			== SFSessionTypesScript.TransportKind.UNKNOWN
		):
			return "supported_transports contains an unknown token: %s" % token
	for token: String in supported_topologies:
		if (
			SFSessionTypesScript.topology_from_string(token)
			== SFSessionTypesScript.Topology.UNKNOWN
		):
			return "supported_topologies contains an unknown token: %s" % token
	for token: String in requested_capabilities:
		if token.is_empty():
			return "requested_capabilities must not contain empty strings"
	return ""


func _game_data_format_error() -> String:
	var encoding := SFTypesScript.game_data_encoding_from_string(game_data_format)
	if encoding == SFTypesScript.GameDataEncoding.UNKNOWN:
		return "game_data_format is unknown: %s" % game_data_format
	return ""
