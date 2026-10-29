extends RefCounted

const Drill = preload("res://tests/smoke/active_shutdown.gd")
const CompletionGuard = preload("res://tests/completion_guard.gd")

var _failures: Array[String] = []
var _test_done := false


class FakeClient:
	extends "res://addons/signal_fish/signal_fish_client.gd"
	var sent: Array[Dictionary] = []

	func get_connection_state() -> ConnectionState:
		return ConnectionState.CONNECTED

	func send_game_data(data: Variant) -> Error:
		var payload: Dictionary = data
		sent.append(payload)
		return OK


static func run() -> Array[String]:
	var tests := new()
	tests.run_all()
	return tests._failures


func run_all() -> void:
	var cases: Array[Callable] = [_test_ack_prefix_and_identity, _test_exact_receive_credit]
	CompletionGuard.drive(self, cases, _failures)
	CompletionGuard.check_registration(self, cases, _failures)


func _done() -> void:
	_test_done = true


func _check(value: bool, label: String) -> void:
	if not value:
		_failures.append(label)


func _test_ack_prefix_and_identity() -> void:
	var drill := Drill.new()
	drill.set("_options", {"relay_credit_transport": "app-ack"})
	drill.set("_generation", 2)
	var seat := Drill.Seat.new()
	seat.expected_sender = "remote"
	seat.relay_sent = 2
	seat.transport.observer = Drill.ReceiveObserver.new()
	var ack := {"generation": 2, "room_id": "", "next_sequence": 1}
	drill._receive_relay(seat, "remote", {"shutdown_ack": ack})
	_check(seat.relay_acked == 1 and seat.acks_received == 1, "valid remote ACK advances credit")
	for change: Dictionary in [
		{"next_sequence": 3},
		{"next_sequence": 1.5},
		{"next_sequence": -1},
		{"next_sequence": 0},
		{"next_sequence": "2"},
		{"next_sequence": true},
		{"generation": 1},
		{"room_id": "old"}
	]:
		var corrupt := ack.duplicate()
		corrupt.merge(change, true)
		drill._receive_relay(seat, "remote", {"shutdown_ack": corrupt})
		_check(
			seat.relay_acked == 1 and seat.acks_received == 1,
			"invalid ACK keeps window: " + str(change)
		)
	for sender: String in ["other", "remote"]:
		var invalid_ack: Variant = null
		if sender == "other":
			invalid_ack = ack
		drill._receive_relay(seat, sender, {"shutdown_ack": invalid_ack})
		_check(
			seat.relay_acked == 1 and seat.acks_received == 1,
			"wrong sender or null ACK keeps window"
		)
	drill._receive_relay(seat, "remote", {"shutdown_ack": ack})
	_check(
		seat.relay_acked == 1 and seat.acks_received == 2, "duplicate ACK grants no extra credit"
	)
	seat.client.free()
	seat.mesh.free()
	var http: HTTPRequest = drill.get("_http")
	http.free()
	drill.free()
	_done()


func _test_exact_receive_credit() -> void:
	var drill := Drill.new()
	drill.set("_options", {"relay_credit_transport": "app-ack"})
	drill.set("_generation", 2)
	var seat := Drill.Seat.new()
	seat.client.free()
	var client := FakeClient.new()
	seat.client = client
	seat.expected_sender = "remote"
	seat.transport.observer = Drill.ReceiveObserver.new()
	var body := "0123456789abcdef".repeat(256)
	drill._receive_relay(seat, "remote", {"sequence": 0, "body": body})
	drill._flush_ack(seat)
	_check(
		client.sent.size() == 1 and seat.ack_sent_prefix == 1, "exact receipt returns remote credit"
	)
	drill._flush_ack(seat)
	_check(client.sent.size() == 1, "unchanged prefix sends no redundant ACK")
	for fault: Dictionary in [{"sequence": 2}, {"body": "bad"}, {"sender": "other"}]:
		seat.relay_received = 1
		seat.relay_prefix_valid = true
		var packet := {"sequence": 1, "body": body}
		packet.merge(fault, true)
		var sender: String = fault.get("sender", "remote")
		drill._receive_relay(seat, sender, packet)
		drill._receive_relay(seat, "remote", {"sequence": seat.relay_received, "body": body})
		drill._flush_ack(seat)
		_check(
			not seat.relay_prefix_valid and client.sent.size() == 1,
			"invalid receipt never returns credit: " + str(fault)
		)
	client.free()
	seat.mesh.free()
	var http: HTTPRequest = drill.get("_http")
	http.free()
	drill.free()
	_done()
