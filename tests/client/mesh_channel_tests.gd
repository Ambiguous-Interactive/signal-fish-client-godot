extends RefCounted

const MeshScript = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const ClientScript = preload("res://addons/signal_fish/signal_fish_client.gd")
const TransportScript = preload("res://tests/transport/sf_fake_transport.gd")
const Messages = preload("res://addons/signal_fish/protocol/sf_messages.gd")
const Session = preload("res://addons/signal_fish/protocol/sf_session_types.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")
const PLAYER_B := "10000000-0000-0000-0000-000000000002"

var _failures: Array[String] = []
var _test_done := false
var _owner: Object


static func run(owner: Object) -> Array[String]:
	var tests := new()
	tests._owner = owner
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [_test_required_channels_control_transport_reports]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _assert_equal(expected: Variant, actual: Variant, label: String) -> void:
	if expected != actual:
		_failures.append(
			"%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(actual)]
		)


func _test_required_channels_control_transport_reports() -> void:
	for channel_index: int in 3:
		for state: int in [WebRTCDataChannel.STATE_CLOSING, WebRTCDataChannel.STATE_CLOSED]:
			var client: ClientScript = _owner.call("_make_in_room_client")
			var mesh: MeshScript = _owner.call("_make_mesh")
			_owner.call("_attach", mesh, client)
			var peers: Array[Dictionary] = [_owner.call("_peer", PLAYER_B, false)]
			_owner.call("_inject_plan", client, peers)
			var created: Array = _owner.call("_mesh_peers", mesh)
			var pc: Object = created[0]
			var channels: Array = pc.get("channels")
			var channel: Object = channels[channel_index]
			pc.set("state", WebRTCPeerConnection.STATE_CONNECTED)
			channel.set("state", WebRTCDataChannel.STATE_CONNECTING)
			var transport: TransportScript = client.transport
			var before: int = transport.sent_text.size()
			mesh.poll()
			_assert_equal(
				[],
				_owner.call("_sent_after", client, before),
				"pending required channel cannot report up"
			)
			channel.set("state", WebRTCDataChannel.STATE_OPEN)
			mesh.poll()
			_assert_equal(1, _sent_count(client, before), "all channels open reports up")
			channel.set("state", state)
			mesh.poll()
			_assert_equal(
				Messages.encode(Messages.transport_status(Session.TransportKind.WEBRTC, false)),
				transport.sent_text.back(),
				"closed required channel reports down while peer connection stays connected"
			)
			_assert_equal(
				WebRTCPeerConnection.STATE_CONNECTED,
				pc.get("state"),
				"physical connection is still connected"
			)
			var multiplayer: Object = _owner.call("_mesh_multiplayer", mesh)
			multiplayer.call("remove_peer", MeshScript.uuid_to_peer_id(PLAYER_B))
			channel.set("state", WebRTCDataChannel.STATE_OPEN)
			mesh.poll()
			_assert_equal(2, _sent_count(client, before), "engine removal cannot revive report")
			_owner.call("_inject_plan", client, peers, "40000000-0000-0000-0000-000000000002")
			var replacement: Object = created[1]
			replacement.set("state", WebRTCPeerConnection.STATE_CONNECTED)
			mesh.poll()
			_assert_equal(3, _sent_count(client, before), "fresh link reports up again")
			mesh.free()
			client.free()
	_done()


func _sent_count(client: ClientScript, before: int) -> int:
	var sent: Array = _owner.call("_sent_after", client, before)
	return sent.size()
