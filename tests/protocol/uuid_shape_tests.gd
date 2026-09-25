extends RefCounted

## Issues #149/#151: wire identifiers are upstream `uuid::Uuid` values
## (`PlayerId`, `RoomId`, `SessionGeneration`). On the text path a present
## identifier must be canonical lowercase hyphenated UUID text: the empty
## string collided with the retired negotiated-rkyv "" sender-unknowable
## sentinel (issue #149), and no other serde spelling (simple, braced, urn,
## uppercase) is wire-reachable (issue #151) - upstream serializes `Uuid` in
## exactly that one form, and its own text-path precedent
## (`canonical_room_operation_id`) refuses everything else. The binary path
## already enforces the 16-byte UUID and formats it to the same string.
## Wire-null/absent optionals keep their "" sentinels; free-text fields stay
## pass-through.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array = []
var _test_done := false


func _done() -> void:
	_test_done = true


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_uuid_text_shape,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## Data-driven: every identifier surface refuses off-contract UUID text, the
## optional-id sentinels survive, and canonical ids decode verbatim.
func _test_uuid_text_shape() -> void:
	# Issues #149/#151: identifier fields are upstream UUIDs (`PlayerId`,
	# `RoomId`, `SessionGeneration`), so a present id must be canonical
	# lowercase hyphenated UUID text: empty collided with the retired
	# negotiated-rkyv "" sender-unknowable sentinel, and no other serde
	# spelling is wire-reachable. Free-text fields stay pass-through.
	# Cases: [label, envelope type, data].
	var empty_id_cases := [
		["game data empty from_player", "GameData", {"from_player": "", "data": {}}],
		[
			"binary game data empty from_player",
			"GameDataBinary",
			{"from_player": "", "encoding": "message_pack", "payload": "yv4"}
		],
		["player left empty id", "PlayerLeft", {"player_id": ""}],
		["player reconnected empty id", "PlayerReconnected", {"player_id": ""}],
		["new peer empty id", "NewPeer", {"peer_id": "", "you_initiate": true}],
		[
			"peer transport status empty id",
			"PeerTransportStatus",
			{"peer_id": "", "transport": "relay", "connected": true}
		],
		["spectator disconnected empty id", "SpectatorDisconnected", {"spectator_id": ""}],
		["signal empty from", "Signal", {"from": "", "signal": {}}],
		[
			"signal empty generation",
			"Signal",
			{"from": "10000000-0000-0000-0000-000000000001", "generation": "", "signal": {}}
		],
		[
			"authority changed empty authority",
			"AuthorityChanged",
			{"authority_player": "", "you_are_authority": false}
		],
		[
			"spectator left empty room id",
			"SpectatorLeft",
			{"room_id": "", "room_code": "RC", "reason": "room_closed"}
		],
		[
			"lobby ready players empty id",
			"LobbyStateChanged",
			{"lobby_state": "waiting", "ready_players": [""], "all_ready": false}
		],
		[
			"room joined empty room id",
			"RoomJoined",
			_with_overrides(_minimal_room_joined_data(), {"room_id": ""})
		],
		[
			"room joined empty player id",
			"RoomJoined",
			_with_overrides(_minimal_room_joined_data(), {"player_id": ""})
		],
		[
			"ready players empty entry",
			"RoomJoined",
			_with_overrides(_minimal_room_joined_data(), {"ready_players": [""]})
		],
		[
			"player joined empty id",
			"PlayerJoined",
			{"player": _with_overrides(_minimal_player_data(), {"id": ""})}
		],
		[
			"spectator joined empty id",
			"SpectatorJoined",
			_with_overrides(_minimal_spectator_joined_data(), {"spectator_id": ""})
		],
		[
			"spectator joined empty room id",
			"SpectatorJoined",
			_with_overrides(_minimal_spectator_joined_data(), {"room_id": ""})
		],
		[
			"new spectator empty id",
			"NewSpectatorJoined",
			{"spectator": _with_overrides(_minimal_spectator_data(), {"id": ""})}
		],
		[
			"game starting empty peer id",
			"GameStarting",
			{"peer_connections": [_peer_connection({"player_id": ""})]}
		],
		[
			"session plan empty generation",
			"SessionPlan",
			_minimal_session_plan_data({"generation": ""})
		],
		["session plan empty host", "SessionPlan", _minimal_session_plan_data({"host": ""})],
		[
			"session plan empty peer id",
			"SessionPlan",
			_minimal_session_plan_data(
				{
					"topology": "mesh",
					"transport": "webrtc",
					"peers":
					[{"player_id": "", "player_name": "P", "is_authority": false, "initiate": true}]
				}
			)
		],
		[
			"reconnect watermark empty id",
			"Reconnected",
			_with_overrides(
				_minimal_room_joined_data(),
				{
					"missed_events": [],
					"sender_watermarks": [{"player_id": "", "epoch": 1, "seq": 1}]
				}
			)
		],
		["game data non-uuid from_player", "GameData", {"from_player": "not-a-uuid", "data": {}}],
		[
			"game data uppercase from_player",
			"GameData",
			{"from_player": "10000000-0000-0000-0000-00000000000A", "data": {}}
		],
		[
			"binary game data braced from_player",
			"GameDataBinary",
			{
				"from_player": "{10000000-0000-0000-0000-000000000001}",
				"encoding": "message_pack",
				"payload": "yv4"
			}
		],
		[
			"player left short id",
			"PlayerLeft",
			{"player_id": "10000000-0000-0000-0000-00000000001"}
		],
		[
			"player left simple spelling",
			"PlayerLeft",
			{"player_id": "10000000000000000000000000000001"}
		],
		[
			"player left shifted hyphens",
			"PlayerLeft",
			{"player_id": "100000000-0000-0000-0000-00000000001"}
		],
		[
			"signal urn generation",
			"Signal",
			{
				"from": "10000000-0000-0000-0000-000000000001",
				"generation": "urn:uuid:40000000-0000-0000-0000-000000000001",
				"signal": {}
			}
		],
		[
			"ready players one bad entry",
			"LobbyStateChanged",
			{
				"lobby_state": "waiting",
				"ready_players": ["10000000-0000-0000-0000-000000000001", "p1"],
				"all_ready": false
			}
		],
		[
			"room joined uppercase room id",
			"RoomJoined",
			_with_overrides(
				_minimal_room_joined_data(), {"room_id": "2ABCDEF0-0000-0000-0000-000000000001"}
			)
		],
		[
			"session plan urn generation",
			"SessionPlan",
			_minimal_session_plan_data(
				{"generation": "urn:uuid:40000000-0000-0000-0000-000000000001"}
			)
		],
		[
			"session plan peer simple id",
			"SessionPlan",
			_minimal_session_plan_data(
				{
					"topology": "mesh",
					"transport": "webrtc",
					"peers":
					[
						{
							"player_id": "10000000000000000000000000000001",
							"player_name": "P",
							"is_authority": false,
							"initiate": true
						}
					]
				}
			)
		],
		[
			"reconnect watermark uppercase id",
			"Reconnected",
			_with_overrides(
				_minimal_room_joined_data(),
				{
					"missed_events": [],
					"sender_watermarks":
					[{"player_id": "1000000A-0000-0000-0000-000000000001", "epoch": 1, "seq": 1}]
				}
			)
		],
	]
	for test_case: Array in empty_id_cases:
		var data: Dictionary = test_case[2]
		var label: String = test_case[0]
		var decoded: SFTypesScript.DecodedEvent = _assert_protocol_error_envelope(
			{"type": test_case[1], "data": data}, label
		)
		_assert_string_contains(
			str(decoded.args[0]), "lowercase hyphenated UUID", "%s gate message" % label
		)

	# No false positives: wire-null optionals keep their "" sentinels, and
	# free-text fields still pass empty strings through.
	var null_authority: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "AuthorityChanged", "data": {"authority_player": null, "you_are_authority": false}}
	)
	if _assert_equal(
		"authority_changed", String(null_authority.signal_name), "null authority decodes"
	):
		_assert_equal("", null_authority.args[0], "null authority keeps empty sentinel")
	var absent_generation: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Signal", "data": {"from": "10000000-0000-0000-0000-000000000001", "signal": {}}}
	)
	if _assert_equal(
		"signal_received", String(absent_generation.signal_name), "absent generation decodes"
	):
		_assert_equal("", absent_generation.args[1], "absent generation keeps empty sentinel")
	var empty_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "RoomJoinFailed", "data": {"reason": ""}}
	)
	if _assert_equal(
		"room_join_failed", String(empty_reason.signal_name), "empty reason is free text"
	):
		_assert_equal("", empty_reason.args[0], "empty reason passes through verbatim")
	var null_spectator_room: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorLeft", "data": {"room_id": null}}
	)
	if _assert_equal(
		"spectator_left", String(null_spectator_room.signal_name), "null spectator room decodes"
	):
		_assert_equal("", null_spectator_room.args[0], "null spectator room keeps empty sentinel")
	# Canonical ids decode verbatim (issue #151 positives).
	var canonical_game_data: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "GameData",
			"data": {"from_player": "10000000-0000-0000-0000-000000000001", "data": {}}
		}
	)
	if _assert_equal(
		"game_data_received", String(canonical_game_data.signal_name), "canonical sender decodes"
	):
		_assert_equal(
			"10000000-0000-0000-0000-000000000001",
			canonical_game_data.args[0],
			"canonical sender verbatim"
		)
	var canonical_signal: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "Signal",
			"data":
			{
				"from": "10000000-0000-0000-0000-000000000001",
				"generation": "40000000-0000-0000-0000-000000000001",
				"signal": {}
			}
		}
	)
	if _assert_equal(
		"signal_received", String(canonical_signal.signal_name), "canonical signal decodes"
	):
		_assert_equal(
			"10000000-0000-0000-0000-000000000001",
			canonical_signal.args[0],
			"canonical from verbatim"
		)
		_assert_equal(
			"40000000-0000-0000-0000-000000000001",
			canonical_signal.args[1],
			"canonical generation verbatim"
		)
	var canonical_ready: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "LobbyStateChanged",
			"data":
			{
				"lobby_state": "waiting",
				"ready_players": ["10000000-0000-0000-0000-000000000001"],
				"all_ready": false
			}
		}
	)
	if _assert_equal(
		"lobby_state_changed", String(canonical_ready.signal_name), "canonical ready decodes"
	):
		_assert_equal(
			PackedStringArray(["10000000-0000-0000-0000-000000000001"]),
			canonical_ready.args[1],
			"canonical ready verbatim"
		)
	# The outbound builders gate the same shape symmetrically (issue #151):
	# reconnect and peer_signal refuse non-UUID ids, canonical ids encode,
	# and the legacy "" generation sentinel still omits the field.
	var outbound_refusals := [
		[
			"reconnect uppercase player",
			SFMessagesScript.reconnect(
				"1ABCDEF0-0000-0000-0000-000000000001",
				"20000000-0000-0000-0000-000000000001",
				"tok-not-secret"
			)
		],
		[
			"reconnect braced room",
			SFMessagesScript.reconnect(
				"10000000-0000-0000-0000-000000000001",
				"{20000000-0000-0000-0000-000000000001}",
				"tok-not-secret"
			)
		],
		[
			"reconnect placeholder player",
			SFMessagesScript.reconnect(
				"p1", "20000000-0000-0000-0000-000000000001", "tok-not-secret"
			)
		],
		[
			"peer_signal placeholder to",
			SFMessagesScript.peer_signal(
				"peer-b", "40000000-0000-0000-0000-000000000001", {"Offer": "s"}
			)
		],
		[
			"peer_signal urn generation",
			SFMessagesScript.peer_signal(
				"10000000-0000-0000-0000-000000000001",
				"urn:uuid:40000000-0000-0000-0000-000000000001",
				{"Offer": "s"}
			)
		],
		[
			"peer_signal int generation",
			SFMessagesScript.peer_signal("10000000-0000-0000-0000-000000000001", 7, {"Offer": "s"})
		],
	]
	for refusal: Array in outbound_refusals:
		var envelope: Dictionary = refusal[1]
		_assert(not SFMessagesScript.is_valid_message(envelope), "%s is refused" % refusal[0])
		_assert_string_contains(
			SFMessagesScript.validation_error(envelope),
			"lowercase hyphenated UUID",
			"%s gate message" % refusal[0]
		)
	var canonical_reconnect := SFMessagesScript.reconnect(
		"10000000-0000-0000-0000-000000000001",
		"20000000-0000-0000-0000-000000000001",
		"tok-not-secret"
	)
	_assert_valid_message(canonical_reconnect, "canonical reconnect encodes")
	var canonical_peer_signal := SFMessagesScript.peer_signal(
		"10000000-0000-0000-0000-000000000001",
		"40000000-0000-0000-0000-000000000001",
		{"Offer": "s"}
	)
	_assert_valid_message(canonical_peer_signal, "canonical peer_signal encodes")
	var legacy_generation := SFMessagesScript.peer_signal(
		"10000000-0000-0000-0000-000000000001", "", {"Offer": "s"}
	)
	if _assert(
		SFMessagesScript.is_valid_message(legacy_generation), "legacy empty generation stays valid"
	):
		_assert(
			not SFMessagesScript.encode(legacy_generation).contains("generation"),
			"legacy empty generation omits the field"
		)
	_done()


