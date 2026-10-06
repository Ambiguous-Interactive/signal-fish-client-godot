extends SceneTree

## Opt-in Steam live-drill harness (issue #318): the #315 validation checklist
## as a script, so drill runs produce per-assertion data instead of prose.
##
## Modes:
##  - fake (default): a two-seat loopback self-test. Both seats run the real
##    SFSteamIdentityBootstrap against linked fake Steam seams, so the whole
##    checklist is asserted deterministically without a Steam client. This is
##    the CI-green mode.
##  - live: one seat against real Steamworks and a real relay (--seat picks
##    which side). Without the GodotSteam singleton or an initialized
##    Steamworks the run reports status "pending" with the reason instead of
##    failing - fakes alone cannot close #315, and neither can a machine with
##    no seat. Checklist outcomes are read off the captured signal stream;
##    items nobody drove stay pending in the drill record.
##
## Run:
##  python3 -E scripts/run-runtime-checks.py steam-drill
##  godot --headless --path . --script tests/smoke/run_steam_live_drill.gd ++
##   --mode=live --seat=host --endpoint=wss://example/socket --app=APP_ID
##   --player=Host [--game=signal-fish] [--room=CODE] [--out=drill.json]
##   [--deadline-sec=60]

const ClientFixtures = preload("res://tests/client/client_fixtures.gd")
const SFFakeTransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const SFSteamIdentityBootstrapScript = preload(
	"res://addons/signal_fish/steam/sf_steam_identity_bootstrap.gd"
)
const SFSteamIdentityScript = preload("res://addons/signal_fish/steam/sf_steam_identity.gd")
const SFTypesScript = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const SignalFishConfigScript = preload("res://addons/signal_fish/signal_fish_config.gd")

const HOST_PLAYER := "10000000-0000-0000-0000-000000000001"
const PEER_PLAYER := "10000000-0000-0000-0000-000000000002"
const LATE_PLAYER := "10000000-0000-0000-0000-000000000003"
const HOST_STEAM_ID := "76561197960265728"
const PEER_STEAM_ID := "76561197960265736"
const STRANGER_STEAM_ID := "76561197960265744"

# The fence grace under drill: the refusal probe pumps past it, so the accept
# timing and the refusal timing both land inside one deterministic schedule.
const ACCEPT_GRACE_SEC := 5.0
const PUMP_DELTA_SEC := 0.2
const REFUSAL_ROUNDS := 27
const DEFAULT_DEADLINE_SEC := 60.0
# Covers an abort before any seat exists (live mode); the seat deadline
# takes over once one does.
const LIVE_WATCHDOG_MS := 10000
const KNOWN_KEYS: Array[String] = [
	"mode",
	"seat",
	"endpoint",
	"app",
	"player",
	"game",
	"room",
	"out",
	"deadline-sec",
]
const CAPTURED_SIGNALS: Array[String] = [
	"steam_host_id_received",
	"steam_host_connected",
	"steam_peer_connected",
	"steam_peer_disconnected",
	"coordination_failed",
]
const USAGE := (
	"usage: run_steam_live_drill.gd [--mode=fake|live] [--seat=host|peer]"
	+ " [--endpoint=URL] [--app=APP_ID] [--player=NAME] [--game=NAME]"
	+ " [--room=CODE] [--out=PATH] [--deadline-sec=SEC]"
)

var _assertions: Array[Dictionary] = []
var _fake_seats: Array[DrillSeat] = []
# The harness clock: fake mode advances it in deterministic pump rounds, live
# mode reads wall time through it, so capture stamps share one time base.
var _clock_ms := 0.0
var _started_ms := 0
var _finished := false
var _failed := false
var _pending_reason := ""
# Live-seat state: a phase machine pumped from _process until the seat's
# milestone, a terminal client event, or the deadline.
var _live_seat: DrillSeat = null
var _args: Dictionary = {}
var _live_milestone := ""
var _relayed_frames: Dictionary = {}
var _checklist_recorded := false


func _initialize() -> void:
	_started_ms = Time.get_ticks_msec()
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	if args.is_empty():
		return
	_args = args
	if args["mode"] == "live":
		_begin_live(args)
		return
	_run_fake_loopback()
	if not _finished:
		# Completion sentinel: an abort inside the fake loopback skips quit()
		# and would otherwise hang CI instead of reporting a red result.
		push_error("steam live drill aborted before completion")
		for assertion: Dictionary in _assertions:
			push_error(str(assertion))
		quit(1)


