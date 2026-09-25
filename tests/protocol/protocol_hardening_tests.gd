extends RefCounted

const SFEnvelopeScript = preload("res://addons/signal_fish/protocol/sf_envelope.gd")
const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFGameDataFormatScript = preload("res://addons/signal_fish/protocol/sf_game_data_format.gd")
const SFMessagesScript = preload("res://addons/signal_fish/protocol/sf_messages.gd")
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
		_test_client_message_validation,
		_test_connection_info_to_dict_resend_canonicalization,
		_test_custom_connection_info_data_is_copied,
		_test_inbound_strict_null_validation,
		_test_binary_codec_hardening,
		_test_forward_compatible_inbound_strings,
		_test_non_empty_wire_strings,
		_test_reconnected_missed_events_nonfatal,
		_test_reconnected_missed_events_depth_hardening,
		_test_decode_raw_aliasing,
		_test_optional_string_field_strictness,
		_test_wire_payload_fidelity,
		_test_encode_boundary_refusals,
		_test_format_downgrade_diagnostics,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## Issue #76: nested floats used to serialize at reduced precision
## (JSON.stringify's full_precision flag does not reach container values),
## so the wire text failed to round-trip. The encoder now proves every
## float bit-exact by parse-back, keeps integral floats on the wire as
## floats ("2.0", never integer text), and refuses what it cannot
## represent losslessly.
func _test_wire_payload_fidelity() -> void:
	var vectors := [
		{"label": "guard digits", "value": 0.30000000000000004},
		{"label": "short value", "value": 0.5},
		{"label": "integral float", "value": 2.0, "wire": "2.0"},
		{"label": "negative magnitude", "value": -7.3e12},
		{"label": "large id double", "value": 9007199254740993.0},
		{"label": "negative zero", "value": -0.0},
	]
	for vector: Dictionary in vectors:
		var value: float = vector["value"]
		var label: String = vector["label"]
		var envelope := SFMessagesScript.game_data({"score": value})
		_assert_valid_message(envelope, "fidelity %s builds" % label)
		var wire := SFMessagesScript.encode(envelope)
		if not _assert(not wire.is_empty(), "fidelity %s encodes" % label):
			continue
		var back: Variant = JSON.parse_string(wire)
		if not _assert(typeof(back) == TYPE_DICTIONARY, "fidelity %s wire parses" % label):
			continue
		var wire_dict: Dictionary = back
		var payload: Variant = wire_dict["data"]["data"]["score"]
		_assert(typeof(payload) == TYPE_FLOAT, "fidelity %s stays float on the wire" % label)
		var round_trips: bool = payload == value
		_assert(round_trips, "fidelity %s round-trips" % label)
		if vector.has("wire"):
			_assert_string_contains(
				wire, '"score":%s' % vector["wire"], "fidelity %s wire text" % label
			)
	var null_envelope := SFMessagesScript.game_data(null)
	_assert_valid_message(null_envelope, "top-level null game data stays valid")
	_assert_equal(
		'{"type":"GameData","data":{"data":null}}',
		SFMessagesScript.encode(null_envelope),
		"top-level null wire bytes unchanged"
	)
	# Nested JSON null is upstream `Value::Null`: the decoder preserves it,
	# so the outbound guard must not refuse what a peer could send back.
	var nested_null := SFMessagesScript.game_data({"hp": null, "tags": [null]})
	_assert_valid_message(nested_null, "nested null game data stays valid")
	_assert_equal(
		'{"type":"GameData","data":{"data":{"hp":null,"tags":[null]}}}',
		SFMessagesScript.encode(nested_null),
		"nested null wire bytes verbatim"
	)
	# The matchbox Signal payload keeps its documented nested-null refusal.
	_assert_invalid_message(
		SFMessagesScript.peer_signal("peer-b", null, {"Offer": null}),
		"must be JSON data",
		"peer_signal nested null refused"
	)
	var non_finite := [{"label": "NaN", "value": NAN}, {"label": "INF", "value": INF}]
	for case: Dictionary in non_finite:
		var payload: Dictionary = {"x": case["value"]}
		_assert_invalid_message(
			SFMessagesScript.game_data(payload),
			"must be JSON data",
			"game_data %s refused" % case["label"]
		)
		_assert_invalid_message(
			SFMessagesScript.peer_signal("peer-b", null, payload),
			"must be JSON data",
			"peer_signal %s refused" % case["label"]
		)
	# Sibling parity with peer_signal's pinned engine-Variant refusal.
	_assert_invalid_message(
		SFMessagesScript.game_data({"pos": Vector2(1, 2)}),
		"must be JSON data",
		"game_data engine Variant refused"
	)
	# Godot convenience types the old bare JSON.stringify serialized silently:
	# StringName values and Packed*Array payloads are refused like any other
	# non-JSON Variant (fail closed, convert at the call site).
	_assert_invalid_message(
		SFMessagesScript.game_data({"name": &"reef"}),
		"must be JSON data",
		"game_data StringName value refused"
	)
	_assert_invalid_message(
		SFMessagesScript.game_data(PackedStringArray(["a", "b"])),
		"must be JSON data",
		"game_data packed array refused"
	)
	# The builder depth bound matches the encoder's envelope-relative bound:
	# the payload sits two levels below the root, so a leaf value at depth 16
	# still encodes and one more wrap is refused with the payload-level
	# diagnostic.
	var nest: Variant = {"leaf": true}
	for _level: int in SFTypeUtils.MAX_MESSAGE_DEPTH - 3:
		nest = {"inner": nest}
	var at_bound := SFMessagesScript.game_data(nest)
	_assert_valid_message(at_bound, "depth-bound game data builds")
	_assert(not SFMessagesScript.encode(at_bound).is_empty(), "depth-bound game data encodes")
	var over_nest: Variant = {"inner": nest}
	var over_bound := SFMessagesScript.game_data(over_nest)
	_assert_invalid_message(
		over_bound, "must be JSON data", "over-deep game data refused at the builder"
	)
	_done()