func _minimal_session_plan_data(overrides: Dictionary = {}) -> Dictionary:
	var data := {
		"generation": "40000000-0000-0000-0000-000000000001",
		"topology": "relay",
		"transport": "relay",
		"peers": [],
		"fallback": "relay"
	}
	return _with_overrides(data, overrides)


func _minimal_room_joined_data() -> Dictionary:
	return {
		"room_id": "20000000-0000-0000-0000-000000000001",
		"room_code": "ABC123",
		"player_id": "10000000-0000-0000-0000-000000000001",
		"game_name": "reef-rally",
		"max_players": 4,
		"supports_authority": false,
		"current_players": [],
		"is_authority": false,
		"lobby_state": "waiting",
		"ready_players": [],
		"relay_type": "websocket"
	}


func _minimal_player_data() -> Dictionary:
	return {
		"id": "10000000-0000-0000-0000-000000000001",
		"name": "Alice",
		"is_authority": false,
		"is_ready": false,
		"connected_at": "now"
	}


func _minimal_spectator_joined_data() -> Dictionary:
	return {
		"room_id": "20000000-0000-0000-0000-000000000001",
		"room_code": "ABC123",
		"spectator_id": "30000000-0000-0000-0000-000000000001",
		"game_name": "reef-rally",
		"current_players": [],
		"current_spectators": [],
		"lobby_state": "waiting"
	}