func _process(_delta: float) -> bool:
	if not _finished:
		if _live_seat != null:
			_pump_live()
		elif Time.get_ticks_msec() - _started_ms > LIVE_WATCHDOG_MS:
			# An abort before the seat exists (arg parse, dial setup) must
			# fail red instead of hanging a driver that waits on exit.
			push_error("steam live drill aborted before any seat started")
			quit(1)
	return false


# -- argument parsing ---------------------------------------------------------


func _parse_args(raw: PackedStringArray) -> Dictionary:
	var args: Dictionary = {"mode": "fake"}
	for entry: String in raw:
		if not entry.begins_with("--") or not entry.contains("="):
			_usage_error("unrecognized argument %s" % entry)
			return {}
		var parts := entry.substr(2).split("=", true, 1)
		if not parts[0] in KNOWN_KEYS:
			_usage_error("unknown key --%s" % parts[0])
			return {}
		args[parts[0]] = parts[1]
	if not args["mode"] in ["fake", "live"]:
		_usage_error("--mode must be fake or live")
		return {}
	if args["mode"] == "live":
		return _live_args_checked(args)
	for key: String in KNOWN_KEYS:
		if key != "mode" and key != "out" and args.has(key):
			_usage_error("--%s only applies to --mode=live" % key)
			return {}
	return args


func _live_args_checked(args: Dictionary) -> Dictionary:
	for key: String in ["seat", "endpoint", "app", "player"]:
		var value: String = args.get(key, "")
		if value.is_empty():
			_usage_error("live mode requires --%s" % key)
			return {}
	if not args["seat"] in ["host", "peer"]:
		_usage_error("--seat must be host or peer")
		return {}
	args["deadline_sec"] = DEFAULT_DEADLINE_SEC
	if args.has("deadline-sec"):
		# Args arrive as strings; a direct float assignment is a runtime
		# type error, so validate the text first.
		var raw_deadline: String = args["deadline-sec"]
		if not raw_deadline.is_valid_float() or raw_deadline.to_float() <= 0.0:
			_usage_error("--deadline-sec must be a positive number")
			return {}
		args["deadline_sec"] = raw_deadline.to_float()
	return args


func _usage_error(detail: String) -> void:
	push_error("steam live drill: %s" % detail)
	push_error(USAGE)
	quit(2)


# -- fake loopback: two seats, linked seams, the full #315 checklist ----------


func _run_fake_loopback() -> void:
	var host := _make_seat(SFSteamIdentityBootstrapScript.Role.HOST, HOST_STEAM_ID)
	var peer := _make_seat(SFSteamIdentityBootstrapScript.Role.PEER, PEER_STEAM_ID)
	_fake_seats = [host, peer]
	_join_fake_room(host, SFSteamIdentityBootstrapScript.Role.HOST, HOST_PLAYER)
	_join_fake_room(peer, SFSteamIdentityBootstrapScript.Role.PEER, PEER_PLAYER)
	host.steam.partner = peer.steam
	peer.steam.partner = host.steam
	var host_error: Error = host.bootstrap.start()
	_record_assert("host_start", host_error == OK, host_error, "fake loopback host seat")
	var peer_error: Error = peer.bootstrap.start()
	_record_assert("peer_start", peer_error == OK, peer_error, "fake loopback peer seat")
	_phase_publishes(host, peer)
	_phase_handshake(host, peer)
	_phase_unadvertised_refusal(host)
	_phase_leave_detection(host, peer)
	_phase_authority_loss(host)
	# Break the seam partner cycle and drop the seat refs, or RefCounted
	# teardown leaks them past the engine's exit check.
	host.steam.partner = null
	peer.steam.partner = null
	for seat: DrillSeat in _fake_seats:
		seat.dispose()
	_fake_seats = []
	_finish()