## The encode boundary is the last-resort net for payloads that skip the
## builder whitelist (ConnectionInfo.custom.data): unserializable values
## refuse the frame — empty wire, never JSON.stringify's silent
## stringification, `nan` literals, or coerced dict keys.


func _test_encode_boundary_refusals() -> void:
	var cases := [
		{"label": "engine Variant", "payload": {"deep": Vector2(1, 2)}},
		{"label": "non-finite float", "payload": {"deep": NAN}},
		{"label": "Object Variant", "payload": {"deep": RefCounted.new()}},
		{"label": "non-string key", "payload": {"deep": {1: "a"}}},
	]
	for case: Dictionary in cases:
		var envelope := SFEnvelopeScript.message("GameData", {"data": {"custom": case["payload"]}})
		_assert_equal(
			true, SFMessagesScript.is_valid_message(envelope), "%s passes builders" % case["label"]
		)
		# report_error off: the refusal itself is the assertion; the reported
		# path is covered by the client-level boundary test.
		_assert_equal(
			"",
			SFEnvelopeScript.encode(envelope, false),
			"%s refuses at the boundary" % case["label"]
		)
	# Three envelope levels precede the payload, so 13 nested arrays put the
	# leaf exactly at the encoder's MAX_MESSAGE_DEPTH bound: in passes, one
	# more wrap refuses.
	var deep: Variant = "leaf"
	for _level: int in SFTypeUtils.MAX_MESSAGE_DEPTH - 3:
		deep = [deep]
	var deep_envelope := SFEnvelopeScript.message("GameData", {"data": {"custom": deep}})
	_assert_equal(
		true,
		SFMessagesScript.is_valid_message(deep_envelope),
		"depth-bound payload passes builders"
	)
	_assert(not SFMessagesScript.encode(deep_envelope).is_empty(), "depth-bound payload encodes")
	var over_deep: Variant = [deep]
	var over_envelope := SFEnvelopeScript.message("GameData", {"data": {"custom": over_deep}})
	_assert_equal("", SFEnvelopeScript.encode(over_envelope, false), "over-deep payload refuses")
	_done()


## Issue #79: the downgrade diagnostic renders the server's statement as
## wire tokens, not coerced enum ints (unknown becomes "-1" today).


func _test_format_downgrade_diagnostics() -> void:
	var cases := [
		{
			"label": "int array renders tokens",
			"supported": [SFTypesScript.GameDataEncoding.JSON, -1],
			"expected": "[json, unknown]",
		},
		{
			"label": "string array renders verbatim",
			"supported": ["json", "weird"],
			"expected": "[json, weird]",
		},
	]
	for case: Dictionary in cases:
		var supported: Array = case["supported"]
		var expected: String = case["expected"]
		var reason := SFGameDataFormatScript.downgrade_reason("message_pack", supported)
		_assert_string_contains(reason, expected, "downgrade %s" % case["label"])
		_assert_string_contains(
			reason, "does not include the requested format", "downgrade %s explains" % case["label"]
		)
	_assert_equal(
		"", SFGameDataFormatScript.downgrade_reason("rkyv", [0, 2]), "supported preference silent"
	)
	_assert_equal(
		"", SFGameDataFormatScript.downgrade_reason("message_pack", []), "empty statement silent"
	)
	_done()


