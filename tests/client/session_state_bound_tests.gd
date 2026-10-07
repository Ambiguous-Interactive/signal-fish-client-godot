extends RefCounted

## Session-state bound tests (issue #274). A hostile relay must not grow
## session state (rosters, secret-redaction list) without a bound; receives
## the client runner instance so connect/auth fakes stay defined in one place.

const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SFLogScript = preload("res://addons/signal_fish/protocol/sf_log.gd")
const SFTypeUtils = preload("res://addons/signal_fish/protocol/sf_type_utils.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

const PLAYER_B := "10000000-0000-0000-0000-000000000002"

var _failures: Array[String] = []
var _test_done := false
var _runner: Object = null


func _done() -> void:
	_test_done = true


static func run(runner: Object) -> Array[String]:
	var tests := new()
	tests._runner = runner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [
		_test_over_cap_baseline_clamps,
		_test_duplicate_baseline_ids_fail_closed,
		_test_roster_growth_stays_bounded,
		_test_secret_list_stays_bounded,
		_test_pinned_secret_list_stays_bounded,
		_test_live_credential_stays_redacted,
	]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


## Issue #274: precedent `MAX_MISSED_EVENTS` — cap plus one diagnostic per
## refused event. Data-driven across both rosters: baselines clamp to the
## cap, refused joins stay untracked, and a freed slot accepts again.


func _test_over_cap_baseline_clamps() -> void:
	var cap := SFTypeUtils.MAX_TRACKED_PEERS
	for flow: String in ["players", "spectators"]:
		var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
		var errors: Array[String] = _runner.call("_track_protocol_errors", client)
		var members: Array = []
		for index: int in cap + 1:
			members.append(_bulk_roster_member(flow, index))
		_inject_roster_baseline(client, flow, members)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s baseline clamps to the cap" % flow)
		_assert_equal(1, errors.size(), "%s clamped baseline emits one diagnostic" % flow)
		_assert_string_contains(errors[0], "dropped 1", "%s diagnostic counts the drop" % flow)
		client.free()
	_done()


func _test_roster_growth_stays_bounded() -> void:
	var cap := SFTypeUtils.MAX_TRACKED_PEERS
	for flow: String in ["players", "spectators"]:
		var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
		var fake: SFFakeTransportScript = client.transport
		var errors: Array[String] = _runner.call("_track_protocol_errors", client)
		var joins: Array[String] = []
		if flow == "players":
			client.player_joined.connect(
				func(player: SFTypesScript.PlayerInfo) -> void: joins.append(player.id)
			)
		else:
			client.new_spectator_joined.connect(
				func(spectator: SFTypesScript.SpectatorInfo, _current: Array, _reason: int) -> void:
					joins.append(spectator.id)
			)

		var members: Array = []
		for index: int in cap:
			members.append(_bulk_roster_member(flow, index))
		_inject_roster_baseline(client, flow, members)
		_assert_equal(
			cap, _roster_of(client, flow).size(), "%s baseline installs the full roster" % flow
		)
		_assert_equal(0, errors.size(), "%s baseline at the cap stays silent" % flow)

		var stranger_id: String = _bulk_roster_member(flow, cap)["id"]
		var zero_id: String = _bulk_roster_member(flow, 0)["id"]

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(stranger_id, "Stranger")}}
			)
		else:
			fake.inject_server_message(
				{
					"type": "NewSpectatorJoined",
					"data": {"spectator": _spectator(stranger_id, "Stranger")}
				}
			)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s roster stays at the cap" % flow)
		_assert_equal(1, errors.size(), "%s over-cap join emits one diagnostic" % flow)
		_assert_string_contains(errors[0], "cap %d" % cap, "%s diagnostic names the cap" % flow)
		_assert_equal([stranger_id], joins, "%s refused join still surfaces" % flow)

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(zero_id, "Fresh")}}
			)
		else:
			fake.inject_server_message(
				{"type": "NewSpectatorJoined", "data": {"spectator": _spectator(zero_id, "Fresh")}}
			)
		_assert_equal(
			cap, _roster_of(client, flow).size(), "%s upsert at the cap adds no entry" % flow
		)
		_assert_equal(1, errors.size(), "%s known-id join stays silent" % flow)
		_assert_equal(
			"Fresh", _roster_of(client, flow)[0].name, "%s known-id join updates in place" % flow
		)

		if flow == "players":
			fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": zero_id}})
		else:
			fake.inject_server_message(
				{"type": "SpectatorDisconnected", "data": {"spectator_id": zero_id}}
			)
		_assert_equal(cap - 1, _roster_of(client, flow).size(), "%s leave frees a slot" % flow)
		_assert_equal(1, errors.size(), "%s leave stays silent" % flow)

		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(stranger_id, "Back")}}
			)
		else:
			fake.inject_server_message(
				{
					"type": "NewSpectatorJoined",
					"data": {"spectator": _spectator(stranger_id, "Back")}
				}
			)
		_assert_equal(cap, _roster_of(client, flow).size(), "%s freed slot accepts the join" % flow)
		_assert_equal(1, errors.size(), "%s accepted join stays silent" % flow)
		_assert_equal(
			stranger_id, _roster_of(client, flow)[cap - 1].id, "%s join lands at the tail" % flow
		)
		_assert_equal(
			[stranger_id, zero_id, stranger_id], joins, "%s join events all surface" % flow
		)
		client.free()
	_done()