func _phase_publishes(host: DrillSeat, peer: DrillSeat) -> void:
	_pump_round()
	_record_assert(
		"host_id_publish",
		_host_envelope_count(host) >= 1,
		_host_envelope_count(host),
		"host envelope on the room lane"
	)
	_record_assert(
		"peer_id_publish",
		_peer_envelope_count(peer) >= 1,
		_peer_envelope_count(peer),
		"peer envelope on the room lane"
	)
	# The relay hands the host id to the peer, which consumes it and dials;
	# the poke arrives while the peer is still un-advertised, arming the fence.
	_relay_game_data(host, peer)
	_pump_round()
	var received: Array[Dictionary] = peer.captures("steam_host_id_received")
	var got_host_id: bool = not received.is_empty() and received[0]["value"] == HOST_STEAM_ID
	_record_assert(
		"peer_host_id_received", got_host_id, _first_value(received), "consumed from the lane"
	)
	# Late join: a third player joining re-publishes the ids so a late
	# bootstrap never depends on timing (issue #315 checklist item 1).
	var publishes_before := _host_envelope_count(host)
	_relay_join(host, LATE_PLAYER, "Late")
	_record_assert(
		"host_id_republish_on_late_join",
		_host_envelope_count(host) == publishes_before + 1,
		"%d -> %d" % [publishes_before, _host_envelope_count(host)],
		"re-publish on PlayerJoined"
	)


func _phase_handshake(host: DrillSeat, peer: DrillSeat) -> void:
	# The peer advertisement crosses the lane; a pending requester is accepted
	# on the spot and the ack closes the peer's dial on the next pump.
	_relay_game_data(peer, host)
	_pump_round()
	var requests: Array[Dictionary] = host.steam.requests
	var dialed: bool = not requests.is_empty() and requests[0]["id"] == int(PEER_STEAM_ID)
	_record_assert(
		"peer_dial_reaches_fence", dialed, _request_ids(requests), "poke arrives as a request"
	)
	var connected: Array[Dictionary] = host.captures("steam_peer_connected")
	var fenced: bool = not connected.is_empty() and connected[0]["value"] == PEER_STEAM_ID
	var elapsed := _fence_elapsed_ms(connected, requests)
	_record_assert(
		"fence_accept_within_grace",
		fenced and elapsed >= 0.0 and elapsed < ACCEPT_GRACE_SEC * 1000.0,
		_fms(elapsed),
		"held until the lane advertisement, accepted inside the grace"
	)
	var host_connected: Array[Dictionary] = peer.captures("steam_host_connected")
	var handshook: bool = (
		not host_connected.is_empty() and host_connected[0]["value"] == HOST_STEAM_ID
	)
	_record_assert(
		"peer_steam_host_connected", handshook, _first_value(host_connected), "ack closed the dial"
	)
	var ack_shape := "no ack sent"
	for sent: Dictionary in host.steam.sends:
		if sent["remote"] == int(PEER_STEAM_ID) and sent["data"] == PackedByteArray([0x41]):
			ack_shape = "0x41 ack to the peer on channel %s" % sent["channel"]
	_record_assert("handshake_reply_shape", _ack_matches(host.steam.sends), ack_shape, "one-byte")


func _phase_unadvertised_refusal(host: DrillSeat) -> void:
	var requested_at := _clock_ms
	host.steam.request_session(int(STRANGER_STEAM_ID))
	for _round: int in REFUSAL_ROUNDS:
		_pump_round()
	var closed_at := host.steam.refusal_of(int(STRANGER_STEAM_ID))
	var latency := -1.0 if closed_at < 0.0 else closed_at - requested_at
	_record_assert(
		"unadvertised_requester_refused",
		closed_at >= 0.0,
		_fms(latency),
		(
			"closed after %s with no advertisement (%s grace)"
			% [_fms(latency), _fms(ACCEPT_GRACE_SEC * 1000.0)]
		)
	)
	var strangers: Array[Dictionary] = host.captures_of("steam_peer_connected", STRANGER_STEAM_ID)
	_record_assert(
		"refused_requester_not_connected",
		strangers.is_empty(),
		_first_value(strangers),
		"no signal"
	)


func _phase_leave_detection(host: DrillSeat, peer: DrillSeat) -> void:
	host.steam.set_session_active(int(PEER_STEAM_ID), false)
	_pump_round()
	var drops: Array[Dictionary] = host.captures("steam_peer_disconnected")
	var dropped: bool = not drops.is_empty() and drops[0]["value"] == PEER_STEAM_ID
	_record_assert(
		"peer_leave_detected", dropped, _first_value(drops), "session state went inactive"
	)
	# The session death is visible at both ends, so the peer's host session
	# closes and its coordination fails with it.
	var peer_failures: Array[Dictionary] = peer.captures("coordination_failed")
	var expected := "the host Steam session closed"
	var peer_failed: bool = not peer_failures.is_empty() and peer_failures[0]["value"] == expected
	_record_assert(
		"host_drop_fails_peer_coordination",
		peer_failed,
		_first_value(peer_failures),
		"the peer sees the same session death"
	)