func _test_client_message_validation() -> void:
	var join_integral_float := SFMessagesScript.join_room(
		"reef-rally", "Alice", null, 4.0, false, SFTypesScript.RelayTransport.WEBSOCKET
	)
	_assert_valid_message(join_integral_float, "join_room integral float")
	_assert_equal(4, join_integral_float["data"]["max_players"], "join_room max_players int")
	_assert_equal(false, join_integral_float["data"]["supports_authority"], "join_room bool")
	_assert_equal("websocket", join_integral_float["data"]["relay_transport"], "join_room enum int")

	# PLAN §13 item 9 (server room_service.rs `unwrap_or(true)`, upstream
	# 5af5fee): the Godot default omits `supports_authority`, so the server
	# enables authority — exactly the rust client's `Option` default.
	var join_default := SFMessagesScript.join_room("reef-rally", "Alice")
	_assert_valid_message(join_default, "join_room defaults")
	var join_default_data: Dictionary = join_default["data"]
	_assert(
		not join_default_data.has("supports_authority"),
		"join_room omits supports_authority by default (server enables authority)"
	)

	# Builder-side collapse gate (issue #96): a magnitude int() would
	# collapse platform-dependently must refuse, not range-check the
	# collapsed value (a collapse landing at 0 would even silently omit
	# protocol_version).
	_assert_invalid_message(
		SFMessagesScript.join_room("reef-rally", "Alice", null, 1e30),
		"must be an integer",
		"join_room max_players 1e30 refused"
	)
	_assert_invalid_message(
		SFMessagesScript.join_room("reef-rally", "Alice", null, 9223372036854775808.0),
		"must be an integer",
		"join_room max_players 2^63 refused"
	)
	_assert_invalid_message(
		SFMessagesScript.authenticate("mb_app_fixture", null, null, null, 1e30),
		"must be an integer",
		"authenticate protocol_version 1e30 refused"
	)

	var valid_messages := [
		{
			"label": "authenticate enum int",
			"envelope":
			SFMessagesScript.authenticate(
				"mb_app_fixture", null, null, SFTypesScript.GameDataEncoding.MESSAGE_PACK
			)
		},
		{
			"label": "provide direct connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 7777}
			)
		},
		{
			"label": "provide relay connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t"
				}
			)
		},
		{
			"label": "provide webrtc connection",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "webrtc", "sdp": "offer", "ice_candidates": ["candidate:1"]}
			)
		},
		{
			"label": "provide custom connection",
			"envelope":
			SFMessagesScript.provide_connection_info({"type": "custom", "data": {"x": 1}})
		},
		{
			"label": "provide custom null payload",
			"envelope": SFMessagesScript.provide_connection_info({"type": "custom", "data": null})
		},
	]
	for test_case: Dictionary in valid_messages:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_valid_message(envelope, label)

	var invalid_messages := [
		{
			"label": "join_room fractional max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 4.5),
			"error": "max_players"
		},
		{
			"label": "join_room zero max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 0),
			"error": "max_players"
		},
		{
			"label": "join_room high max_players",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, 256),
			"error": "max_players"
		},
		{
			"label": "join_room string bool",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, "false"),
			"error": "supports_authority"
		},
		{
			"label": "join_room relay typo",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, null, "TCP"),
			"error": "relay_transport"
		},
		{
			"label": "join_room empty relay",
			"envelope": SFMessagesScript.join_room("reef-rally", "Alice", null, null, null, ""),
			"error": "relay_transport"
		},
		{
			"label": "authenticate format typo",
			"envelope": SFMessagesScript.authenticate("mb_app_fixture", null, null, "message-pack"),
			"error": "game_data_format"
		},
		{
			"label": "authenticate empty format",
			"envelope": SFMessagesScript.authenticate("mb_app_fixture", null, null, ""),
			"error": "game_data_format"
		},
		{
			"label": "provide direct missing host",
			"envelope": SFMessagesScript.provide_connection_info({"type": "direct", "port": 7777}),
			"error": "host"
		},
		{
			"label": "provide direct null host",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": null, "port": 7777}
			),
			"error": "host"
		},
		{
			"label": "provide direct high port",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 65536}
			),
			"error": "port"
		},
		{
			"label": "provide direct float port",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "direct", "host": "127.0.0.1", "port": 7777.0}
			),
			"error": "port"
		},
		{
			"label": "provide relay transport typo",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"transport": "TCP"
				}
			),
			"error": "transport"
		},
		{
			"label": "provide relay null transport",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"transport": null
				}
			),
			"error": "transport"
		},
		{
			"label": "provide relay null required field",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": null,
					"token": "t"
				}
			),
			"error": "allocation_id"
		},
		{
			"label": "provide relay float client id",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{
					"type": "relay",
					"host": "relay.example.test",
					"port": 9000,
					"allocation_id": "a",
					"token": "t",
					"client_id": 1.0
				}
			),
			"error": "client_id"
		},
		{
			"label": "provide unknown type",
			"envelope": SFMessagesScript.provide_connection_info({"type": "future"}),
			"error": "type"
		},
		{
			"label": "provide webrtc missing ice",
			"envelope":
			SFMessagesScript.provide_connection_info({"type": "webrtc", "sdp": "offer"}),
			"error": "ice_candidates"
		},
		{
			"label": "provide webrtc null ice",
			"envelope":
			SFMessagesScript.provide_connection_info(
				{"type": "webrtc", "sdp": "offer", "ice_candidates": null}
			),
			"error": "ice_candidates"
		},
		{
			"label": "provide custom missing data",
			"envelope": SFMessagesScript.provide_connection_info({"type": "custom"}),
			"error": "data"
		},
	]
	for test_case: Dictionary in invalid_messages:
		var envelope: Dictionary = test_case["envelope"]
		var expected_error: String = test_case["error"]
		var label: String = test_case["label"]
		_assert_invalid_message(envelope, expected_error, label)
	var invalid_envelope: Dictionary = invalid_messages[0]["envelope"]
	_assert_equal("", SFEnvelopeScript.encode(invalid_envelope, false), "invalid encode guard")
	_done()


