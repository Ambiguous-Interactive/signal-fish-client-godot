class_name SFDiagnostics
extends RefCounted

## Safe rendering of hostile wire-derived keys in refusal diagnostics
## (issue #279). Refusal text reaches the [code]protocol_error[/code]
## signal and the debug log, so each rendered key is capped at 32
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


static func _escape_controls(text: String) -> String:
	var safe := ""
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code <= 0x1F or (code >= 0x7F and code <= 0x9F):
			safe += "\\x%02X" % code
		else:
			safe += String.chr(code)
	return safe