func _phase_authority_loss(host: DrillSeat) -> void:
	var transport: SFFakeTransportScript = host.client.transport
	(
		transport
		. inject_server_message(
			{
				"type": "AuthorityChanged",
				"data": {"authority_player": PEER_PLAYER, "you_are_authority": false},
			}
		)
	)
	host.client.poll()
	var failures: Array[Dictionary] = host.captures("coordination_failed")
	var expected := "authority left the host; the fence has no holder"
	var failed: bool = not failures.is_empty() and failures[0]["value"] == expected
	_record_assert(
		"authority_loss_fails_coordination",
		failed and not host.bootstrap.is_coordinating(),
		_first_value(failures),
		"coordination stops with the fence holder gone"
	)


# -- live seat: one process, one side of the drill ----------------------------


func _begin_live(args: Dictionary) -> void:
	var steam: Object = _resolve_live_steam()
	if steam == null:
		_finish()
		return
	var role: SFSteamIdentityBootstrapScript.Role = (
		SFSteamIdentityBootstrapScript.Role.HOST
		if args["seat"] == "host"
		else SFSteamIdentityBootstrapScript.Role.PEER
	)
	var seat := _make_seat(role, "")
	seat.bootstrap.steam = steam
	_live_milestone = (
		"steam_peer_connected"
		if role == SFSteamIdentityBootstrapScript.Role.HOST
		else "steam_host_connected"
	)
	_wire_live_client(seat)
	var config := SignalFishConfigScript.new()
	var app_id: String = args["app"]
	config.app_id = app_id
	config.auto_poll = false
	var error: Error = seat.client.configure(config)
	if error == OK:
		var endpoint: String = args["endpoint"]
		error = seat.client.connect_to_server(endpoint)
	if error != OK:
		seat.dispose()
		_fail_live("live dial failed (%d)" % error)
		return
	_live_seat = seat
	var seat_name: String = args["seat"]
	_record_assert("seat_started", true, seat_name, "live seat dialing")


func _resolve_live_steam() -> Object:
	if not Engine.has_singleton("Steam"):
		_pending("the GodotSteam singleton is absent; install the GDExtension (see steam-ext)")
		return null
	var steam: Object = Engine.get_singleton("Steam")
	var init_result: Variant = steam.call("steamInitEx")
	if typeof(init_result) != TYPE_DICTIONARY:
		_pending("steamInitEx returned no dictionary; the GDExtension surface changed")
		return null
	var init: Dictionary = init_result
	var init_status: int = init.get("status", -1)
	if init_status != 0:
		_pending("Steamworks did not initialize: %s" % str(init.get("verbal", "no detail")))
		return null
	var steam_id := str(steam.call("getSteamID"))
	if not SFSteamIdentityScript.is_valid_steam_id(steam_id):
		_pending("getSteamID() returned no usable id (%s)" % steam_id)
		return null
	_record_assert("steamworks_initialized", true, steam_id, "seat id")
	return steam


func _wire_live_client(seat: DrillSeat) -> void:
	seat.client.connected.connect(_on_live_connected)
	seat.client.authenticated.connect(_on_live_authenticated)
	seat.client.room_joined.connect(_on_live_room_joined)
	seat.client.room_join_failed.connect(
		func(reason: String, error_code: int) -> void:
			_fail_live("room join failed: %s (code %d)" % [reason, error_code])
	)
	seat.client.connection_failed.connect(
		func(error: String) -> void: _fail_live("connection failed: %s" % error)
	)
	seat.client.disconnected.connect(
		func(code: int, reason: String) -> void:
			_fail_live("disconnected before the milestone: %d %s" % [code, reason])
	)


func _on_live_connected() -> void:
	_record_assert("relay_connected", true, "open", "dial acknowledged")