func _test_connection_info_to_dict_resend_canonicalization() -> void:
	var direct_info := SFTypesScript.ConnectionInfo.new(
		{"type": "direct", "host": "127.0.0.1", "port": 7777.0}
	)
	var direct_dict := direct_info.to_dict()
	_assert_equal(TYPE_INT, typeof(direct_dict["port"]), "direct to_dict port type")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(direct_dict), "resend direct to_dict"
	)

	var direct_extra_fields_info := SFTypesScript.ConnectionInfo.new(
		{
			"type": "direct",
			"host": "127.0.0.1",
			"port": 7777.0,
			"token": "wrong-variant",
			"transport": "tcp"
		}
	)
	var direct_extra_fields_dict := direct_extra_fields_info.to_dict()
	_assert(not direct_extra_fields_dict.has("transport"), "direct transport metadata omitted")
	_assert(not direct_extra_fields_dict.has("token"), "direct cross-variant token omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(direct_extra_fields_dict),
		"resend direct extra fields to_dict"
	)

	var relay_raw := _relay_connection_info({"port": 9000.0, "transport": null, "client_id": null})
	var relay_info := SFTypesScript.ConnectionInfo.new(relay_raw)
	var relay_dict := relay_info.to_dict()
	_assert_equal(-1, relay_info.client_id, "relay null client_id stays absent")
	_assert_equal(TYPE_INT, typeof(relay_dict["port"]), "relay to_dict port type")
	_assert_equal("auto", relay_dict["transport"], "relay null transport to auto")
	_assert(not relay_dict.has("client_id"), "relay null client_id omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(relay_dict), "resend relay to_dict"
	)

	# Issue #89: a fractional client_id must fail closed in the constructor —
	# int() truncation used to launder it into a different (valid) relay slot
	# through the documented to_dict() resend path.
	var fractional_info := SFTypesScript.ConnectionInfo.new(
		_relay_connection_info({"client_id": 1.5})
	)
	var fractional_dict := fractional_info.to_dict()
	_assert_equal(-1, fractional_info.client_id, "relay fractional client_id fails closed")
	_assert(not fractional_dict.has("client_id"), "relay fractional client_id omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(fractional_dict),
		"resend fractional-client_id to_dict"
	)
	var integral_float_info := SFTypesScript.ConnectionInfo.new(
		_relay_connection_info({"client_id": 7.0})
	)
	_assert_equal(7, integral_float_info.client_id, "relay integral float client_id accepted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(integral_float_info.to_dict()),
		"resend integral-float client_id to_dict"
	)

	var future_transport_info := SFTypesScript.ConnectionInfo.new(
		_relay_connection_info({"transport": "future_transport"})
	)
	var future_transport_dict := future_transport_info.to_dict()
	_assert(not future_transport_dict.has("transport"), "future relay transport omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(future_transport_dict),
		"resend future relay transport to_dict"
	)

	var webrtc_info := SFTypesScript.ConnectionInfo.new(
		{"type": "webrtc", "sdp": null, "ice_candidates": ["candidate:1"]}
	)
	var webrtc_dict := webrtc_info.to_dict()
	_assert(not webrtc_dict.has("sdp"), "webrtc null sdp omitted")
	_assert_valid_message(
		SFMessagesScript.provide_connection_info(webrtc_dict), "resend webrtc to_dict"
	)
	# Issue #97: a wrong-typed candidate stays in the resent dict verbatim so
	# the outbound validation refuses the frame loudly instead of the
	# constructor silently laundering a shorter array onto the wire.
	var hostile_candidates_info := SFTypesScript.ConnectionInfo.new(
		{"type": "webrtc", "sdp": "s", "ice_candidates": ["candidate:1", 42]}
	)
	_assert_invalid_message(
		SFMessagesScript.provide_connection_info(hostile_candidates_info.to_dict()),
		"ice_candidates",
		"resend hostile webrtc candidates"
	)

	var player_info := SFTypesScript.PlayerInfo.new(
		_with_overrides(_minimal_player_data(), {"connection_info": relay_raw})
	)
	var player_dict := player_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(player_dict["connection_info"]["port"]),
		"player to_dict connection port type"
	)
	_assert_equal(
		"auto", player_dict["connection_info"]["transport"], "player to_dict connection transport"
	)

	var peer_info := SFTypesScript.PeerConnectionInfo.new(
		_peer_connection({"connection_info": relay_raw})
	)
	var peer_dict := peer_info.to_dict()
	_assert_equal(
		TYPE_INT, typeof(peer_dict["connection_info"]["port"]), "peer to_dict connection port type"
	)
	_assert_equal(
		"auto", peer_dict["connection_info"]["transport"], "peer to_dict connection transport"
	)

	var nested_player := _minimal_player_data()
	nested_player["connection_info"] = relay_raw
	var room_info := SFTypesScript.RoomJoinedInfo.new(
		_with_overrides(_minimal_room_joined_data(), {"current_players": [nested_player]})
	)
	var room_dict := room_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(room_dict["current_players"][0]["connection_info"]["port"]),
		"room to_dict connection port type"
	)

	var spectator_joined_info := SFTypesScript.SpectatorJoinedInfo.new(
		_with_overrides(_minimal_spectator_joined_data(), {"current_players": [nested_player]})
	)
	var spectator_joined_dict := spectator_joined_info.to_dict()
	_assert_equal(
		TYPE_INT,
		typeof(spectator_joined_dict["current_players"][0]["connection_info"]["port"]),
		"spectator joined to_dict connection port type"
	)
	_done()


func _test_custom_connection_info_data_is_copied() -> void:
	# Issue #73: custom.data is an open payload, but to_dict() must hand back
	# an independent copy instead of aliasing the caller's wire tree.
	var payload := {"depth": {"hp": 3}}
	var source := {"type": "custom", "data": payload}
	var info := SFTypesScript.ConnectionInfo.new(source)
	var dict := info.to_dict()
	payload["depth"]["hp"] = 9
	_assert_equal(3, info.data["depth"]["hp"], "data views the snapshot, not the caller tree")
	_assert_equal(3, dict["data"]["depth"]["hp"], "to_dict copy survives caller mutation")
	dict["data"]["depth"]["hp"] = 42
	_assert_equal(3, info.data["depth"]["hp"], "mutating to_dict leaves data intact")
	_assert_equal(
		null, SFTypesScript.ConnectionInfo.new({"type": "custom"}).data, "absent data stays null"
	)
	_assert_valid_message(SFMessagesScript.provide_connection_info(dict), "resend custom to_dict")
	_done()


