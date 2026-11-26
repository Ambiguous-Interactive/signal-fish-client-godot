class_name SFBinaryGameData
extends RefCounted

const SFBinaryFramesScript = preload("res://addons/signal_fish/protocol/sf_binary_frames.gd")
const SFGameDataFormatScript = preload("res://addons/signal_fish/protocol/sf_game_data_format.gd")
const SFMsgpackScript = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

const _BROADCAST_OPCODE := 0
const _ADDRESSED_OPCODE := 1
const _BINARY_FORMATS: Array[int] = [
	SFTypesScript.GameDataEncoding.MESSAGE_PACK,
	SFTypesScript.GameDataEncoding.RKYV,
	SFTypesScript.GameDataEncoding.PROTOBUF,
]


static func supports_encoding(encoding: int) -> bool:
	return encoding in _BINARY_FORMATS


static func send_format_error(action: String, encoding: int, protocol_version: int) -> String:
	if not supports_encoding(encoding):
		return (
			(
				"%s requires a binary game_data_format (message_pack, rkyv, or protobuf);"
				+ " this connection negotiates %s"
			)
			% [action, SFGameDataFormatScript.label(encoding)]
		)
	if encoding != SFTypesScript.GameDataEncoding.MESSAGE_PACK and protocol_version < 3:
		return (
			"%s game data requires protocol version 3; no v3 negotiation seen"
			% SFGameDataFormatScript.label(encoding)
		)
	return ""


static func frame_size(
	bytes: PackedByteArray, recipient: PackedByteArray, use_carrier: bool
) -> int:
	return bytes.size() + (1 + recipient.size() if use_carrier else 0)


static func encode(
	bytes: PackedByteArray, recipient: PackedByteArray, use_carrier: bool
) -> PackedByteArray:
	if not use_carrier:
		return bytes
	var opcode := _BROADCAST_OPCODE if recipient.is_empty() else _ADDRESSED_OPCODE
	var frame := PackedByteArray([opcode])
	frame.append_array(recipient)
	frame.append_array(bytes)
	return frame


static func decode(
	payload: PackedByteArray, encoding: int, allow_addressed: bool, decode_msgpack: bool
) -> Dictionary:
	if not supports_encoding(encoding):
		return {
			"ok": false,
			"error":
			(
				"binary frame on a %s-negotiated connection; dropped"
				% SFGameDataFormatScript.label(encoding)
			),
		}
	# Ordinary binary data begins with a MessagePack map marker.
	var addressed := not payload.is_empty() and payload[0] == _ADDRESSED_OPCODE
	if addressed and not allow_addressed:
		return {"ok": false, "error": "addressed binary game data is unavailable"}
	var frame := SFBinaryFramesScript.decode_envelope(payload, 1 if addressed else 0)
	if not frame["ok"]:
		return frame
	var bytes: PackedByteArray = frame["payload"]
	if addressed and (frame["version"] != 3 or frame["encoding"] != encoding or bytes.is_empty()):
		return {"ok": false, "error": "invalid addressed binary game data"}
	if decode_msgpack and frame["encoding"] == SFTypesScript.GameDataEncoding.MESSAGE_PACK:
		var decoded := SFMsgpackScript.decode(bytes)
		if decoded["ok"]:
			frame["value"] = decoded["value"]
		else:
			frame["warning"] = (
				"message_pack payload decode failed (%s); surfacing raw bytes" % decoded["error"]
			)
	return frame