func _on_live_authenticated(
	_app_name: String, _organization: String, _rate_limits: SFTypesScript.RateLimitInfo
) -> void:
	var params := SignalFishClientScript.JoinRoomParams.new()
	var game_name: String = _args.get("game", "signal-fish")
	var player_name: String = _args["player"]
	var room_code: String = _args.get("room", "")
	params.game_name = game_name
	params.player_name = player_name
	params.room_code = room_code
	var error: Error = _live_seat.client.join_room(params)
	if error != OK:
		_fail_live("join_room refused (%d)" % error)


func _on_live_room_joined(info: SFTypesScript.RoomJoinedInfo) -> void:
	_record_assert("room_joined", true, info.room_code, "the fence lane is live")
	var error: Error = _live_seat.bootstrap.attach(_live_seat.client)
	# The bootstrap joins the tree so its own clock (grace expiries, dial
	# deadlines) runs on real frames; the client is pumped manually below.
	if error == OK:
		root.add_child(_live_seat.bootstrap)
		error = _live_seat.bootstrap.start()
	if error != OK:
		if _live_seat.bootstrap.is_inside_tree():
			root.remove_child(_live_seat.bootstrap)
		_live_seat.dispose()
		_fail_live("bootstrap start failed (%d)" % error)


func _pump_live() -> void:
	# Captures stamp the harness clock; live mode reads wall time.
	_clock_ms = float(Time.get_ticks_msec() - _started_ms)
	var steam: Object = _live_seat.bootstrap.steam
	if steam != null and steam.has_method("run_callbacks"):
		steam.call("run_callbacks")
	_live_seat.client.poll()
	var failures: Array[Dictionary] = _live_seat.captures("coordination_failed")
	if not failures.is_empty():
		_fail_live("coordination failed: %s" % _first_value(failures))
		return
	var milestones: Array[Dictionary] = _live_seat.captures(_live_milestone)
	if milestones.is_empty() and not _deadline_hit():
		return
	if milestones.is_empty():
		_pending("the deadline elapsed before %s" % _live_milestone)
	_record_checklist_from_captures()
	_finish()


func _deadline_hit() -> bool:
	var elapsed := float(Time.get_ticks_msec() - _started_ms)
	var deadline_sec: float = _args["deadline_sec"]
	return elapsed > deadline_sec * 1000.0


func _fail_live(detail: String) -> void:
	if _finished:
		return
	_record_checklist_from_captures()
	_record_assert("seat_milestone", false, detail, "live run aborted")
	_finish()


func _record_checklist_from_captures() -> void:
	if _live_seat == null or _checklist_recorded:
		return
	_checklist_recorded = true
	if _args["seat"] == "host":
		_record_milestone(
			"fence_accept_within_grace",
			_live_seat.captures("steam_peer_connected"),
			"no peer was fenced inside the window"
		)
		_record_milestone(
			"peer_leave_detected",
			_live_seat.captures("steam_peer_disconnected"),
			"no leave was driven inside the window"
		)
	else:
		_record_milestone(
			"peer_host_id_received",
			_live_seat.captures("steam_host_id_received"),
			"no host id arrived inside the window"
		)
		_record_milestone(
			"peer_steam_host_connected",
			_live_seat.captures("steam_host_connected"),
			"the dial never completed inside the window"
		)
	# Only an authority-reason failure verifies this item: a spontaneous
	# coordination failure is data, not a driven checklist pass.
	var authority_reason := "authority left the host; the fence has no holder"
	var failures: Array[Dictionary] = _live_seat.captures("coordination_failed")
	if failures.is_empty():
		_record("authority_loss_fails_coordination", "pending", "", "no authority loss was driven")
		return
	for failure: Dictionary in failures:
		if failure["value"] == authority_reason:
			_record_assert("authority_loss_fails_coordination", true, failure["value"], "captured")
			return
	_record(
		"authority_loss_fails_coordination",
		"failed",
		_first_value(failures),
		"a different failure landed; nobody drove authority loss"
	)


func _record_milestone(name: String, captures: Array[Dictionary], pending_detail: String) -> void:
	if captures.is_empty():
		_record(name, "pending", "", pending_detail)
		return
	var first: Dictionary = captures[0]
	var captured_at: float = first["at_ms"]
	_record_assert(
		name, true, "%s @%.0f ms" % [first["value"], captured_at], "captured with timing"
	)


# -- shared: assertion records, report, teardown ------------------------------


func _record(name: String, outcome: String, value: Variant, detail: String) -> void:
	(
		_assertions
		. append(
			{
				"name": name,
				"outcome": outcome,
				"elapsed_ms": snappedf(_clock_ms, 0.1),
				"value": str(value),
				"detail": detail,
			}
		)
	)


