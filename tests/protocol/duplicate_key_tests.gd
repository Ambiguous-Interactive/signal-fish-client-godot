extends RefCounted

## Issue #92: Godot's JSON parser is last-wins on duplicate keys, so a
## repeated key used to silently substitute envelope fields — the real
## event vanished, a smuggled RoomLeft wiped room state, a repeated
## reconnection_token emptied the auto-reconnect identity, and a repeated
## all_ready could force ready-gates open. Upstream (serde) rejects every
## such frame; the text path now fails closed before the engine parse.
## Keys compare after escape decoding, matching serde and the engine's own
## parse, so lookalike spellings are duplicates too, and escaped spellings
## of genuinely different keys never false-positive.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFJsonGuard = preload("res://addons/signal_fish/protocol/sf_json_guard.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

var _failures: Array = []


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_duplicate_key_frames_fail_closed()
	_test_clean_frames_still_decode()
	_test_escape_canonicalization()


func _test_duplicate_key_frames_fail_closed() -> void:
	var hostile := [
		{
			"label": "envelope type substitution",
			"text": '{"type":"GameData","data":{"from_player":"p1","data":{}},"type":"RoomLeft"}',
		},
		{
			"label": "reconnection token wipe",
			"text":
			_room_joined_text_with_suffix(
				',"reconnection_token":"REAL-TOKEN","reconnection_token":""'
			),
		},
		{
			"label": "ready gate forced open",
			"text":
			(
				'{"type":"LobbyStateChanged","data":{"lobby_state":"lobby","ready_players":["p1"],'
				+ '"all_ready":false,"all_ready":true}}'
			),
		},
		{
			"label": "nested payload field",
			"text":
			'{"type":"GameData","data":{"from_player":"p1","data":{"stats":{"hp":1,"hp":9}}}}',
		},
		{
			"label": "duplicate after a 64 KiB string",
			"text":
			(
				'{"type":"GameData","data":{"from_player":"p1","data":{"blob":"%s","k":1,"k":2}}}'
				% "a".repeat(65536)
			),
		},
		{
			"label": "escaped-key lookalike of type",
			"text": '{"type":"Ping","typ\\u0065":"smuggled"}',
		},
		{
			"label": "surrogate-pair key vs literal emoji",
			"text":
			'{"type":"GameData","data":{"from_player":"p1","data":{"\\uD83D\\uDE00":1,"😀":2}}}',
		},
	]
	for case: Dictionary in hostile:
		var text: String = case["text"]
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(text)
		_assert_protocol_error_contains(
			decoded, "duplicate", "duplicate key %s rejected" % case["label"]
		)
	# The engine strips NUL from decoded strings, so a key spelled with a
	# NUL escape merges with its lookalike neighbour (last-wins) even though
	# the scan sees distinct keys. Such keys are refused with their own
	# diagnostic, merged-duplicate class.
	var nul_type_smuggle: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		'{"type":"GameData","data":{"from_player":"p1","data":{}},"typ\\u0000e":"RoomLeft"}'
	)
	_assert_protocol_error_contains(nul_type_smuggle, "NUL", "NUL-escape type smuggle rejected")
	var nul_merged: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		'{"type":"GameData","data":{"from_player":"p1","data":{"h\\u0000p":1,"hp":2}}}'
	)
	_assert_protocol_error_contains(nul_merged, "NUL", "NUL-escape merged keys rejected")
	var nul_guard := SFJsonGuard.duplicate_key_error('{"a\\u0000b":1,"ab":2}')
	_assert_string_contains(nul_guard, "NUL", "NUL key guard diagnostic")


func _test_clean_frames_still_decode() -> void:
	var accepted := [
		{"label": "unit envelope", "text": '{"type":"Pong"}', "signal": "pong"},
		{
			"label": "escapes in values",
			"text":
			(
				'{"type":"GameData","data":{"from_player":"p1","data":{"msg":'
				+ '"quote\\\" backslash\\\\ \\u0041"}}}'
			),
			"signal": "game_data_received",
			"payload_msg": 'quote" backslash\\ A',
		},
		{
			"label": "escaped distinct keys",
			"text": '{"type":"GameData","data":{"from_player":"p1","data":{"\\u0062":1,"b2":2}}}',
			"signal": "game_data_received",
		},
	]
	for case: Dictionary in accepted:
		var text: String = case["text"]
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(text)
		if not _assert_equal(
			case["signal"], String(decoded.signal_name), "%s decodes" % case["label"]
		):
			continue
		if case.has("payload_msg"):
			_assert_equal(
				case["payload_msg"], decoded.args[1]["msg"], "%s value round-trip" % case["label"]
			)


