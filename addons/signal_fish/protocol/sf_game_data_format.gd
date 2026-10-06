class_name SFGameDataFormat
extends RefCounted

## Pure game-data-format negotiation rules (PLAN §4.6). The client owns the
## state mutation and logging; this class owns the decisions so they stay
## unit-testable and anchored to upstream behavior (server
## `websocket/connection.rs` downgrades unsupported preferences to JSON).

const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFDiagnosticsScript = preload("res://addons/signal_fish/protocol/sf_diagnostics.gd")

## The encodings the client refuses below v3: `message_pack` keeps the v2
## three-field map with sender attribution, while `rkyv`/`protobuf` relay as
## raw unattributed bytes on v2, which the attributed receive API cannot
## surface (server `docs/protocol.md`, issue #627).
const _OPAQUE_V3_ENCODINGS: Array[int] = [
	SFTypesScript.GameDataEncoding.RKYV,
	SFTypesScript.GameDataEncoding.PROTOBUF,
]


## The requested format drives the wire until the server says otherwise: an
## unsupported preference is downgraded to JSON at Authenticate (an
## `Error{UnsupportedGameDataFormat}` event and/or absence from
## `ProtocolInfo.game_data_formats`).
static func negotiated(config_format: String, effective: int) -> int:
	if effective != SFTypesScript.GameDataEncoding.UNKNOWN:
		return effective
	return SFTypesScript.game_data_encoding_from_string(config_format)


## Returns the downgrade reason when the negotiated opaque encoding cannot run
## on the negotiated protocol version, or "" when it can. The opaque wire
## shapes are v3-only: a v2 negotiation carries no sender attribution (rust
## client `negotiated_version_from`, server issue #627), so `rkyv`/`protobuf`
## requests must fall back to JSON the way an unadvertised format does.
## ProtocolInfo omits `protocol_version` exactly when the server negotiates
## v2 (frozen v2 wire shape), so every value below 3 is a v2 statement and
## the diagnostic names v2 like the rust client does.
static func version_downgrade_reason(encoding: int, protocol_version: int) -> String:
	if encoding in _OPAQUE_V3_ENCODINGS and protocol_version < 3:
		return (
			"%s game data requires protocol version 3; the server negotiated v2" % label(encoding)
		)
	return ""


## Wire label used in diagnostics; UNKNOWN means "server-default json".
static func label(encoding: int) -> String:
	if encoding == SFTypesScript.GameDataEncoding.UNKNOWN:
		return "server-default json"
	return SFTypesScript.game_data_encoding_to_string(encoding)


## Returns the downgrade reason when the server's supported-format statement
## contradicts the requested binary preference, or "" when the preference can
## stand. An empty statement means "no server opinion": keep the preference.
## Formats are rendered as wire tokens, not coerced enum ints, so the
## diagnostic stays readable (unknown tokens surface as "unknown"), and the
## rendered list is count-bounded with each free-text item bounded like a
## key, so a hostile statement cannot stretch one WARN line
## (issues #284, #286).
static func downgrade_reason(config_format: String, supported_formats: Array) -> String:
	if supported_formats.is_empty():
		return ""
	var requested := SFTypesScript.game_data_encoding_from_string(config_format)
	if requested == SFTypesScript.GameDataEncoding.UNKNOWN:
		return ""
	if requested == SFTypesScript.GameDataEncoding.JSON:
		return ""
	if requested in supported_formats:
		return ""
	var labels := PackedStringArray()
	for value: Variant in supported_formats:
		match typeof(value):
			TYPE_INT:
				var encoding: int = value
				labels.append(SFTypesScript.game_data_encoding_to_string(encoding))
			TYPE_STRING:
				var token: String = value
				labels.append(SFDiagnosticsScript.bound_item(token))
			_:
				labels.append(SFDiagnosticsScript.bound_item(str(value)))
	var shown := SFDiagnosticsScript.bound_items(labels)
	return "server game_data_formats [%s] does not include the requested format" % ", ".join(shown)
