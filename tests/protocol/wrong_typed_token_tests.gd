extends RefCounted

## Issue #81: `String(value)` / `int(null)` raise for wrong-typed Variants and
## abort the helper, whose typed default (0) silently defeats the UNKNOWN
## (-1) guard. Every enum-token helper must fail closed to UNKNOWN, a
## present-null optional port must not abort the ConnectionInfo constructor,
## and the shared integral-number gate must refuse non-finite magnitudes.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")

var _failures: Array = []


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	_test_wrong_typed_enum_tokens_fail_closed()


func _test_wrong_typed_enum_tokens_fail_closed() -> void:
	var checks := [
		[
			Callable(SFTypesScript, "game_data_encoding_from_string"),
			SFTypesScript.GameDataEncoding.UNKNOWN,
		],
		[Callable(SFTypesScript, "lobby_state_from_string"), SFTypesScript.LobbyState.UNKNOWN],
		[
			Callable(SFTypesScript, "relay_transport_from_string"),
			SFTypesScript.RelayTransport.UNKNOWN
		],
		[
			Callable(SFTypesScript, "spectator_reason_from_string"),
			SFTypesScript.SpectatorReason.UNKNOWN,
		],
		[
			Callable(SFSessionTypesScript, "transport_kind_from_string"),
			SFSessionTypesScript.TransportKind.UNKNOWN,
		],
		[
			Callable(SFSessionTypesScript, "topology_from_string"),
			SFSessionTypesScript.Topology.UNKNOWN
		],
	]
	for value: Variant in [42, 3.5, true, [], {}]:
		var v := var_to_str(value)
		for check: Array in checks:
			var helper: Callable = check[0]
			var unknown: int = check[1]
			var actual: int = helper.call(value)
			_assert(actual == unknown, "%s %s fails closed" % [helper.get_method(), v])
		_assert(
			(
				SFTypeUtils.enum_value(
					SFTypesScript.RELAY_TRANSPORT_FROM_STRING,
					value,
					SFTypesScript.RelayTransport.UNKNOWN
				)
				== SFTypesScript.RelayTransport.UNKNOWN
			),
			"enum_value %s fails closed" % v
		)
		_assert_protocol_error_envelope(
			{
				"type": "PeerTransportStatus",
				"data": {"peer_id": "p2", "transport": value, "connected": true},
			},
			"PeerTransportStatus transport %s refused" % v
		)
	_assert_equal(
		SFTypesScript.GameDataEncoding.UNKNOWN,
		SFTypesScript.game_data_encoding_from_string(null),
		"null encoding fails closed"
	)
	_assert(not SFTypeUtils.is_integral_number(INF), "is_integral_number INF refused")
	_assert(not SFTypeUtils.is_integral_number(-INF), "is_integral_number -INF refused")
	_assert(not SFTypeUtils.is_integral_number(NAN), "is_integral_number NaN refused")
	_assert(SFTypeUtils.is_integral_number(4.0), "is_integral_number integral float")
	var unity_relay_player := {
		"id": "p1",
		"name": "Alice",
		"is_authority": false,
		"is_ready": false,
		"connected_at": "now",
		"connection_info":
		{
			"type": "unity_relay",
			"allocation_id": "alloc-1",
			"connection_data": "cd-1",
			"key": "k-1",
			"port": null,
		},
	}
	var unity_relay_decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(
		{"type": "PlayerJoined", "data": {"player": unity_relay_player}}
	)
	_assert_equal(
		"player_joined", String(unity_relay_decoded.signal_name), "unity_relay null port decodes"
	)
	var unity_relay_info: SFTypesScript.ConnectionInfo = unity_relay_decoded.args[0].connection_info
	_assert_equal(0, unity_relay_info.port, "unity_relay null port stays defaulted")
	_assert_equal("alloc-1", unity_relay_info.allocation_id, "allocation_id survives null port")
	_assert_equal("cd-1", unity_relay_info.connection_data, "connection_data survives null port")
	_assert_equal("k-1", unity_relay_info.key, "key survives null port")
	var custom_info := SFTypesScript.ConnectionInfo.new(
		{"type": "custom", "data": {"x": 1}, "port": null}
	)
	_assert_equal(0, custom_info.port, "custom null port stays defaulted")
	_assert_equal(1, custom_info.data["x"], "custom data survives null port")


func _assert_protocol_error_envelope(envelope: Dictionary, label: String) -> void:
	var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_envelope(envelope)
	_assert(
		decoded != null and String(decoded.signal_name) == "protocol_error",
		"%s must fail closed as protocol_error" % label
	)


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