## Direct guard vectors for the escape spellings the engine parser decodes:
## keys differing only in escape notation are the same key (duplicates),
## while escaped spellings of genuinely different keys never false-positive.
func _test_escape_canonicalization() -> void:
	var duplicates := [
		["plain vs unicode escape", '{"k":1,"\\u006b":2}'],
		["simple escape spelling", '{"\\/":1,"/":2}'],
		["surrogate pair vs literal", '{"\\ud83d\\ude00":1,"😀":2}'],
		["empty key twice", '{"":1,"":2}'],
	]
	for case: Array in duplicates:
		var text: String = case[1]
		var error := SFJsonGuard.duplicate_key_error(text)
		if not _assert(not error.is_empty(), "%s reported" % case[0]):
			continue
		_assert_string_contains(error, "duplicate", "%s message" % case[0])
	var clean := [
		["distinct keys, one escaped", '{"\\u0061":1,"b":2}'],
		["same keys in sibling objects", '{"a":{"k":1},"b":{"k":2}}'],
		["key repeated across nesting levels", '{"k":{"k":1}}'],
		["lookalikes inside string values", '{"a":"k","k":1}'],
		["escaped distinct emoji", '{"\\ud83d\\ude00":1,"\\u2728":2}'],
		["invalid escape left to the engine", '{"k":"\\x"}'],
	]
	for case: Array in clean:
		var text: String = case[1]
		_assert_equal("", SFJsonGuard.duplicate_key_error(text), "%s accepted" % case[0])
	var unterminated := SFJsonGuard.duplicate_key_error('{"k":"open')
	_assert_string_contains(unterminated, "unterminated", "unterminated string fails closed")
	var oversized := '{"%s":1,"%s":2}' % ["k".repeat(64), "k".repeat(64)]
	var truncated := SFJsonGuard.duplicate_key_error(oversized)
	_assert_string_contains(truncated, "duplicate", "oversized key still reported")
	_assert(not truncated.contains("k".repeat(64)), "oversized key truncated in diagnostic")


## Emits the minimal RoomJoined baseline as raw wire text, minus its closing
## brace, so duplicate-key vectors can append repeated fields to it.
func _room_joined_text_with_suffix(suffix: String) -> String:
	var body := JSON.stringify(_minimal_room_joined_data())
	return '{"type":"RoomJoined","data":%s%s}' % [body.substr(0, body.length() - 1), suffix]


func _minimal_room_joined_data() -> Dictionary:
	return {
		"room_id": "r1",
		"room_code": "ABC123",
		"player_id": "p1",
		"game_name": "reef-rally",
		"max_players": 4,
		"supports_authority": false,
		"current_players": [],
		"is_authority": false,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket",
	}


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append(label)
		return false
	return true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
		var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
		_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
		return false
	return true


func _assert_string_contains(actual: String, expected_substring: String, label: String) -> bool:
	if actual.find(expected_substring) == -1:
		_failures.append(
			(
				"%s: expected %s to contain %s"
				% [label, var_to_str(actual), var_to_str(expected_substring)]
			)
		)
		return false
	return true


func _assert_protocol_error_contains(
	decoded: RefCounted, expected_substring: String, label: String
) -> bool:
	var event: SFTypesScript.DecodedEvent = decoded
	if not _assert_equal("protocol_error", String(event.signal_name), label):
		return false
	if not _assert_equal(1, event.args.size(), "%s protocol_error args" % label):
		return false
	if typeof(event.args[0]) != TYPE_STRING:
		_failures.append("%s protocol_error message must be a string" % label)
		return false
	var message: String = event.args[0]
	return _assert_string_contains(message, expected_substring, label)