func _record_assert(name: String, ok: bool, value: Variant, detail: String) -> void:
	if not ok:
		_failed = true
	_record(name, "passed" if ok else "failed", value, detail)


func _pending(reason: String) -> void:
	_pending_reason = reason


func _finish() -> void:
	if _finished:
		return
	_finished = true
	var status := "failed" if _failed else "passed"
	if not _failed and not _pending_reason.is_empty():
		status = "pending"
	var mode: String = _args.get("mode", "fake")
	var seat_name: String = _args.get("seat", "loopback")
	var report: Dictionary = {
		"status": status,
		"mode": mode,
		"seat": seat_name,
		"generated_at": Time.get_datetime_string_from_system(true),
		"elapsed_ms": snappedf(float(Time.get_ticks_msec() - _started_ms), 0.1),
		"assertions": _assertions,
	}
	if not _pending_reason.is_empty():
		report["pending_reason"] = _pending_reason
	var text := JSON.stringify(report, "  ")
	var out_path: String = _args.get("out", "")
	if not out_path.is_empty():
		var file := FileAccess.open(out_path, FileAccess.WRITE)
		if file != null:
			file.store_string(text)
			file.close()
		else:
			# A drill run whose requested record was not written is red:
			# the operator must never walk away believing a record exists.
			_failed = true
			status = "failed"
			report["status"] = status
			text = JSON.stringify(report, "  ")
			push_error("steam live drill: could not write --out %s" % out_path)
	print(text)
	print("steam live drill %s" % status)
	quit(1 if _failed else 0)


# -- fake loopback plumbing: seats, clock, room relay -------------------------


func _make_seat(role: SFSteamIdentityBootstrapScript.Role, steam_id: String) -> DrillSeat:
	var seat := DrillSeat.new(role, steam_id, func() -> float: return _clock_ms)
	seat.bootstrap.accept_grace_sec = ACCEPT_GRACE_SEC
	for signal_name: String in CAPTURED_SIGNALS:
		seat.bootstrap.connect(signal_name, _on_seat_capture.bind(seat, signal_name))
	return seat


func _on_seat_capture(value: String, seat: DrillSeat, signal_name: String) -> void:
	var entries: Array[Dictionary] = seat.captured[signal_name]
	entries.append({"value": value, "at_ms": _clock_ms})


func _join_fake_room(
	seat: DrillSeat, role: SFSteamIdentityBootstrapScript.Role, player_id: String
) -> void:
	seat.player_id = player_id
	var config := SignalFishConfigScript.new()
	config.app_id = "steam-drill"
	config.sdk_version = "0.1.0"
	config.platform = "linux"
	config.game_data_format = "json"
	seat.client.configure(config)
	seat.client.transport = SFFakeTransportScript.new()
	seat.client.connect_to_server("ws://drill.test/socket")
	var transport: SFFakeTransportScript = seat.client.transport
	transport.inject_open()
	transport.inject_server_message(
		{"type": "Authenticated", "data": ClientFixtures.authenticated_data()}
	)
	(
		transport
		. inject_server_message(
			{
				"type": "RoomJoined",
				"data":
				(
					ClientFixtures
					. room_joined_data(
						{
							"player_id": player_id,
							"is_authority": role == SFSteamIdentityBootstrapScript.Role.HOST,
							"current_players": [ClientFixtures.player(player_id, "Seat")],
							"current_spectators": [],
						}
					)
				),
			}
		)
	)
	seat.bootstrap.attach(seat.client)
	seat.client.poll()


func _pump_round() -> void:
	_clock_ms += PUMP_DELTA_SEC * 1000.0
	for seat: DrillSeat in _fake_seats:
		seat.bootstrap._process(PUMP_DELTA_SEC)


func _relay_join(seat: DrillSeat, player_id: String, display_name: String) -> void:
	var transport: SFFakeTransportScript = seat.client.transport
	(
		transport
		. inject_server_message(
			{
				"type": "PlayerJoined",
				"data": {"player": ClientFixtures.player(player_id, display_name)},
			}
		)
	)
	seat.client.poll()


