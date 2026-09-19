class_name SFLog
extends RefCounted

## Leveled logger with secret redaction (PLAN §12, issue #15). The client
## routes its diagnostics through this class so tokens and credentials never
## reach stdout/stderr, and early adopters do not grow [code]print()[/code]
## habits around payloads that will carry secrets once reconnection lands.

enum Level { DEBUG, INFO, WARN, ERROR, OFF }

const REDACTED := "[REDACTED]"

static var min_level: int = Level.WARN


static func debug(message: String, secrets: PackedStringArray = PackedStringArray()) -> void:
	_log(Level.DEBUG, message, secrets)


static func info(message: String, secrets: PackedStringArray = PackedStringArray()) -> void:
	_log(Level.INFO, message, secrets)


static func warn(message: String, secrets: PackedStringArray = PackedStringArray()) -> void:
	_log(Level.WARN, message, secrets)


static func error(message: String, secrets: PackedStringArray = PackedStringArray()) -> void:
	_log(Level.ERROR, message, secrets)


## Replaces every non-empty secret occurrence with [constant REDACTED].
static func redact(message: String, secrets: PackedStringArray = PackedStringArray()) -> String:
	var result := message
	for secret: String in secrets:
		if not secret.is_empty():
			result = result.replace(secret, REDACTED)
	return result


static func _log(level: int, message: String, secrets: PackedStringArray) -> void:
	if level < min_level or level >= Level.OFF:
		return
	var line := "[signal_fish] %s" % redact(message, secrets)
	if level >= Level.ERROR:
		printerr(line)
	else:
		print(line)