## Issue #274: hostile baselines cycling fresh reconnection tokens must not
## grow the redaction list; pins are bounded by the same cap (issue #335).


func _test_secret_list_stays_bounded() -> void:
	var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
	var fake: SFFakeTransportScript = client.transport
	var params := SignalFishClientScript.JoinRoomParams.new()
	params.game_name = "g"
	params.player_name = "p"
	params.password = "pinned-pass-not-secret"
	_assert_equal(OK, client.join_room(params), "join_room pins the password")
	var rounds: int = SignalFishClientScript.MAX_REMEMBERED_SECRETS * 4
	for index: int in rounds:
		var baseline: Dictionary = _runner.call(
			"_room_joined_data", {"reconnection_token": "rotated-token-%d-not-secret" % index}
		)
		fake.inject_server_message({"type": "RoomJoined", "data": baseline})
	_assert_equal(1, client._pinned_secrets, "the join password is the only pinned secret")
	_assert_equal(
		client._pinned_secrets + SignalFishClientScript.MAX_REMEMBERED_SECRETS,
		client._secrets.size(),
		"rotating tokens evict oldest past the cap"
	)
	_assert(client._secrets.has("pinned-pass-not-secret"), "the one pinned password stays")
	var freshest := "rotated-token-%d-not-secret" % (rounds - 1)
	_assert(client._secrets.has(freshest), "the freshest token stays redacted")
	_assert(not client._secrets.has("rotated-token-0-not-secret"), "the oldest token ages out")
	client.free()
	_done()


## Issue #335: distinct pins (rotated room passwords) are bounded like the
## rotating half. The newest pin is always the live credential, so
## oldest-first eviction can never unredact it.


func _test_pinned_secret_list_stays_bounded() -> void:
	var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
	var cap: int = SignalFishClientScript.MAX_REMEMBERED_SECRETS
	var rounds := cap + 4
	for index: int in rounds:
		client._remember_secret("pinned-pass-%d-not-secret" % index, true)
	_assert_equal(cap, client._pinned_secrets, "pins clamp to the cap")
	_assert_equal(cap, client._secrets.size(), "only pins remain in the list")
	var freshest := "pinned-pass-%d-not-secret" % (rounds - 1)
	_assert(client._secrets.has(freshest), "the freshest pin (the live credential) stays")
	_assert(not client._secrets.has("pinned-pass-0-not-secret"), "the oldest pin ages out")
	_assert_string_contains(
		SFLogScript.redact("pass %s end" % freshest, client._secrets),
		SFLogScript.REDACTED,
		"the freshest pin still redacts"
	)
	client.free()
	_done()


## Issue #335: the configured credential re-pins on every Authenticate dial,
## so bounded pin eviction can never unredact a credential still in use —
## while an idle credential ages out like any other pin.


func _test_live_credential_stays_redacted() -> void:
	var config: SignalFishConfigScript = _runner.call("_make_config")
	config.credential = "sfk-live-credential-not-secret"
	var client: SignalFishClientScript = _runner.call("_connect_new_client", config)
	var cap: int = SignalFishClientScript.MAX_REMEMBERED_SECRETS
	for index: int in cap + 4:
		client._remember_secret("join-pass-%d-not-secret" % index, true)
	_assert(
		not client._secrets.has("sfk-live-credential-not-secret"),
		"an idle credential ages out like any pin"
	)
	client._send_authenticate()
	_assert(
		client._secrets.has("sfk-live-credential-not-secret"),
		"the dial re-pins the in-use credential"
	)
	_assert_equal(
		"sfk-live-credential-not-secret",
		client._secrets[client._pinned_secrets - 1],
		"the re-pinned credential is the newest pin"
	)
	# A credential that stayed tracked but slid to the eviction end while the
	# client joined other rooms moves back to the newest pin on the dial.
	for index: int in cap - 1:
		client._remember_secret("more-pass-%d-not-secret" % index, true)
	_assert_equal(
		"sfk-live-credential-not-secret",
		client._secrets[0],
		"the stale credential sits at the eviction end"
	)
	client._send_authenticate()
	_assert_equal(
		"sfk-live-credential-not-secret",
		client._secrets[client._pinned_secrets - 1],
		"the dial moves the in-use credential off the eviction end"
	)
	client.free()
	_done()


