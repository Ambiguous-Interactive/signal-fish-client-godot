class_name SFJsonGuard
extends RefCounted

## Strict duplicate-key pre-scan for inbound text frames (issue #92).
##
## Godot's JSON parser is last-wins on duplicate object keys, so a hostile
## frame such as [code]{"type":"GameData",...,"type":"RoomLeft"}[/code] used
## to silently substitute the decoded event: the real message vanished, room
## state was wiped, and a repeated [code]reconnection_token[/code] could
## empty the retained auto-reconnect identity. Upstream (serde) rejects every
## such frame, and the binary envelope path already rejects duplicate
## fields — this scan gives the text path the same fail-closed strictness
## before the engine parse runs.
##
## Single linear pass over the frame's UTF-8 bytes. String contents are
## skipped with the native byte search (multi-byte characters never contain
## ASCII quote or backslash bytes), so only object keys — short — are
## decoded per byte. Keys compare after JSON escape decoding —
## [code]"\u0061"[/code] and [code]"a"[/code] are the same string, matching
## serde's unescaped comparison and the engine's own parse — so lookalike
## spellings cannot smuggle a second copy of a key past the guard. The one
## deliberate divergence from serde: a key whose decoded form contains U+0000
## is refused outright, because the engine strips NUL from strings and would
## merge such a key into a lookalike neighbour for a silent last-wins
## overwrite. Unterminated strings fail closed as well; malformed JSON of
## every other class is left to the engine parser — only the duplicate-key
## class (plus unterminated strings and NUL keys) is diagnosed here.
##
## Cost (issue #92 decision gate, Godot 4.3 headless): the guard adds
## ~0.02 ms to a small control frame and ~0.5 ms at the 256 KiB frame-cap
## bound when the frame is string-dense (string content is skipped
## natively). Legal object-dense frames are the expensive shape — 256 KiB of
## ~32700 tiny objects costs ~100 ms, dominated by the per-object key sets,
## which are Dictionary-backed to keep a single-object flood of distinct
## keys linear. Bounded and linear in frame size; typical control frames sit
## orders of magnitude below the cap.

const _MAX_REPORTED_KEY_BYTES := 32


## Returns "" when the frame has no duplicate keys, otherwise a
## protocol-error diagnostic naming the first duplicated key.
static func duplicate_key_error(text: String) -> String:
	var bytes := text.to_utf8_buffer()
	var size := bytes.size()
	var key_sets: Array[Dictionary] = []
	var is_object: Array[bool] = []
	var expect_key := false
	var index := 0
	while index < size:
		var byte := bytes[index]
		if byte == 0x22:  # '"': consume one string atomically
			var close := _close_quote_index(bytes, index + 1)
			if close < 0:
				return "message contains an unterminated JSON string"
			if expect_key:
				var key := _collect_key(bytes, index + 1, close)
				if key.find(0x00) != -1:
					# The engine strips NUL from decoded strings, so a NUL key
					# would merge with a lookalike neighbour (last-wins)
					# despite being distinct to this scan.
					return "message contains a NUL character in a JSON key"
				var keys: Dictionary = key_sets[key_sets.size() - 1]
				if keys.has(key):
					return "message contains duplicate JSON key %s" % _render_key(key)
				keys[key] = true
			index = close + 1
			expect_key = false
			continue
		if byte == 0x7B:  # '{'
			key_sets.append({})
			is_object.append(true)
			expect_key = true
		elif byte == 0x5B:  # '['
			# Arrays never collect keys; the slot only balances the stack.
			key_sets.append({})
			is_object.append(false)
			expect_key = false
		elif byte == 0x7D or byte == 0x5D:  # '}' or ']'
			if not key_sets.is_empty():
				key_sets.pop_back()
				is_object.pop_back()
			expect_key = false
		elif byte == 0x2C:  # ','
			expect_key = not is_object.is_empty() and is_object[is_object.size() - 1]
		elif byte == 0x3A:  # ':'
			expect_key = false
		index += 1
	return ""


