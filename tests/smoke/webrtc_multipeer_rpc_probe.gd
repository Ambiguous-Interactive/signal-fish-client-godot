extends "res://tests/smoke/webrtc_rpc_probe.gd"

const CHUNKS := 64
const WINDOW := 8

var targets: Array[int] = []
var sent_by_peer: Dictionary = {}
var acknowledged: Dictionary = {}
var received_by_peer: Dictionary = {}
var samples_seen: Dictionary = {}
var last_ordered: Dictionary = {}
var credit_started: Dictionary = {}
var credit_times: Dictionary = {}
var peak_outstanding: Dictionary = {}


func reset_multi(new_phase: int, new_seat: int, peers: Array[int]) -> void:
	phase = new_phase
	seat = new_seat
	targets = peers
	failure = ""
	sent_by_peer.clear()
	acknowledged.clear()
	received_by_peer.clear()
	samples_seen.clear()
	last_ordered.clear()
	credit_started.clear()
	credit_times.clear()
	peak_outstanding.clear()
	for peer: int in targets:
		sent_by_peer[peer] = 0
		acknowledged[peer] = 0
		received_by_peer[peer] = [0, 0, 0]
		samples_seen[peer] = [{}, {}]
		last_ordered[peer] = -1
		credit_times[peer] = []
		peak_outstanding[peer] = 0


func send_batch() -> void:
	for peer: int in targets:
		for _batch: int in 4:
			var sequence: int = sent_by_peer[peer]
			var acked: int = acknowledged[peer]
			if sequence >= CHUNKS or sequence - acked >= WINDOW:
				break
			if sequence == acked:
				credit_started[peer] = Time.get_ticks_usec()
			if rpc_id(peer, "mesh_snapshot", phase, sequence, _bytes(peer, 2, sequence)) != OK:
				failure = "multi-peer snapshot RPC send failed"
			if sequence < SAMPLES:
				if rpc_id(peer, "mesh_position", phase, sequence, _bytes(peer, 0, sequence)) != OK:
					failure = "multi-peer position RPC send failed"
				if rpc_id(peer, "mesh_ordered", phase, sequence, _bytes(peer, 1, sequence)) != OK:
					failure = "multi-peer ordered RPC send failed"
			sent_by_peer[peer] = sequence + 1
			var peak: int = peak_outstanding[peer]
			peak_outstanding[peer] = maxi(peak, sequence + 1 - acked)


func complete() -> bool:
	for peer: int in targets:
		var peer_counts: Array = received_by_peer[peer]
		if (
			acknowledged[peer] != CHUNKS
			or peer_counts[2] != CHUNKS
			or peer_counts[0] != SAMPLES
			or peer_counts[1] != SAMPLES
		):
			return false
	return failure.is_empty()


func pair_complete(peer: int) -> bool:
	var peer_counts: Array = received_by_peer[peer]
	return (
		acknowledged[peer] == CHUNKS
		and peer_counts[2] == CHUNKS
		and peer_counts[0] == SAMPLES
		and peer_counts[1] == SAMPLES
	)


func evidence() -> Dictionary:
	var waits: Dictionary = {}
	for peer: int in targets:
		if sent_by_peer[peer] - acknowledged[peer] == WINDOW:
			waits[peer] = Time.get_ticks_usec() - credit_started[peer]
	return {
		"phase": phase,
		"sent_by_peer": sent_by_peer.duplicate(),
		"acknowledged_by_peer": acknowledged.duplicate(),
		"received_by_peer_and_mode": received_by_peer.duplicate(true),
		"peak_outstanding_by_peer": peak_outstanding.duplicate(),
		"credit_round_trip_us_by_peer": credit_times.duplicate(true),
		"credit_wait_age_us_by_peer": waits,
		"failure": failure
	}


func _bytes(target: int, mode: int, sequence: int, sender: int = 0) -> PackedByteArray:
	var text := (
		"phase=%d sender=%d target=%d mode=%d sequence=%d:"
		% [phase, multiplayer.get_unique_id() if sender == 0 else sender, target, mode, sequence]
	)
	if mode == 2:
		text += "snapshot".repeat(140)
	return text.to_utf8_buffer()


@rpc("any_peer", "call_remote", "reliable")
func mesh_snapshot(generation: int, sequence: int, data: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if (
		not targets.has(sender)
		or generation != phase
		or sequence >= CHUNKS
		or sequence != received_by_peer[sender][2]
		or data != _bytes(multiplayer.get_unique_id(), 2, sequence, sender)
	):
		failure = "multi-peer snapshot RPC sender, generation, sequence or bytes differ"
		return
	received_by_peer[sender][2] += 1
	var consumed: int = received_by_peer[sender][2]
	if consumed % WINDOW == 0:
		if rpc_id(sender, "mesh_credit", phase, consumed) != OK:
			failure = "multi-peer credit RPC send failed"


@rpc("any_peer", "call_remote", "reliable")
func mesh_credit(generation: int, consumed: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if (
		not targets.has(sender)
		or generation != phase
		or consumed != acknowledged[sender] + WINDOW
		or consumed > sent_by_peer[sender]
	):
		failure = "multi-peer credit RPC sender, generation or count differs"
		return
	acknowledged[sender] = consumed
	var timings: Array = credit_times[sender]
	timings.append(Time.get_ticks_usec() - credit_started[sender])


@rpc("any_peer", "call_remote", "unreliable")
func mesh_position(generation: int, sequence: int, data: PackedByteArray) -> void:
	_receive_multi_sample(generation, sequence, data, 0)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func mesh_ordered(generation: int, sequence: int, data: PackedByteArray) -> void:
	_receive_multi_sample(generation, sequence, data, 1)


func _receive_multi_sample(
	generation: int, sequence: int, data: PackedByteArray, mode: int
) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if (
		not targets.has(sender)
		or generation != phase
		or sequence < 0
		or sequence >= SAMPLES
		or sequence in samples_seen[sender][mode]
		or (mode == 1 and sequence <= last_ordered[sender])
		or data != _bytes(multiplayer.get_unique_id(), mode, sequence, sender)
	):
		failure = "multi-peer position RPC sender, generation, sequence or bytes differ"
		return
	samples_seen[sender][mode][sequence] = true
	if mode == 1:
		last_ordered[sender] = sequence
	received_by_peer[sender][mode] += 1