## A baseline with duplicate ids must not seed the id-keyed roster: joins
## and leaves stop at the first match, so extra entries with a repeated id
## go stale forever and can keep a departed player holding authority.


func _test_duplicate_baseline_ids_fail_closed() -> void:
	var id_a := "000000bb-0000-0000-0000-000000000001"
	var id_b := "000000bb-0000-0000-0000-000000000002"
	for flow: String in ["players", "spectators"]:
		var client: SignalFishClientScript = _runner.call("_make_authenticated_client")
		var fake: SFFakeTransportScript = client.transport
		var errors: Array[String] = _runner.call("_track_protocol_errors", client)
		_inject_roster_baseline(
			client,
			flow,
			[
				_member(flow, id_a, "First"),
				_member(flow, id_a, "Ghost"),
				_member(flow, id_b, "Other")
			]
		)
		var roster := _roster_of(client, flow)
		_assert_equal(2, roster.size(), "%s duplicate baseline keeps one entry per id" % flow)
		_assert_equal(
			"First", roster[0].name, "%s duplicate baseline keeps the first occurrence" % flow
		)
		_assert_equal(1, errors.size(), "%s duplicate baseline emits one diagnostic" % flow)
		_assert_string_contains(
			errors[0], "duplicate", "%s diagnostic names the duplicate drop" % flow
		)
		_assert_string_contains(errors[0], "dropped 1", "%s diagnostic counts the drop" % flow)
		if flow == "players":
			fake.inject_server_message(
				{"type": "PlayerJoined", "data": {"player": _player(id_a, "Renamed")}}
			)
		else:
			fake.inject_server_message(
				{"type": "NewSpectatorJoined", "data": {"spectator": _spectator(id_a, "Renamed")}}
			)
		roster = _roster_of(client, flow)
		_assert_equal("Renamed", roster[0].name, "%s join updates the kept entry" % flow)
		_assert_equal(2, roster.size(), "%s join adds no ghost entry" % flow)
		if flow == "players":
			fake.inject_server_message(
				{
					"type": "AuthorityChanged",
					"data": {"authority_player": id_a, "you_are_authority": false}
				}
			)
			fake.inject_server_message({"type": "PlayerLeft", "data": {"player_id": id_a}})
			_assert_equal(
				"", client.get_authority_player(), "%s leave cannot leave an authority ghost" % flow
			)
		else:
			fake.inject_server_message(
				{"type": "SpectatorDisconnected", "data": {"spectator_id": id_a}}
			)
		roster = _roster_of(client, flow)
		_assert_equal(1, roster.size(), "%s leave removes the departed id fully" % flow)
		_assert_equal(id_b, roster[0].id, "%s only the other member survives" % flow)
		client.free()
	_done()


func _member(flow: String, id: String, display_name: String) -> Dictionary:
	return _player(id, display_name) if flow == "players" else _spectator(id, display_name)


func _inject_roster_baseline(client: SignalFishClientScript, flow: String, members: Array) -> void:
	var fake: SFFakeTransportScript = client.transport
	if flow == "players":
		var baseline: Dictionary = _runner.call("_room_joined_data", {"current_players": members})
		fake.inject_server_message({"type": "RoomJoined", "data": baseline})
		return
	fake.inject_server_message(
		{
			"type": "SpectatorJoined",
			"data":
			{
				"room_id": "20000000-0000-0000-0000-000000000009",
				"room_code": "SPEC1",
				"spectator_id": PLAYER_B,
				"game_name": "reef-rally",
				"current_players": [],
				"current_spectators": members,
				"lobby_state": "waiting"
			}
		}
	)


func _roster_of(client: SignalFishClientScript, flow: String) -> Array:
	if flow == "players":
		return client.get_players()
	return client.get_spectators()


func _bulk_roster_member(flow: String, index: int) -> Dictionary:
	var id := "000000aa-0000-0000-0000-%012d" % index
	return _player(id, "P%04d" % index) if flow == "players" else _spectator(id, "P%04d" % index)


func _player(id: String, display_name: String) -> Dictionary:
	return _runner.call("_player", id, display_name)


func _spectator(id: String, display_name: String) -> Dictionary:
	return _runner.call("_spectator", id, display_name)


func _assert(condition: bool, label: String) -> bool:
	return _runner.call("_assert", condition, label)


func _assert_equal(expected: Variant, actual: Variant, label: String) -> bool:
	return _runner.call("_assert_equal", expected, actual, label)


func _assert_string_contains(actual: String, expected_substring: String, label: String) -> bool:
	return _runner.call("_assert_string_contains", actual, expected_substring, label)