func _minimal_spectator_data() -> Dictionary:
	return {"id": "30000000-0000-0000-0000-000000000001", "name": "Watcher", "connected_at": "now"}


func _peer_connection(overrides: Dictionary) -> Dictionary:
	return _with_overrides(
		{
			"player_id": "10000000-0000-0000-0000-000000000001",
			"player_name": "Alice",
			"is_authority": false,
			"relay_type": "regional-relay"
		},
		overrides
	)


func _with_overrides(data: Dictionary, overrides: Dictionary) -> Dictionary:
	for key: Variant in overrides:
		data[key] = overrides[key]
	return data


func _assert_protocol_error_envelope(envelope: Dictionary, label: String) -> RefCounted:
	var decoded := SFEventsScript.decode_envelope(envelope)
	_assert_protocol_error(decoded, "%s envelope=%s" % [label, var_to_str(envelope)])
	return decoded


func _assert_protocol_error(decoded: RefCounted, label: String) -> bool:
	if decoded == null:
		_failures.append("%s: expected protocol_error, got <null decoded event>" % label)
		return false
	var event: SFTypesScript.DecodedEvent = decoded
	if not _assert_equal("protocol_error", String(event.signal_name), label):
		return false
	if not _assert_equal(1, event.args.size(), "%s protocol_error args" % label):
		return false
	return _assert(
		typeof(event.args[0]) == TYPE_STRING and not str(event.args[0]).is_empty(),
		"%s protocol_error message must be non-empty" % label
	)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected != actual:
		var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
		var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
		_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
		return false
	return true


func _assert_valid_message(envelope: Dictionary, label: String) -> bool:
	return _assert(SFMessagesScript.is_valid_message(envelope), "%s should be valid" % label)


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


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append(label)
		return false
	return true
