extends RefCounted

## Pins the codec to the concrete v2 wire samples upstream publishes as of
## signal-fish-server v0.9.2 (issue #55). Every sample line must decode, every
## v2 server event must appear, and the published shapes that constrain the
## codec are pinned by name so drift surfaces as a named failure.

const SFEventsScript = preload("res://addons/signal_fish/protocol/sf_events.gd")
const SFErrorCodesScript = preload("res://addons/signal_fish/protocol/sf_error_codes.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const SERVER_SAMPLES := "res://tests/fixtures/upstream/v2_server_messages.jsonl"
const CLIENT_SAMPLES := "res://tests/fixtures/upstream/v2_client_messages.jsonl"

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

var _failures: Array = []
var _test_done := false


func _done() -> void:
	_test_done = true


static func run() -> Array:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var server_events := _decode_all_server_samples()
	_check_all_expected_signals_present(server_events)
	_check_published_shape_pins(server_events)
	var cases: Array[Callable] = [
		_test_all_client_samples_are_client_messages,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _decode_all_server_samples() -> Array:
	var events: Array = []
	for line: String in _read_sample_lines(SERVER_SAMPLES):
		var decoded: SFTypesScript.DecodedEvent = SFEventsScript.decode_text(line)
		if decoded == null or decoded.signal_name == &"protocol_error":
			_failures.append(
				"%s: sample line failed to decode: %s" % [SERVER_SAMPLES, _line_summary(line)]
			)
			continue
		events.append(decoded)
	return events


func _check_all_expected_signals_present(server_events: Array) -> void:
	var seen := {}
	for decoded: SFTypesScript.DecodedEvent in server_events:
		var signal_text := String(decoded.signal_name)
		seen[signal_text] = seen.get(signal_text, 0) + 1
	for expected: String in EXPECTED_SERVER_SIGNALS:
		if not seen.has(expected):
			_failures.append("%s: no sample decodes to %s" % [SERVER_SAMPLES, expected])
	_assert_equal(24, server_events.size(), "sample decode count")


func _check_published_shape_pins(server_events: Array) -> void:
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
		var peers: Array = game_starting.args[0]
		_assert_equal(2, peers.size(), "upstream game starting peer count")
		_assert_equal(null, peers[1].connection_info, "upstream peer without connection")

	var reconnected := _first_event(server_events, "reconnected")
	if reconnected != null:
		var missed_events: Array = reconnected.args[1]
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


func _test_all_client_samples_are_client_messages() -> void:
	var known := {}
	for message_type: String in CLIENT_MESSAGE_TYPES:
		known[message_type] = true
	for line: String in _read_sample_lines(CLIENT_SAMPLES):
		var parsed: Variant = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			_failures.append(
				"%s: sample line is not a JSON object: %s" % [CLIENT_SAMPLES, _line_summary(line)]
			)
			continue
		var message: Dictionary = parsed
		var message_type: String = message.get("type", "")
		if not known.has(message_type):
			_failures.append("%s: unknown client message type %s" % [CLIENT_SAMPLES, message_type])
	_done()


func _first_event(events: Array, signal_text: String) -> SFTypesScript.DecodedEvent:
	var matches := _events(events, signal_text)
	return matches[0] if not matches.is_empty() else null


func _events(events: Array, signal_text: String) -> Array:
	var matches: Array = []
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
