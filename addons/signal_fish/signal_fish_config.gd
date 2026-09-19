class_name SignalFishConfig
extends Resource

## Connection settings for [SignalFishClient]. Author as a Resource in the
## editor or build in code, then pass to [method SignalFishClient.configure].
##
## ## Credential hygiene (PLAN §12)
## [member credential] reserves API space for the upstream secret-key decision
## (issue #14): it is carried as a value only — never stitched into URLs,
## never included in [method _to_string], and redacted by
## [code]sf_log.gd[/code] when the client logs. Do not save a config
## Resource containing a credential to a committed file.

const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

## Public application identifier. Safe to ship in game builds.
@export var app_id: String = ""

## Optional SDK version reported to the server. Empty = omitted from the wire.
@export var sdk_version: String = ""

## Optional platform identifier reported to the server. Empty = omitted.
@export var platform: String = ""

## Game data format preference. Until binary game-data decode ships (PLAN P2),
## only [code]json[/code] (or empty = server-default JSON) is accepted: asking
## for [code]message_pack[/code]/[code]rkyv[/code] would make the server send
## binary frames this client cannot decode yet.
@export var game_data_format: String = ""

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

## Reserved slot for a secret credential (e.g. an [code]sfk_*[/code] app key)
## should upstream move to secret-based authentication. Empty = unset.
## Deliberately NOT an [code]@export[/code]: secrets must be set in code only,
## so the Resource pipeline (.tres/.tscn saves) can never persist it, and it is
## excluded from [method _to_string] and redacted by the logger (issue #14).
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
	return ""


func _game_data_format_error() -> String:
	var encoding := SFTypesScript.game_data_encoding_from_string(game_data_format)
	if encoding == SFTypesScript.GameDataEncoding.UNKNOWN:
		return "game_data_format is unknown: %s" % game_data_format
	if encoding != SFTypesScript.GameDataEncoding.JSON:
		return (
			(
				"game_data_format %s is reserved for the P2 binary game-data milestone;"
				+ " the client cannot decode binary frames yet"
			)
			% game_data_format
		)
	return ""