## The room relay: the server wraps every published payload with the sender's
## player id, so the loopback re-wraps each new GameData frame the same way
## before injecting it into the other seat.
func _relay_game_data(from_seat: DrillSeat, to_seat: DrillSeat) -> void:
	var transport: SFFakeTransportScript = from_seat.client.transport
	var relayed: int = _relayed_frames.get(from_seat.client, 0)
	for index: int in range(relayed, transport.sent_text.size()):
		var envelope: Variant = JSON.parse_string(transport.sent_text[index])
		if typeof(envelope) != TYPE_DICTIONARY:
			continue
		var frame: Dictionary = envelope
		if frame.get("type") != "GameData":
			continue
		# Sent GameData frames wrap the payload one level deep (the server
		# adds from_player on delivery); unwrap before re-wrapping the way
		# the room delivers it.
		var wrapper: Dictionary = frame["data"]
		var target: SFFakeTransportScript = to_seat.client.transport
		(
			target
			. inject_server_message(
				{
					"type": "GameData",
					"data": {"from_player": from_seat.player_id, "data": wrapper["data"]},
				}
			)
		)
		to_seat.client.poll()
	_relayed_frames[from_seat.client] = transport.sent_text.size()


func _game_data_payloads(seat: DrillSeat, lane_key: String) -> Array[Dictionary]:
	var payloads: Array[Dictionary] = []
	var transport: SFFakeTransportScript = seat.client.transport
	for text: String in transport.sent_text:
		var envelope: Variant = JSON.parse_string(text)
		if typeof(envelope) != TYPE_DICTIONARY:
			continue
		var frame: Dictionary = envelope
		if frame.get("type") != "GameData":
			continue
		# Sent frames wrap the payload: {"type": "GameData", "data":
		# {"data": <lane envelope>}}.
		var wrapper: Dictionary = frame["data"]
		var payload: Variant = wrapper.get("data", {})
		if typeof(payload) != TYPE_DICTIONARY:
			continue
		var lane_payload: Dictionary = payload
		if lane_payload.has(lane_key):
			payloads.append(lane_payload)
	return payloads


func _host_envelope_count(seat: DrillSeat) -> int:
	return _game_data_payloads(seat, SFSteamIdentityScript.HOST_LANE_KEY).size()


func _peer_envelope_count(seat: DrillSeat) -> int:
	return _game_data_payloads(seat, SFSteamIdentityScript.PEER_LANE_KEY).size()


func _fence_elapsed_ms(connected: Array[Dictionary], requests: Array[Dictionary]) -> float:
	if connected.is_empty() or requests.is_empty():
		return -1.0
	var accepted_at: float = connected[0]["at_ms"]
	var requested_at: float = requests[0]["at_ms"]
	return accepted_at - requested_at


func _ack_matches(sends: Array[Dictionary]) -> bool:
	for sent: Dictionary in sends:
		if (
			sent["remote"] == int(PEER_STEAM_ID)
			and sent["data"] == PackedByteArray([0x41])
			and sent["send_type"] == SFSteamIdentityBootstrapScript.P2P_SEND_RELIABLE
			and sent["channel"] == 1
		):
			return true
	return false


func _request_ids(requests: Array[Dictionary]) -> String:
	var ids: Array[String] = []
	for request: Dictionary in requests:
		ids.append(str(request["id"]))
	return ", ".join(ids)


func _first_value(captures: Array[Dictionary]) -> String:
	return "" if captures.is_empty() else str(captures[0]["value"])


func _fms(ms: float) -> String:
	return "%.0f ms" % ms


## One drill seat: a client plus the real bootstrap. Fake loopback seats ride
## the fake transport and a linked fake seam; the live seat swaps the seam for
## the real GodotSteam singleton. Captures carry the harness clock so
## assertions can time the fence and the handshake against it.
class DrillSeat:
	extends RefCounted

	var client: SignalFishClientScript
	var bootstrap: SFSteamIdentityBootstrapScript
	var steam: LinkedSteam
	var player_id := ""
	var captured: Dictionary = {}

	func _init(
		role: SFSteamIdentityBootstrapScript.Role, steam_id: String, clock: Callable
	) -> void:
		client = SignalFishClientScript.new()
		steam = LinkedSteam.new(steam_id, clock)
		bootstrap = SFSteamIdentityBootstrapScript.new()
		bootstrap.role = role
		bootstrap.steam = steam
		for signal_name: String in CAPTURED_SIGNALS:
			var entries: Array[Dictionary] = []
			captured[signal_name] = entries

	func captures(signal_name: String) -> Array[Dictionary]:
		return captured[signal_name]

	func captures_of(signal_name: String, value: String) -> Array[Dictionary]:
		var matches: Array[Dictionary] = []
		for capture: Dictionary in captures(signal_name):
			if capture["value"] == value:
				matches.append(capture)
		return matches

	## Named for the teardown it does: `free` would collide with the native
	## Object.free, which refuses RefCounted receivers.
	func dispose() -> void:
		bootstrap.free()
		client.free()


