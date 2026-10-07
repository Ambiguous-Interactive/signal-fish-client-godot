extends RefCounted

## Pins the codec to the concrete wire samples upstream publishes as of
## signal-fish-server v0.10.0 (issue #55 vendored the v0.9.2 corpus; the
## v0.10.0 refresh added the v3 corpora and two v2 client lines). Every
## sample line must decode, every expected server event must appear, and the
## published shapes that constrain the codec are pinned by name so drift
## surfaces as a named failure.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFSessionTypesScript = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const SERVER_SAMPLES := "res://tests/fixtures/upstream/v2_server_messages.jsonl"
const CLIENT_SAMPLES := "res://tests/fixtures/upstream/v2_client_messages.jsonl"
const SERVER_SAMPLES_V3 := "res://tests/fixtures/upstream/v3_server_messages.jsonl"
const CLIENT_SAMPLES_V3 := "res://tests/fixtures/upstream/v3_client_messages.jsonl"

## Probe-count floor for the future-field sweep, so a corpus refresh that
## dodges every injection site cannot pass the sweep having probed nothing.
## Raise it with the corpus.
const FUTURE_FIELD_PROBE_COUNT := 62

## All `ClientMessage` wire names upstream accepts for the v2 route.
const CLIENT_MESSAGE_TYPES: Array[String] = [
	"Authenticate",
	"JoinRoom",
	"LeaveRoom",
	"GameData",
	"AuthorityRequest",
	"PlayerReady",
	"StartGame",
	"ProvideConnectionInfo",
	"Ping",
	"Reconnect",
	"JoinAsSpectator",
	"LeaveSpectator",
]

## All `ClientMessage` wire names upstream accepts for the v3 route.
const CLIENT_MESSAGE_TYPES_V3: Array[String] = [
	"Authenticate",
	"RoomOperation",
	"GameData",
	"Signal",
	"TransportStatus",
]

## Every v2 `ServerMessage` variant must be represented in the published
## sample corpus (GameDataBinary has no `{type, data}` text envelope).
const EXPECTED_SERVER_SIGNALS: Array[String] = [
	"authenticated",
	"protocol_info",
	"room_joined",
	"player_joined",
	"player_left",
	"game_data_received",
	"lobby_state_changed",
	"authority_changed",
	"authority_response",
	"game_starting",
	"pong",
	"reconnected",
	"reconnection_failed",
	"player_reconnected",
	"spectator_joined",
	"spectator_join_failed",
	"spectator_left",
	"new_spectator_joined",
	"spectator_disconnected",
	"room_join_failed",
	"room_left",
	"authentication_error",
	"server_error",
]

## Every signal the published v3 sample corpus must decode to (17 lines).
const EXPECTED_V3_SERVER_SIGNALS: Array[String] = [
	"protocol_info",
	"room_operation_result",
	"delivery_report",
	"game_data_received",
	"new_peer",
	"signal_received",
	"session_plan",
	"room_joined",
	"reconnected",
	"peer_transport_status",
	"going_away",
]

var _failures: Array[String] = []
var _test_done := false