func _test_inbound_strict_null_validation() -> void:
	var custom_null_player := _minimal_player_data()
	custom_null_player["connection_info"] = {"type": "custom", "data": null}
	var invalid_envelopes := [
		{
			"label": "ProtocolInfo null allowed symbols",
			"envelope":
			{
				"type": "ProtocolInfo",
				"data":
				{
					"player_name_rules":
					{
						"max_length": 32,
						"min_length": 1,
						"allow_unicode_alphanumeric": true,
						"allow_spaces": true,
						"allow_leading_trailing_whitespace": false,
						"allowed_symbols": null
					}
				}
			}
		},
	]
	for test_case: Dictionary in invalid_envelopes:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)

	var pong_null_data: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Pong", "data": null}
	)
	_assert_equal("pong", String(pong_null_data.signal_name), "pong null data")

	var player_custom_null: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": custom_null_player}}
	)
	_assert_equal("player_joined", String(player_custom_null.signal_name), "custom null player")
	_assert_equal(null, player_custom_null.args[0].connection_info.data, "custom null player data")

	var peer_custom_null: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		_game_starting_envelope(
			[_peer_connection({"connection_info": {"type": "custom", "data": null}})]
		)
	)
	_assert_equal("game_starting", String(peer_custom_null.signal_name), "custom null peer")
	_assert_equal(null, peer_custom_null.args[0][0].connection_info.data, "custom null peer data")

	var null_connection_player := _minimal_player_data()
	null_connection_player["connection_info"] = null
	var player_null_connection: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": null_connection_player}}
	)
	_assert_equal(
		"player_joined", String(player_null_connection.signal_name), "player null connection"
	)
	_assert_equal(null, player_null_connection.args[0].connection_info, "null player connection")
	_done()


func _test_binary_codec_hardening() -> void:
	var unpadded: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": "yv4"}
		}
	)
	_assert_equal(
		"game_data_binary_received", String(unpadded.signal_name), "unpadded base64 binary event"
	)
	_assert_equal(PackedByteArray([202, 254]), unpadded.args[2], "unpadded base64 payload")

	var future_encoding: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "future_pack", "payload": "yv4"}
		}
	)
	_assert_equal(
		"game_data_binary_received",
		String(future_encoding.signal_name),
		"unknown binary encoding is forward-compatible"
	)
	_assert_equal(
		SFTypesScript.GameDataEncoding.UNKNOWN,
		future_encoding.args[1],
		"unknown binary encoding value"
	)
	_assert_equal(PackedByteArray([202, 254]), future_encoding.args[2], "future encoding payload")

	var invalid_padding := _assert_protocol_error_envelope(
		{
			"type": "GameDataBinary",
			"data": {"from_player": "p1", "encoding": "message_pack", "payload": "yv=4"}
		},
		"invalid base64 padding"
	)
	_assert_protocol_error_contains(invalid_padding, "base64", "invalid base64 diagnostics")
	_done()


func _test_forward_compatible_inbound_strings() -> void:
	var future_protocol_info: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "ProtocolInfo", "data": {"game_data_formats": ["json", "future_pack"]}}
	)
	_assert_equal(
		"protocol_info",
		String(future_protocol_info.signal_name),
		"future protocol game data format"
	)
	_assert_equal(
		[SFTypesScript.GameDataEncoding.JSON, SFTypesScript.GameDataEncoding.UNKNOWN],
		future_protocol_info.args[0].game_data_formats,
		"future protocol game data format value"
	)

	var relay_future_transport_data := _relay_connection_info({"transport": "future_transport"})
	var relay_future_transport: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		_game_starting_envelope(
			[_peer_connection({"connection_info": relay_future_transport_data})]
		)
	)
	_assert_equal(
		"game_starting",
		String(relay_future_transport.signal_name),
		"future relay transport accepted inbound"
	)
	_assert_equal(
		SFTypesScript.RelayTransport.UNKNOWN,
		relay_future_transport.args[0][0].connection_info.transport,
		"future relay transport value"
	)

	var future_connection_type_player := _minimal_player_data()
	future_connection_type_player["connection_info"] = {
		"type": "future_transport", "data": {"x": 1}
	}
	var future_connection_type: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": future_connection_type_player}}
	)
	_assert_equal(
		"player_joined",
		String(future_connection_type.signal_name),
		"future connection_info type accepted inbound"
	)
	_assert_equal(
		"future_transport",
		future_connection_type.args[0].connection_info.type,
		"future connection_info type value"
	)

	var spectator_joined_unknown_data := _minimal_spectator_joined_data()
	spectator_joined_unknown_data["reason"] = "future_reason"
	var spectator_joined_unknown_reason: SFTypesScript.DecodedEvent = (
		SFEventsScript
		. decode_envelope({"type": "SpectatorJoined", "data": spectator_joined_unknown_data})
	)
	_assert_equal(
		"spectator_joined",
		String(spectator_joined_unknown_reason.signal_name),
		"spectator joined unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_joined_unknown_reason.args[0].reason,
		"spectator joined unknown reason value"
	)

	var spectator_left_unknown_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorLeft", "data": {"reason": "future_reason"}}
	)
	_assert_equal(
		"spectator_left",
		String(spectator_left_unknown_reason.signal_name),
		"spectator left unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		spectator_left_unknown_reason.args[2],
		"spectator left unknown reason value"
	)

	var new_spectator_unknown_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{
			"type": "NewSpectatorJoined",
			"data": {"spectator": _minimal_spectator_data(), "reason": "future_reason"}
		}
	)
	_assert_equal(
		"new_spectator_joined",
		String(new_spectator_unknown_reason.signal_name),
		"new spectator unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		new_spectator_unknown_reason.args[2],
		"new spectator unknown reason value"
	)

	var disconnected_unknown_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": "future_reason"}}
	)
	_assert_equal(
		"spectator_disconnected",
		String(disconnected_unknown_reason.signal_name),
		"spectator disconnected unknown reason"
	)
	_assert_equal(
		SFTypesScript.SpectatorReason.UNKNOWN,
		disconnected_unknown_reason.args[1],
		"spectator disconnected unknown reason value"
	)

	var null_game_data: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "GameData", "data": {"from_player": "p1", "data": null}}
	)
	_assert_equal("game_data_received", String(null_game_data.signal_name), "null game data")
	_assert_equal(null, null_game_data.args[1], "null game data value")
	_done()


