extends RefCounted

## Issues #95/#96: direct construction of the public typed value objects must
## fail closed exactly like the wire-decode validators (issues #81/#89
## policy). Wrong-typed booleans must not launder through bool() — bool(0.5)
## is true — and wrong-typed strings/null raise there, aborting the
## constructor mid-way. Integers int() would collapse (integral floats at or
## beyond 2^63, non-finite magnitudes) must take the field's absent sentinel
## instead of a platform-dependent garbage value.

const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
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
		_test_wrong_typed_bools_take_the_false_sentinel,
		_test_valid_bools_pass_through,
		_test_collapsing_integers_take_the_absent_sentinel,
		_test_representable_integers_pass_through,
		_test_negative_integers_stay_visible,
		_test_laundered_client_id_never_reaches_the_wire_dict,
		_test_wrong_typed_array_entries_round_trip,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## Every constructor bool field, driven over the hostile matrix. The decode
## path refuses each of these shapes outright; direct construction must read
## them as the field's false sentinel, never as a manufactured true. Rows
## whose field has successors also seed a trailing value and assert it
## survives: a hostile string raises under the old bool() code and aborts
## the constructor mid-way, which silently defaults the field anyway — the
## survival check is what pins that abort class (issues #81/#95).
func _test_wrong_typed_bools_take_the_false_sentinel() -> void:
	for site: Array in _bool_sites():
		for hostile: Variant in ["false", "true", "", 1, 0, 0.5, -1, 1.5]:
			var object: Object = _build(site, hostile)
			_assert_equal(
				false, _read(site, object), "%s <- %s launders" % [site[0], _variant_label(hostile)]
			)
			if site[4] == null:
				continue
			var after_field: StringName = site[4]
			_assert_equal(
				site[5],
				object.get(after_field),
				"%s trailing %s survives %s" % [site[0], site[4], _variant_label(hostile)]
			)
	_done()


func _test_valid_bools_pass_through() -> void:
	for site: Array in _bool_sites():
		for honest: Variant in [true, false]:
			_assert_equal(honest, _read(site, _build(site, honest)), "%s honest bool" % site[0])
	_done()


## Every constructor integer field driven over the int()-collapse matrix:
## integral floats at/after 2^63 collapse platform-dependently, non-finite
## and non-numeric input is not an integer at all. Each field reads as its
## documented absent sentinel instead.


func _test_collapsing_integers_take_the_absent_sentinel() -> void:
	var collapsing := [1e30, 9223372036854775808.0, -9223372036854775808.0, NAN, INF, "12", 1.5]
	for site: Array in _int_sites():
		for hostile: Variant in collapsing:
			_assert_equal(
				site[4],
				_read(site, _build(site, hostile)),
				"%s <- %s collapses" % [site[0], _variant_label(hostile)]
			)
	_done()


func _test_representable_integers_pass_through() -> void:
	for site: Array in _int_sites():
		_assert_equal(
			4294967296, _read(site, _build(site, 4294967296.0)), "%s big-but-legal float" % site[0]
		)
		_assert_equal(7, _read(site, _build(site, 7)), "%s plain int" % site[0])
	_done()


## A hostile negative is not the 0 "absent" sentinel: ProtocolInfo versions
## used to clamp it to 0, silently reading as "absent on negotiated v2".


func _test_negative_integers_stay_visible() -> void:
	var info: SFTypesScript.ProtocolInfo = SFTypesScript.ProtocolInfo.new(
		{"protocol_version": -1, "max_outbound_message_size": -1}
	)
	_assert_equal(-1, info.protocol_version, "negative protocol_version stays visible")
	_assert_equal(-1, info.max_outbound_message_size, "negative size cap stays visible")
	_done()


## The #89 relay-slot hazard at constructor level: a collapsed client_id used
## to flow back out through to_dict() as the relay slot on the wire dict.


func _test_laundered_client_id_never_reaches_the_wire_dict() -> void:
	var laundered: SFTypesScript.ConnectionInfo = SFTypesScript.ConnectionInfo.new(
		{"type": "relay", "host": "relay.example.test", "port": 9000, "client_id": 1e30}
	)
	_assert_equal(-1, laundered.client_id, "laundered client_id reads absent")
	_assert(
		not laundered.to_dict().has("client_id"), "laundered client_id is erased from to_dict()"
	)
	_done()


## Issue #97: array coercion keeps only strings (the typed accessor view),
## but to_dict() must not silently shorten what a consumer put in — the
## verbatim entries either round-trip (rosters) or let the outbound
## validation refuse the frame loudly (webrtc candidates on the resend path).