func _done() -> void:
	_test_done = true


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var server_events := _decode_all_server_samples(SERVER_SAMPLES)
	_check_all_expected_signals_present(server_events, EXPECTED_SERVER_SIGNALS, 24, SERVER_SAMPLES)
	_check_published_shape_pins(server_events)
	var v3_server_events := _decode_all_server_samples(SERVER_SAMPLES_V3)
	_check_all_expected_signals_present(
		v3_server_events, EXPECTED_V3_SERVER_SIGNALS, 17, SERVER_SAMPLES_V3
	)
	_check_v3_published_shape_pins(v3_server_events)
	_check_server_samples_tolerate_future_fields()
	var cases: Array[Callable] = [
		_test_all_client_samples_are_client_messages,
		_test_all_v3_client_samples_are_client_messages,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _decode_all_server_samples(path: String) -> Array[SFTypesScript.DecodedEvent]:
	var events: Array[SFTypesScript.DecodedEvent] = []
	for line: String in _read_sample_lines(path):
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(line)
		if decoded == null or decoded.signal_name == &"protocol_error":
			_failures.append("%s: sample line failed to decode: %s" % [path, _line_summary(line)])
			continue
		events.append(decoded)
	return events


func _check_all_expected_signals_present(
	events: Array[SFTypesScript.DecodedEvent],
	expected_signals: Array[String],
	expected_count: int,
	path: String
) -> void:
	var seen := {}
	for decoded: SFTypesScript.DecodedEvent in events:
		var signal_text := String(decoded.signal_name)
		seen[signal_text] = seen.get(signal_text, 0) + 1
	for expected: String in expected_signals:
		if not seen.has(expected):
			_failures.append("%s: no sample decodes to %s" % [path, expected])
	_assert_equal(expected_count, events.size(), "%s sample decode count" % path)


func _check_published_shape_pins(server_events: Array[SFTypesScript.DecodedEvent]) -> void:
	var room_joined := _first_event(server_events, "room_joined")
	if room_joined != null:
		var info: SFTypesScript.RoomJoinedInfo = room_joined.args[0]
		_assert_equal("matchbox", info.relay_type, "upstream relay_type preserved verbatim")
		_assert_equal(
			SFTypesScript.LobbyState.WAITING, info.lobby_state, "upstream room lobby state"
		)

	var protocol_info := _first_event(server_events, "protocol_info")
	if protocol_info != null:
		var info: SFTypesScript.ProtocolInfo = protocol_info.args[0]
		_assert_equal(
			[SFTypesScript.GameDataEncoding.JSON, SFTypesScript.GameDataEncoding.MESSAGE_PACK],
			info.game_data_formats,
			"upstream protocol info formats"
		)

	var authority_response := _first_event(server_events, "authority_response")
	if authority_response != null:
		_assert_equal(true, authority_response.args[0], "upstream authority granted")
		_assert_equal("", authority_response.args[1], "upstream null reason decodes to empty")

	var game_starting := _first_event(server_events, "game_starting")
	if game_starting != null:
		var peers: Array[SFTypesScript.PeerConnectionInfo] = game_starting.args[0]
		_assert_equal(2, peers.size(), "upstream game starting peer count")
		_assert_equal(null, peers[1].connection_info, "upstream peer without connection")

	var reconnected := _first_event(server_events, "reconnected")
	if reconnected != null:
		var missed_events: Array[SFTypesScript.DecodedEvent] = reconnected.args[1]
		_assert_equal(0, missed_events.size(), "upstream reconnected missed events")

	var lobby_state_changed := _first_event(server_events, "lobby_state_changed")
	if lobby_state_changed != null:
		_assert_equal(
			SFTypesScript.LobbyState.LOBBY, lobby_state_changed.args[0], "upstream lobby state"
		)
		var ready_players: PackedStringArray = lobby_state_changed.args[1]
		_assert_equal(1, ready_players.size(), "upstream ready players")

	var spectator_left := _first_event(server_events, "spectator_left")
	if spectator_left != null:
		_assert_equal(
			SFTypesScript.SpectatorReason.VOLUNTARY_LEAVE,
			spectator_left.args[2],
			"upstream spectator left reason"
		)

	var server_errors := _events(server_events, "server_error")
	_assert_equal(2, server_errors.size(), "upstream error sample count")
	if server_errors.size() == 2:
		_assert_equal(
			SFErrorCodesScript.Code.ROOM_FULL, server_errors[0].args[1], "error room full"
		)
		_assert_equal(
			SFErrorCodesScript.Code.GAME_START_NOT_READY,
			server_errors[1].args[1],
			"error game start not ready"
		)


## The published v3 shapes that constrain the codec, pinned by name. The
## v0.10.0 v3-only ProtocolInfo fields have no typed surface yet (the rust
## binding still pins v0.9.1): tolerance means they ride in [code]raw[/code]
## without failing decode.
func _check_v3_published_shape_pins(server_events: Array[SFTypesScript.DecodedEvent]) -> void:
	var protocol_infos := _events(server_events, "protocol_info")
	_assert_equal(2, protocol_infos.size(), "v3 protocol info sample count")
	if protocol_infos.size() == 2:
		var info: SFTypesScript.ProtocolInfo = protocol_infos[0].args[0]
		_assert_equal(
			[SFTypesScript.GameDataEncoding.JSON, SFTypesScript.GameDataEncoding.MESSAGE_PACK],
			info.game_data_formats,
			"v3 protocol info formats"
		)
		_assert_equal(
			SFTypeUtils.string_or_empty(info.raw.get("implementation_version")),
			"0.10.0",
			"v3-only implementation_version survives in raw"
		)
		var extended: SFTypesScript.ProtocolInfo = protocol_infos[1].args[0]
		_assert_equal(
			[
				SFTypesScript.GameDataEncoding.JSON,
				SFTypesScript.GameDataEncoding.MESSAGE_PACK,
				SFTypesScript.GameDataEncoding.RKYV,
				SFTypesScript.GameDataEncoding.PROTOBUF,
			],
			extended.game_data_formats,
			"v3 protocol info advertises every published encoding"
		)

	var going_aways := _events(server_events, "going_away")
	_assert_equal(1, going_aways.size(), "going away sample count")
	if going_aways.size() == 1:
		_assert_equal(1700000000000, going_aways[0].args[0], "going away deadline")
		_assert_equal(30, going_aways[0].args[1], "going away retry hint")

	var delivery_reports := _events(server_events, "delivery_report")
	_assert_equal(1, delivery_reports.size(), "delivery report sample count")
	if delivery_reports.size() == 1:
		var report: SFSessionTypesScript.DeliveryReportInfo = delivery_reports[0].args[0]
		_assert_equal(
			8, report.counters_for("reliable").get_count("delivered"), "reliable delivered"
		)
		_assert_equal(1, report.counters_for("latest").get_count("superseded"), "latest superseded")
		_assert_equal(
			4, report.counters_for("volatile").get_count("delivered"), "volatile delivered"
		)
		_assert_equal(1, report.gaps.size(), "delivery report gap count")
		if report.gaps.size() == 1:
			_assert_equal(
				SFSessionTypesScript.DeliveryGapReason.LATEST_SUPERSEDED,
				report.gaps[0].reason,
				"delivery gap reason"
			)
			_assert_equal(
				"00000000-0000-0000-0000-00000000000b",
				report.gaps[0].from_player,
				"delivery gap sender"
			)

	var operation_results := _events(server_events, "room_operation_result")
	_assert_equal(3, operation_results.size(), "room operation result sample count")
	if operation_results.size() == 3:
		var result_types := {}
		for decoded: SFTypesScript.DecodedEvent in operation_results:
			var result: SFSessionTypesScript.RoomOperationResultInfo = decoded.args[0]
			result_types[result.result_type] = true
			_assert_equal(
				true, SFTypeUtils.is_canonical_uuid_text(result.operation_id), "operation id shape"
			)
		for expected_type: String in ["RoomLeft", "PlayerKicked", "RoomCodeRegenerated"]:
			if not result_types.has(expected_type):
				_failures.append("no room operation result sample decodes to %s" % expected_type)


## Upstream grows the server surface between releases by adding optional
## payload fields (the v0.9.1...v0.10.0 diff added three; two land on
## server payloads), while the rust binding pin defers their typed surface
## here. Tolerance contract: every server sample keeps decoding with a
## synthetic future field on the payload, one level nested, and inside a
## nested list entry; a map of objects grows by adding a key with a
## well-formed entry, so the probe mirrors the container's shape. An
## additive upstream release must never strand a pinned client with a
## protocol error.
func _check_server_samples_tolerate_future_fields() -> void:
	var probes := 0
	for path: String in [SERVER_SAMPLES, SERVER_SAMPLES_V3]:
		for line: String in _read_sample_lines(path):
			probes += _check_future_field_tolerance(path, line)
	_assert_equal(FUTURE_FIELD_PROBE_COUNT, probes, "future-field probe count")


func _check_future_field_tolerance(path: String, line: String) -> int:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_failures.append("%s: sample line is not a JSON object: %s" % [path, _line_summary(line)])
		return 0
	var message: Dictionary = parsed
	if not message.has("data") or typeof(message["data"]) != TYPE_DICTIONARY:
		# Unit variants (Pong, RoomLeft) take no payload upstream, so they
		# cannot gain a field.
		return 0
	var data: Dictionary = message["data"]
	var type_name: String = message.get("type", "")
	var probes := 1
	_check_tolerates_future_field(path, type_name, data, "")
	for key: String in data:
		var value: Variant = data[key]
		if typeof(value) == TYPE_DICTIONARY:
			_check_tolerates_future_field(path, type_name, data, key)
			probes += 1
		elif typeof(value) == TYPE_ARRAY:
			var entries: Array = value
			if not entries.is_empty() and typeof(entries[0]) == TYPE_DICTIONARY:
				_check_tolerates_future_field_in_list(path, type_name, data, key)
				probes += 1
	return probes


func _check_tolerates_future_field(
	path: String, type_name: String, data: Dictionary, nested_key: String
) -> void:
	var probe: Dictionary = data.duplicate(true)
	var site := "data"
	if nested_key.is_empty():
		probe["sf_future_field"] = true
	else:
		var nested: Dictionary = probe[nested_key]
		nested["sf_future_field"] = _future_field_value(nested)
		site = "data.%s" % nested_key
	_decode_must_tolerate(path, type_name, probe, site)


func _future_field_value(member: Dictionary) -> Variant:
	for value: Variant in member.values():
		if typeof(value) == TYPE_DICTIONARY:
			var entry: Dictionary = value
			return entry.duplicate(true)
	return true


func _check_tolerates_future_field_in_list(
	path: String, type_name: String, data: Dictionary, list_key: String
) -> void:
	var probe: Dictionary = data.duplicate(true)
	var entries: Array = probe[list_key]
	var entry: Dictionary = entries[0]
	entry["sf_future_field"] = true
	_decode_must_tolerate(path, type_name, probe, "data.%s[0]" % list_key)


func _decode_must_tolerate(path: String, type_name: String, data: Dictionary, site: String) -> void:
	var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(
		JSON.stringify({"type": type_name, "data": data})
	)
	if decoded == null or decoded.signal_name == &"protocol_error":
		var detail := "null decode"
		if decoded != null and not decoded.args.is_empty():
			detail = str(decoded.args[0])
		_failures.append(
			"%s: %s refused a future field at %s: %s" % [path, type_name, site, detail]
		)


func _test_all_client_samples_are_client_messages() -> void:
	var known := {}
	for message_type: String in CLIENT_MESSAGE_TYPES:
		known[message_type] = true
	var lines := _read_sample_lines(CLIENT_SAMPLES)
	_assert_equal(15, lines.size(), "%s content line count" % CLIENT_SAMPLES)
	for line: String in lines:
		_check_client_sample_line(CLIENT_SAMPLES, line, known)
	_done()


func _test_all_v3_client_samples_are_client_messages() -> void:
	var known := {}
	for message_type: String in CLIENT_MESSAGE_TYPES_V3:
		known[message_type] = true
	var lines := _read_sample_lines(CLIENT_SAMPLES_V3)
	_assert_equal(10, lines.size(), "%s content line count" % CLIENT_SAMPLES_V3)
	for line: String in lines:
		_check_client_sample_line(CLIENT_SAMPLES_V3, line, known)
	_done()


func _check_client_sample_line(path: String, line: String, known: Dictionary) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_failures.append("%s: sample line is not a JSON object: %s" % [path, _line_summary(line)])
		return
	var message: Dictionary = parsed
	var message_type: String = message.get("type", "")
	if not known.has(message_type):
		_failures.append("%s: unknown client message type %s" % [path, message_type])


func _first_event(
	events: Array[SFTypesScript.DecodedEvent], signal_text: String
) -> SFTypesScript.DecodedEvent:
	var matches := _events(events, signal_text)
	return matches[0] if not matches.is_empty() else null


func _events(
	events: Array[SFTypesScript.DecodedEvent], signal_text: String
) -> Array[SFTypesScript.DecodedEvent]:
	var matches: Array[SFTypesScript.DecodedEvent] = []
	for decoded: SFTypesScript.DecodedEvent in events:
		if decoded.signal_name == StringName(signal_text):
			matches.append(decoded)
	return matches


func _read_sample_lines(path: String) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append(
			"failed to open %s: %s" % [path, error_string(FileAccess.get_open_error())]
		)
		return PackedStringArray()
	var lines := PackedStringArray()
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		lines.append(line)
	return lines


func _line_summary(line: String) -> String:
	return line.left(120)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)