func _test_non_empty_wire_strings() -> void:
	_assert_protocol_error_envelope(
		{"type": "ProtocolInfo", "data": {"game_data_formats": [""]}},
		"empty protocol game data format"
	)
	_assert_protocol_error_envelope(
		{"type": "GameDataBinary", "data": {"from_player": "p1", "encoding": "", "payload": "yv4"}},
		"empty binary encoding"
	)

	var empty_type_player := _minimal_player_data()
	empty_type_player["connection_info"] = {"type": "", "data": {"x": 1}}
	_assert_protocol_error_envelope(
		{"type": "PlayerJoined", "data": {"player": empty_type_player}},
		"empty connection_info type"
	)

	var empty_transport := _relay_connection_info({"transport": ""})
	_assert_protocol_error_envelope(
		_game_starting_envelope([_peer_connection({"connection_info": empty_transport})]),
		"empty relay transport"
	)

	var required_error_code_cases := [
		{
			"label": "auth empty error code",
			"envelope":
			{"type": "AuthenticationError", "data": {"error": "bad app", "error_code": ""}}
		},
		{
			"label": "reconnection empty error code",
			"envelope":
			{"type": "ReconnectionFailed", "data": {"reason": "bad token", "error_code": ""}}
		},
	]
	for test_case: Dictionary in required_error_code_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)

	var optional_error_code_cases := [
		{
			"label": "room join empty error code",
			"envelope": {"type": "RoomJoinFailed", "data": {"reason": "bad room", "error_code": ""}}
		},
		{
			"label": "authority empty error code",
			"envelope": {"type": "AuthorityResponse", "data": {"granted": false, "error_code": ""}}
		},
		{
			"label": "spectator join empty error code",
			"envelope":
			{"type": "SpectatorJoinFailed", "data": {"reason": "bad spectator", "error_code": ""}}
		},
		{
			"label": "server error empty error code",
			"envelope": {"type": "Error", "data": {"message": "bad", "error_code": ""}}
		},
	]
	for test_case: Dictionary in optional_error_code_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)

	var spectator_joined_data := _minimal_spectator_joined_data()
	spectator_joined_data["reason"] = ""
	var spectator_reason_cases := [
		{
			"label": "spectator joined empty reason",
			"envelope": {"type": "SpectatorJoined", "data": spectator_joined_data}
		},
		{
			"label": "spectator left empty reason",
			"envelope": {"type": "SpectatorLeft", "data": {"reason": ""}}
		},
		{
			"label": "new spectator empty reason",
			"envelope":
			{
				"type": "NewSpectatorJoined",
				"data": {"spectator": _minimal_spectator_data(), "reason": ""}
			}
		},
		{
			"label": "spectator disconnected empty reason",
			"envelope":
			{"type": "SpectatorDisconnected", "data": {"spectator_id": "s1", "reason": ""}}
		},
	]
	for test_case: Dictionary in spectator_reason_cases:
		var envelope: Dictionary = test_case["envelope"]
		var label: String = test_case["label"]
		_assert_protocol_error_envelope(envelope, label)

	# Issue #149: identifier fields are upstream UUIDs (`PlayerId`, `RoomId`,
	# `SessionGeneration`), so a present empty id cannot come from a conforming
	# server and would collide with the retired negotiated-rkyv ""
	# sender-unknowable sentinel. Free-text fields stay pass-through.
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
		["signal empty generation", "Signal", {"from": "p", "generation": "", "signal": {}}],
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
			"game starting empty peer id",
			"GameStarting",
			{"peer_connections": [_peer_connection({"player_id": ""})]}
		],
		["session plan empty generation", "SessionPlan", _session_plan({"generation": ""})],
		["session plan empty host", "SessionPlan", _session_plan({"host": ""})],
		[
			"session plan empty direct endpoint host",
			"SessionPlan",
			_session_plan({"direct_endpoint": {"host": "", "port": 7777}})
		],
		[
			"session plan empty peer id",
			"SessionPlan",
			_session_plan(
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
	]
	for test_case: Array in empty_id_cases:
		var data: Dictionary = test_case[2]
		var label: String = test_case[0]
		_assert_protocol_error_envelope({"type": test_case[1], "data": data}, label)

	# No false positives: wire null authority keeps the "" no-authority
	# sentinel, and free-text fields still pass empty strings through.
	var null_authority: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "AuthorityChanged", "data": {"authority_player": null, "you_are_authority": false}}
	)
	if _assert_equal(
		"authority_changed", String(null_authority.signal_name), "null authority decodes"
	):
		_assert_equal("", null_authority.args[0], "null authority keeps empty sentinel")
	var empty_reason: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "RoomJoinFailed", "data": {"reason": ""}}
	)
	_assert_equal("room_join_failed", String(empty_reason.signal_name), "empty reason is free text")
	_done()