func _test_wrong_typed_array_entries_round_trip() -> void:
	var webrtc: SFTypesScript.ConnectionInfo = SFTypesScript.ConnectionInfo.new(
		{"type": "webrtc", "sdp": "s", "ice_candidates": ["candidate:a", 42, true]}
	)
	_assert_equal(
		PackedStringArray(["candidate:a"]),
		webrtc.ice_candidates,
		"webrtc typed view keeps only strings"
	)
	_assert_equal(
		["candidate:a", 42, true],
		webrtc.to_dict()["ice_candidates"],
		"webrtc to_dict preserves every raw entry"
	)
	_assert_equal(
		["candidate:1"],
		(
			SFTypesScript
			. ConnectionInfo
			. new({"type": "webrtc", "ice_candidates": ["candidate:1"]})
			. to_dict()["ice_candidates"]
		),
		"honest webrtc candidates round-trip"
	)

	var roster_data := _minimal_room_joined()
	roster_data["current_players"] = [{"id": "a", "name": "Alice"}, "junk", ["nested"]]
	roster_data["current_spectators"] = [{"id": "s1", "name": "Watcher"}, 7]
	var roster: SFTypesScript.RoomJoinedInfo = SFTypesScript.RoomJoinedInfo.new(roster_data)
	_assert_equal(1, roster.current_players.size(), "roster typed view keeps only objects")
	var round_tripped: Dictionary = roster.to_dict()
	var round_tripped_players: Array = round_tripped["current_players"]
	_assert_equal(3, round_tripped_players.size(), "players to_dict preserves every raw entry")
	_assert_equal("a", round_tripped_players[0]["id"], "dict entry still canonicalizes")
	_assert_equal("junk", round_tripped_players[1], "scalar junk passes through")
	var nested_junk: Array = round_tripped_players[2]
	nested_junk.append("mutation")
	_assert_equal(["nested"], roster_data["current_players"][2], "junk containers never alias")
	var round_tripped_spectators: Array = round_tripped["current_spectators"]
	_assert_equal(2, round_tripped_spectators.size(), "spectators to_dict preserves entries")
	_assert_equal("s1", round_tripped_spectators[0]["id"], "spectator dict canonicalizes")
	_assert_equal(7, round_tripped_spectators[1], "spectator junk passes through")

	var spectator_roster_data := {
		"room_id": "20000000-0000-0000-0000-000000000001",
		"room_code": "ABC123",
		"spectator_id": "30000000-0000-0000-0000-000000000001",
		"game_name": "reef-rally",
		"current_players": ["junk", {"id": "a", "name": "Alice"}],
		"current_spectators": [],
		"lobby_state": "waiting"
	}
	var spectator_roster: SFTypesScript.SpectatorJoinedInfo = SFTypesScript.SpectatorJoinedInfo.new(
		spectator_roster_data
	)
	var spectator_round_tripped: Array = spectator_roster.to_dict()["current_players"]
	_assert_equal(2, spectator_round_tripped.size(), "spectator roster keeps junk position")
	_assert_equal("junk", spectator_round_tripped[0], "leading junk stays in place")
	_assert_equal("a", spectator_round_tripped[1]["id"], "trailing dict still canonicalizes")
	_done()


func _bool_sites() -> Array:
	return [
		[
			"PlayerInfo.is_authority",
			SFTypesScript.PlayerInfo,
			"is_authority",
			{"id": "10000000-0000-0000-0000-000000000001", "name": "Alice", "connected_at": "now"},
			"connected_at",
			"now",
		],
		[
			"PlayerInfo.is_ready",
			SFTypesScript.PlayerInfo,
			"is_ready",
			{"id": "10000000-0000-0000-0000-000000000001", "name": "Alice", "connected_at": "now"},
			"connected_at",
			"now",
		],
		[
			"PlayerNameRules.allow_unicode_alphanumeric",
			SFTypesScript.PlayerNameRules,
			"allow_unicode_alphanumeric",
			{"max_length": 8, "min_length": 1, "additional_allowed_characters": "x!"},
			"additional_allowed_characters",
			"x!",
		],
		[
			"PlayerNameRules.allow_spaces",
			SFTypesScript.PlayerNameRules,
			"allow_spaces",
			{"max_length": 8, "min_length": 1, "additional_allowed_characters": "x!"},
			"additional_allowed_characters",
			"x!",
		],
		[
			"PlayerNameRules.allow_leading_trailing_whitespace",
			SFTypesScript.PlayerNameRules,
			"allow_leading_trailing_whitespace",
			{"max_length": 8, "min_length": 1, "additional_allowed_characters": "x!"},
			"additional_allowed_characters",
			"x!",
		],
		[
			"PeerConnectionInfo.is_authority",
			SFTypesScript.PeerConnectionInfo,
			"is_authority",
			{
				"player_id": "10000000-0000-0000-0000-000000000001",
				"player_name": "Alice",
				"relay_type": "websocket"
			},
			"relay_type",
			"websocket",
		],
		[
			"RoomJoinedInfo.supports_authority",
			SFTypesScript.RoomJoinedInfo,
			"supports_authority",
			_room_joined_with_token(),
			"reconnection_token",
			"tok-not-secret",
		],
		[
			"RoomJoinedInfo.is_authority",
			SFTypesScript.RoomJoinedInfo,
			"is_authority",
			_room_joined_with_token(),
			"reconnection_token",
			"tok-not-secret",
		],
		[
			"SessionPeerInfo.is_authority",
			SFSessionTypesScript.SessionPeerInfo,
			"is_authority",
			{
				"player_id": "10000000-0000-0000-0000-000000000001",
				"player_name": "Alice",
				"initiate": true
			},
			"initiate",
			true,
		],
		[
			"SessionPeerInfo.initiate",
			SFSessionTypesScript.SessionPeerInfo,
			"initiate",
			{"player_id": "10000000-0000-0000-0000-000000000001", "player_name": "Alice"},
			null,
			null,
		],
		[
			"NewPeerInfo.you_initiate",
			SFSessionTypesScript.NewPeerInfo,
			"you_initiate",
			{"peer_id": "10000000-0000-0000-0000-000000000001"},
			null,
			null,
		],
		[
			"PeerTransportStatusInfo.connected",
			SFSessionTypesScript.PeerTransportStatusInfo,
			"connected",
			{"peer_id": "10000000-0000-0000-0000-000000000001"},
			null,
			null,
		],
	]


