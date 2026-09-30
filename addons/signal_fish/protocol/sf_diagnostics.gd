class_name SFDiagnostics
extends RefCounted

const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")

## Safe rendering of hostile wire-derived text in diagnostics (issues
## #279, #282). Refusal text reaches the [code]protocol_error[/code]
## signal and the debug log, and transport close reasons and failure
## text reach the info log, so each rendered token is capped at 32
## characters before escaping, and control characters (C0, C1, DEL)
## render as [code]\xNN[/code] escapes: a hostile peer can neither flood
## a log line with a huge key nor forge log lines with embedded newlines.

const MAX_REPORTED_KEY_CHARS := 32

## A wire-derived list renders at most this many items in one diagnostic
## line; longer lists collapse into a trailing "and N more" entry.
const MAX_REPORTED_LIST_ITEMS := 8

## Id-shaped tokens (session generation, peer id) cap at the canonical
## UUID width: legit ids render untouched, while self-inflicted
## over-long or control-laden ids through the public constructors stay
## bounded like any wire-derived token (issue #287).
const MAX_REPORTED_ID_CHARS := 36


## Renders a wire-derived key as a bounded, single-line quoted token.
static func render_key(key: String) -> String:
	var shown := key
	if shown.length() > MAX_REPORTED_KEY_CHARS:
		shown = shown.substr(0, MAX_REPORTED_KEY_CHARS)
	return '"%s"' % _escape_controls(shown)


## Caps a rendered wire-derived list so one diagnostic line cannot be
## stretched by a hostile peer sending thousands of entries (issue #284).
## Returns the caller's array unchanged when already within the cap.
## Items stay raw: free-text members need per-item bounding, see
## [method bound_item]; id-shaped members, see [method bound_id].
static func bound_items(items: PackedStringArray) -> PackedStringArray:
	if items.size() <= MAX_REPORTED_LIST_ITEMS:
		return items
	var shown := items.slice(0, MAX_REPORTED_LIST_ITEMS)
	shown.append("and %d more" % (items.size() - MAX_REPORTED_LIST_ITEMS))
	return shown


## Bounds one free-text wire-derived item (issue #286): capped like
## [method render_key] and control-escaped, but unquoted so in-bounds
## items keep the plain repr the legit-traffic vectors pin.
static func bound_item(text: String) -> String:
	return _escape_controls(text.substr(0, MAX_REPORTED_KEY_CHARS))


## Bounds one id-shaped token (issue #287): capped at the canonical UUID
## width and control-escaped, but unquoted so canonical 36-char ids keep
## the plain repr the legit-traffic vectors pin.
static func bound_id(text: String) -> String:
	return _escape_controls(text.substr(0, MAX_REPORTED_ID_CHARS))


## Renders a composite failure text where only the detail after the
## first ": " is wire-derived: the locally generated prefix stays
## readable (escape-only), and the detail is bounded like a key
## (issue #282). Text without a ": " separator is code-owned, so it
## stays whole and escape-only. The split anchors on the raw text
## before redaction: a secret that spans the separator must not
## unbind the bounded tail.
static func render_failure(
	text: String, secrets: PackedStringArray = PackedStringArray()
) -> String:
	var split := text.find(": ")
	if split == -1:
		return _escape_controls(SFLogScript.redact(text, secrets))
	return (
		"%s: %s"
		% [
			_escape_controls(SFLogScript.redact(text.substr(0, split), secrets)),
			render_key(SFLogScript.redact(text.substr(split + 2), secrets)),
		]
	)


static func _escape_controls(text: String) -> String:
	var safe := ""
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code <= 0x1F or (code >= 0x7F and code <= 0x9F):
			safe += "\\x%02X" % code
		else:
			safe += String.chr(code)
	return safe