func _session_plan(overrides: Dictionary) -> Dictionary:
	var data := {
		"generation": "gen",
		"topology": "relay",
		"transport": "relay",
		"peers": [],
		"fallback": "relay"
	}
	return _with_overrides(data, overrides)


func _test_reconnected_missed_events_nonfatal() -> void:
	var future_missed_event_data := _minimal_room_joined_data()
	future_missed_event_data["missed_events"] = [
		{"type": "FutureEvent", "data": {"value": 1}},
		{"type": "Pong"},
		12,
	]
	var future_missed_event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Reconnected", "data": future_missed_event_data}
	)
	_assert_equal(
		"reconnected", String(future_missed_event.signal_name), "future missed event reconnect"
	)
	var missed_events: Array = future_missed_event.args[1]
	_assert_equal(3, missed_events.size(), "future missed event count")
	_assert_equal("protocol_error", str(missed_events[0].signal_name), "future missed event entry")
	_assert_equal("pong", str(missed_events[1].signal_name), "known missed event")
	var non_object_entry: RefCounted = missed_events[2]
	_assert_protocol_error_contains(non_object_entry, "missed_events[2]", "non-object missed event")
	_done()


func _test_reconnected_missed_events_depth_hardening() -> void:
	var nested_entry_data := _minimal_room_joined_data()
	nested_entry_data["missed_events"] = []
	var nested_data := _minimal_room_joined_data()
	nested_data["missed_events"] = [{"type": "Reconnected", "data": nested_entry_data}]
	var nested_reconnected: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Reconnected", "data": nested_data}
	)
	_assert_equal("reconnected", String(nested_reconnected.signal_name), "nested entry outer")
	var nested_entry: RefCounted = nested_reconnected.args[1][0]
	_assert_protocol_error_contains(
		nested_entry, "not replayable inside missed_events", "nested reconnected rejected"
	)

	var over_depth := SFEventsScript.decode_envelope(
		{"type": "Pong"}, SFEventsScript.MAX_MESSAGE_DEPTH + 1
	)
	_assert_protocol_error_contains(over_depth, "nesting exceeds depth", "depth cap enforced")

	var oversized_data := _minimal_room_joined_data()
	var oversized_missed_events: Array = []
	for _index: int in SFEventsScript.MAX_MISSED_EVENTS + 1:
		oversized_missed_events.append({"type": "Pong"})
	oversized_data["missed_events"] = oversized_missed_events
	var oversized: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "Reconnected", "data": oversized_data}
	)
	_assert_equal("reconnected", String(oversized.signal_name), "oversized missed events outer")
	var oversized_entries: Array = oversized.args[1]
	_assert_equal(
		SFEventsScript.MAX_MISSED_EVENTS + 1,
		oversized_entries.size(),
		"oversized missed events decoded entries"
	)
	var truncated_entry: RefCounted = oversized_entries[SFEventsScript.MAX_MISSED_EVENTS]
	_assert_protocol_error_contains(
		truncated_entry,
		"exceeds %d entries" % SFEventsScript.MAX_MISSED_EVENTS,
		"oversized missed events truncated"
	)
	_done()


func _test_decode_raw_aliasing() -> void:
	# Issue #48: decode output aliases the freshly parsed envelope; to_dict()
	# is the independent mutable copy.
	var room_data := _minimal_room_joined_data()
	room_data["current_players"] = [_minimal_player_data()]
	room_data["missed_events"] = [{"type": "Pong"}]
	var envelope := {"type": "Reconnected", "data": room_data}
	var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(envelope)
	_assert_equal("reconnected", String(event.signal_name), "aliasing decode")
	_assert(is_same(event.raw, envelope), "event raw aliases envelope")
	var room: SFTypesScript.RoomJoinedInfo = event.args[0]
	_assert(is_same(room.raw, envelope["data"]), "baseline raw aliases data")
	_assert(
		is_same(room.current_players[0].raw, envelope["data"]["current_players"][0]),
		"player raw aliases subtree"
	)
	var missed: SFTypesScript.DecodedEvent = event.args[1][0]
	_assert(is_same(missed.raw, envelope["data"]["missed_events"][0]), "missed raw aliases subtree")
	_assert(is_same(room.raw["missed_events"][0], missed.raw), "parent raw exposes missed subtree")
	var snapshot: Dictionary = room.to_dict()
	snapshot["room_id"] = "mutated"
	_assert_equal("r1", room.raw["room_id"], "to_dict copy is independent")
	var info_source := {"type": "direct", "host": "127.0.0.1", "port": 7777}
	var nested_player_data := _minimal_player_data()
	nested_player_data["connection_info"] = info_source
	var nested_player := SFTypesScript.PlayerInfo.new(nested_player_data)
	_assert(
		not is_same(nested_player.connection_info.raw, info_source),
		"outbound ConnectionInfo keeps its snapshot"
	)
	_done()


