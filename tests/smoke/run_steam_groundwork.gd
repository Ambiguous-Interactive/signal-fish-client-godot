extends SceneTree

## Opt-in groundwork for the Steam live drill (issue #317): the real
## GodotSteam GDExtension is installed and the Steam client is absent, so the
## suite pins the opposite direction of the fake-seam suites - the singleton
## registers, Steamworks init fails cleanly without a client, and
## SFSteamIdentityBootstrap.start() refuses with ERR_UNAVAILABLE instead of
## half-starting or crashing. Run via:
## python3 -E scripts/run-runtime-checks.py steam-ext

const SFSteamIdentityBootstrapScript = preload(
	"res://addons/signal_fish/steam/sf_steam_identity_bootstrap.gd"
)
const SignalFishClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")

var _failures: Array[String] = []
# Completion sentinel: an abort inside _run() skips quit() and would
# otherwise hang CI instead of reporting a red result.
var _run_completed := false


func _initialize() -> void:
	_run()
	if not _run_completed:
		push_error("steam groundwork aborted before completion")
		for failure: String in _failures:
			push_error(failure)
		quit(1)
		return
	if _failures.is_empty():
		print("steam groundwork passed")
		quit(0)
		return
	push_error("steam groundwork failed: %d failure(s)" % _failures.size())
	for failure: String in _failures:
		push_error(failure)
	quit(1)


func _run() -> void:
	_phase_singleton_surface()
	_phase_init_without_client()
	_phase_bootstrap_start()
	_run_completed = true


func _phase_singleton_surface() -> void:
	# The lane installs the GDExtension before this suite runs; a missing
	# singleton means the install or the import scan broke, and every later
	# phase would be vacuous.
	if not Engine.has_singleton("Steam"):
		_failures.append("the GodotSteam GDExtension did not register the Steam singleton")
		return
	var steam: Object = Engine.get_singleton("Steam")
	for method: String in [
		"getSteamID",
		"steamInit",
		"steamInitEx",
		"sendP2PPacket",
		"acceptP2PSessionWithUser",
		"closeP2PSessionWithUser",
		"getAvailableP2PPacketSize",
		"readP2PPacket",
		"getP2PSessionState",
	]:
		if not steam.has_method(method):
			_failures.append("singleton surface missing %s" % method)
	for signal_name: String in ["p2p_session_request", "p2p_session_connect_fail"]:
		if not steam.has_signal(signal_name):
			_failures.append("singleton surface missing signal %s" % signal_name)


func _phase_init_without_client() -> void:
	# No Steam client runs on this machine: Steamworks must report the failure
	# through its return values instead of crashing, and the id must stay 0.
	var steam: Object = Engine.get_singleton("Steam")
	var init_result: bool = steam.call("steamInit")
	_assert_equal(false, init_result, "steamInit fails without a Steam client")
	var init_ex: Dictionary = steam.call("steamInitEx")
	_assert_equal(TYPE_DICTIONARY, typeof(init_ex), "steamInitEx returns a dictionary")
	var status: int = init_ex.get("status", -1)
	if status == 0:
		_failures.append("steamInitEx status 0 (OK) without a Steam client")
	_assert_equal(0, steam.call("getSteamID"), "uninitialized getSteamID is 0")


func _phase_bootstrap_start() -> void:
	# The real seam resolves through the singleton, so start() must refuse on
	# the unusable id (exactly what the fake-seam suite asserts for a hollow
	# seam), leave the coordination off, and survive the engine's "not
	# initialized" diagnostics without crashing.
	var bootstrap: SFSteamIdentityBootstrapScript = SFSteamIdentityBootstrapScript.new()
	var client: SignalFishClientScript = SignalFishClientScript.new()
	_assert_equal(OK, bootstrap.attach(client), "attach")
	_assert_equal(ERR_UNAVAILABLE, bootstrap.start(), "start without initialized Steamworks")
	_assert_equal(false, bootstrap.is_coordinating(), "failed start does not coordinate")
	bootstrap.stop()
	bootstrap.free()
	client.free()


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected == actual:
		return
	var expected_text := "%s (%s)" % [var_to_str(expected), type_string(typeof(expected))]
	var actual_text := "%s (%s)" % [var_to_str(actual), type_string(typeof(actual))]
	_failures.append("%s: expected %s, got %s" % [label, expected_text, actual_text])
