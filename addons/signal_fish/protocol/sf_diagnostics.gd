class_name SFDiagnostics
extends RefCounted

## Safe rendering of hostile wire-derived text in diagnostics (issues
## #279, #282). Refusal text reaches the [code]protocol_error[/code]
## signal and the debug log, and transport close reasons and failure
## text reach the info log, so each rendered token is capped at 32
## characters before escaping, and control characters (C0, C1, DEL)
## render as [code]\xNN[/code] escapes: a hostile peer can neither flood
## a log line with a huge key nor forge log lines with embedded newlines.

const MAX_REPORTED_KEY_CHARS := 32


## Renders a wire-derived key as a bounded, single-line quoted token.
static func render_key(key: String) -> String:
	var shown := key
	if shown.length() > MAX_REPORTED_KEY_CHARS:
		shown = shown.substr(0, MAX_REPORTED_KEY_CHARS)
	return '"%s"' % _escape_controls(shown)


## Renders a composite failure text where only the detail after the
## first ": " is wire-derived: the locally generated prefix stays
## readable (escape-only), and the detail is bounded like a key
## (issue #282). Text without a ": " separator is code-owned, so it
## stays whole and escape-only.
static func render_failure(text: String) -> String:
	var split := text.find(": ")
	if split == -1:
		return _escape_controls(text)
	return "%s: %s" % [_escape_controls(text.substr(0, split)), render_key(text.substr(split + 2))]


static func _escape_controls(text: String) -> String:
	var safe := ""
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code <= 0x1F or (code >= 0x7F and code <= 0x9F):
			safe += "\\x%02X" % code
		else:
			safe += String.chr(code)
	return safe