## Two loopback seams emulating Steam's session choreography: a packet to a
## remote makes the session known there, and p2p_session_request fires only
## on a remote that never initiated traffic itself - so the host's handshake
## reply rides the peer-initiated session instead of re-requesting it.
class LinkedSteam:
	extends RefCounted

	signal p2p_session_request(remote_steam_id: int)
	@warning_ignore("unused_signal")
	signal p2p_session_connect_fail(remote_steam_id: int, session_error: int)

	var sends: Array[Dictionary] = []
	var requests: Array[Dictionary] = []
	var closes: Array[Dictionary] = []
	var accepts: Array[int] = []
	var received: Array[Dictionary] = []
	var initiated: Dictionary = {}
	var session_states: Dictionary = {}
	var partner: Object = null
	var local_id := 0
	var clock: Callable

	func _init(id: String, clock_callable: Callable) -> void:
		local_id = int(id)
		clock = clock_callable

	# gdlint: disable=function-name
	func getSteamID() -> int:
		return local_id

	func sendP2PPacket(
		remote_steam_id: int, data: PackedByteArray, send_type: int, channel: int
	) -> bool:
		sends.append(
			{"remote": remote_steam_id, "data": data, "send_type": send_type, "channel": channel}
		)
		initiated[remote_steam_id] = true
		set_session_active(remote_steam_id, true)
		if partner != null:
			partner.call("deliver_from", local_id, data)
		return true

	func acceptP2PSessionWithUser(remote_steam_id: int) -> bool:
		accepts.append(remote_steam_id)
		set_session_active(remote_steam_id, true)
		return true

	func closeP2PSessionWithUser(remote_steam_id: int) -> bool:
		closes.append({"id": remote_steam_id, "at_ms": clock.call()})
		set_session_active(remote_steam_id, false)
		return true

	func getAvailableP2PPacketSize(_channel: int) -> int:
		return received.size()

	func readP2PPacket(_packet_size: int, _channel: int) -> Dictionary:
		if received.is_empty():
			return {}
		return received.pop_front()

	func getP2PSessionState(remote_steam_id: int) -> Dictionary:
		if not session_states.has(remote_steam_id):
			return {}
		var entry: Dictionary = session_states[remote_steam_id]
		return {"connection_active": entry["active"], "connecting": entry["connecting"]}

	# gdlint: enable=function-name

	func deliver_from(sender_steam_id: int, data: PackedByteArray) -> void:
		received.append({"data": data, "remote_steam_id": sender_steam_id})
		if not initiated.has(sender_steam_id):
			requests.append({"id": sender_steam_id, "at_ms": clock.call()})
			p2p_session_request.emit(sender_steam_id)

	## The close time of one refusal probe, or -1 when it never came.
	func refusal_of(remote_steam_id: int) -> float:
		for closed: Dictionary in closes:
			if closed["id"] == remote_steam_id:
				return closed["at_ms"]
		return -1.0

	func request_session(remote_steam_id: int) -> void:
		set_session_active(remote_steam_id, true)
		requests.append({"id": remote_steam_id, "at_ms": clock.call()})
		p2p_session_request.emit(remote_steam_id)

	func set_session(remote_steam_id: int, active: bool, connecting: bool) -> void:
		session_states[remote_steam_id] = {"active": active, "connecting": connecting}
		# A session death is visible at both ends; activations stay per-end
		# (each side's own API calls mark its own state).
		if not active and partner != null:
			var partner_id: int = partner.get("local_id")
			if remote_steam_id == partner_id:
				partner.call("mirror_session", local_id)

	func mirror_session(remote_steam_id: int) -> void:
		session_states[remote_steam_id] = {"active": false, "connecting": false}

	func set_session_active(remote_steam_id: int, active: bool) -> void:
		set_session(remote_steam_id, active, false)