func _int_sites() -> Array:
	return [
		[
			"RateLimitInfo.per_minute",
			SFTypesScript.RateLimitInfo,
			"per_minute",
			{"per_hour": 1, "per_day": 1},
			0,
		],
		[
			"RateLimitInfo.per_hour",
			SFTypesScript.RateLimitInfo,
			"per_hour",
			{"per_minute": 1, "per_day": 1},
			0,
		],
		[
			"RateLimitInfo.per_day",
			SFTypesScript.RateLimitInfo,
			"per_day",
			{"per_minute": 1, "per_hour": 1},
			0,
		],
		[
			"PlayerNameRules.max_length",
			SFTypesScript.PlayerNameRules,
			"max_length",
			{"min_length": 1},
			0,
		],
		[
			"PlayerNameRules.min_length",
			SFTypesScript.PlayerNameRules,
			"min_length",
			{"max_length": 8},
			0,
		],
		[
			"RoomJoinedInfo.max_players",
			SFTypesScript.RoomJoinedInfo,
			"max_players",
			_minimal_room_joined(),
			0,
		],
		[
			"ConnectionInfo.port",
			SFTypesScript.ConnectionInfo,
			"port",
			{"type": "direct", "host": "127.0.0.1"},
			0,
		],
		[
			"ConnectionInfo.client_id",
			SFTypesScript.ConnectionInfo,
			"client_id",
			{"type": "relay", "host": "relay.example.test", "port": 9000},
			-1,
		],
		[
			"ProtocolInfo.protocol_version",
			SFTypesScript.ProtocolInfo,
			"protocol_version",
			{},
			0,
		],
		[
			"ProtocolInfo.min_protocol_version",
			SFTypesScript.ProtocolInfo,
			"min_protocol_version",
			{},
			0,
		],
		[
			"ProtocolInfo.max_protocol_version",
			SFTypesScript.ProtocolInfo,
			"max_protocol_version",
			{},
			0,
		],
		[
			"ProtocolInfo.max_outbound_message_size",
			SFTypesScript.ProtocolInfo,
			"max_outbound_message_size",
			{},
			0,
		],
		[
			"DirectEndpointInfo.port",
			SFSessionTypesScript.DirectEndpointInfo,
			"port",
			{"host": "127.0.0.1"},
			0,
		],
	]


func _minimal_room_joined() -> Dictionary:
	return {
		"room_id": "20000000-0000-0000-0000-000000000001",
		"room_code": "ABC123",
		"player_id": "p1",
		"game_name": "reef-rally",
		"current_players": [],
		"lobby_state": "waiting",
		"ready_players": [],
	}


func _room_joined_with_token() -> Dictionary:
	var data := _minimal_room_joined()
	data["reconnection_token"] = "tok-not-secret"
	return data


## Build a fresh object from a site row: [label, script, field, base data]
## (+ expected sentinel on int rows), with [param field_value] set.
func _build(site: Array, field_value: Variant) -> Object:
	var data: Dictionary = site[3]
	data[site[2]] = field_value
	var script: GDScript = site[1]
	return script.new(data)


func _read(site: Array, object: Object) -> Variant:
	var field: StringName = site[2]
	return object.get(field)


func _variant_label(value: Variant) -> String:
	if typeof(value) == TYPE_FLOAT:
		var float_value: float = value
		if is_nan(float_value):
			return "NaN"
	if typeof(value) == TYPE_STRING:
		return '"%s"' % value
	return str(value)


func _assert(condition: bool, label: String) -> bool:
	if not condition:
		_failures.append(label)
		return false
	return true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	if expected == actual:
		return true
	_failures.append(
		"%s: expected %s, got %s" % [label, _variant_label(expected), _variant_label(actual)]
	)
	return false