func _test_optional_string_field_strictness() -> void:
	# Issue #72: optional string fields decode absent/null to "" and reject
	# present non-string values with protocol_error — no silent String()
	# coercion. Cases: [label, value slots, expected sentinel]; empty slots =
	# key absent, one slot = the value under the key.
	var cases := [
		["absent", [], ""],
		["null", [null], ""],
		["string", ["Org"], "Org"],
	]
	for case: Array in cases:
		var data := {"app_name": "app", "rate_limits": _minimal_rate_limits()}
		var value: Array = case[1]
		if not value.is_empty():
			data["organization"] = value[0]
		var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
			{"type": "Authenticated", "data": data}
		)
		if not _assert_equal(
			"authenticated", String(event.signal_name), "organization %s: decodes" % case[0]
		):
			continue
		_assert_equal(case[2], event.args[1], "organization %s: value" % case[0])
	_assert_protocol_error_envelope(
		{
			"type": "Authenticated",
			"data": {"app_name": "app", "organization": [1], "rate_limits": _minimal_rate_limits()}
		},
		"organization wrong type"
	)

	for envelope_type: String in ["RoomJoined", "Reconnected"]:
		var expected_signal := &"room_joined" if envelope_type == "RoomJoined" else &"reconnected"
		for case: Array in cases:
			var data := _minimal_room_joined_data()
			if envelope_type == "Reconnected":
				data["missed_events"] = []
			var value: Array = case[1]
			if not value.is_empty():
				data["reconnection_token"] = value[0]
			var event: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
				{"type": envelope_type, "data": data}
			)
			if not _assert_equal(
				expected_signal,
				event.signal_name,
				"%s reconnection_token %s: decodes" % [envelope_type, case[0]]
			):
				continue
			_assert_equal(
				case[2],
				event.args[0].reconnection_token,
				"%s reconnection_token %s: value" % [envelope_type, case[0]]
			)
		var hostile := _minimal_room_joined_data()
		hostile["reconnection_token"] = 42
		if envelope_type == "Reconnected":
			hostile["missed_events"] = []
		_assert_protocol_error_envelope(
			{"type": envelope_type, "data": hostile},
			"%s reconnection_token wrong type" % envelope_type
		)
	_done()


func _minimal_rate_limits() -> Dictionary:
	return {"per_minute": 60, "per_hour": 600, "per_day": 6000}


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
		"relay_type": "websocket"
	}


func _minimal_player_data() -> Dictionary:
	return {
		"id": "p1", "name": "Alice", "is_authority": false, "is_ready": false, "connected_at": "now"
	}


func _minimal_spectator_joined_data() -> Dictionary:
	return {
		"room_id": "r1",
		"room_code": "ABC123",
		"spectator_id": "s1",
		"game_name": "reef-rally",
		"current_players": [],
		"current_spectators": [],
		"lobby_state": "waiting"
	}


func _minimal_spectator_data() -> Dictionary:
	return {"id": "s1", "name": "Watcher", "connected_at": "now"}


func _game_starting_envelope(peer_connections: Array) -> Dictionary:
	return {"type": "GameStarting", "data": {"peer_connections": peer_connections}}


func _peer_connection(overrides: Dictionary) -> Dictionary:
	return _with_overrides(
		{
			"player_id": "p1",
			"player_name": "Alice",
			"is_authority": false,
			"relay_type": "regional-relay"
		},
		overrides
	)


func _relay_connection_info(overrides: Dictionary) -> Dictionary:
	var data := {"type": "relay", "host": "relay.example.test", "port": 9000}
	data["allocation_id"] = "alloc"
	data["token"] = "relay-token"
	return _with_overrides(data, overrides)


func _with_overrides(data: Dictionary, overrides: Dictionary) -> Dictionary:
	for key: Variant in overrides:
		data[key] = overrides[key]
	return data


func _assert_valid_message(envelope: Dictionary, label: String) -> bool:
	if not _assert(not SFEnvelopeScript.is_invalid_message(envelope), "%s should be valid" % label):
		return false
	return _assert(not SFEnvelopeScript.encode(envelope).is_empty(), "%s should encode" % label)


func _assert_invalid_message(
	envelope: Dictionary, expected_error_substring: String, label: String
) -> bool:
	if not _assert(SFEnvelopeScript.is_invalid_message(envelope), "%s should be invalid" % label):
		return false
	if not _assert_equal(SFEnvelopeScript.INVALID_MESSAGE_TYPE, envelope.get("type"), label):
		return false
	return _assert_string_contains(
		SFEnvelopeScript.invalid_message_error(envelope), expected_error_substring, label
	)


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


func _assert_protocol_error_contains(
	decoded: RefCounted, expected_substring: String, label: String
) -> bool:
	if not _assert_protocol_error(decoded, label):
		return false
	var event: SFTypesScript.DecodedEvent = decoded
	return _assert_string_contains(str(event.args[0]), expected_substring, label)


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