## Finds the quote that truly ends a string: a candidate preceded by an odd
## number of backslashes is an escaped quote.
static func _close_quote_index(bytes: PackedByteArray, start: int) -> int:
	var close := bytes.find(0x22, start)
	while close >= 0:
		var backslashes := 0
		var cursor := close - 1
		while cursor >= start and bytes[cursor] == 0x5C:
			backslashes += 1
			cursor -= 1
		if backslashes % 2 == 0:
			return close
		close = bytes.find(0x22, close + 1)
	return -1


## Decodes the key bytes between the quotes into their canonical UTF-8 form.
static func _collect_key(bytes: PackedByteArray, start: int, end: int) -> PackedByteArray:
	var key := PackedByteArray()
	var index := start
	while index < end:
		var byte := bytes[index]
		index += 1
		if byte != 0x5C:  # '\\'
			key.append(byte)
			continue
		if index >= end:
			break
		byte = bytes[index]
		index += 1
		var decoded := _escape_byte(byte)
		if decoded >= 0:
			key.append(decoded)
			continue
		if byte != 0x75:  # 'u'; unknown escapes are engine-parser rejects
			continue
		var code := _hex4(bytes, index, end)
		if code < 0:
			continue
		index += 4
		if (
			code >= 0xD800
			and code <= 0xDBFF
			and index + 1 < end
			and bytes[index] == 0x5C
			and bytes[index + 1] == 0x75
		):
			var low := _hex4(bytes, index + 2, end)
			if low >= 0xDC00 and low <= 0xDFFF:
				code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
				index += 6
		_append_utf8(key, code)
	return key


## Maps one simple escape character to its byte value, or -1 when the escape
## is not a simple one ([code]\uXXXX[/code] and unknown escapes return -1).
static func _escape_byte(byte: int) -> int:
	match byte:
		0x22, 0x5C, 0x2F:
			return byte
		0x62:
			return 0x08
		0x66:
			return 0x0C
		0x6E:
			return 0x0A
		0x72:
			return 0x0D
		0x74:
			return 0x09
		_:
			return -1


## Reads four hex digits, or -1 when they are missing or not hex.
static func _hex4(bytes: PackedByteArray, start: int, size: int) -> int:
	if start + 4 > size:
		return -1
	var value := 0
	for offset: int in 4:
		var digit := bytes[start + offset]
		if digit >= 0x30 and digit <= 0x39:
			value = (value << 4) | (digit - 0x30)
		elif digit >= 0x61 and digit <= 0x66:
			value = (value << 4) | (digit - 0x57)
		elif digit >= 0x41 and digit <= 0x46:
			value = (value << 4) | (digit - 0x37)
		else:
			return -1
	return value


## Appends one code point as UTF-8; out-of-range values become U+FFFD like
## the engine's lenient decode.
static func _append_utf8(key: PackedByteArray, code_point: int) -> void:
	if code_point < 0 or code_point > 0x10FFFF:
		code_point = 0xFFFD
	if code_point < 0x80:
		key.append(code_point)
	elif code_point < 0x800:
		key.append(0xC0 | (code_point >> 6))
		key.append(0x80 | (code_point & 0x3F))
	elif code_point < 0x10000:
		key.append(0xE0 | (code_point >> 12))
		key.append(0x80 | ((code_point >> 6) & 0x3F))
		key.append(0x80 | (code_point & 0x3F))
	else:
		key.append(0xF0 | (code_point >> 18))
		key.append(0x80 | ((code_point >> 12) & 0x3F))
		key.append(0x80 | ((code_point >> 6) & 0x3F))
		key.append(0x80 | (code_point & 0x3F))


## Renders a key for the diagnostic, truncated so a hostile frame cannot
## bloat the log line. Invalid UTF-8 degrades to replacement characters.
static func _render_key(key: PackedByteArray) -> String:
	var shown := key
	if shown.size() > _MAX_REPORTED_KEY_BYTES:
		shown = shown.slice(0, _MAX_REPORTED_KEY_BYTES)
	return '"%s"' % shown.get_string_from_utf8()
