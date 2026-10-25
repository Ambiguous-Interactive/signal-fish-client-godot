extends Node

const SAMPLES := 32
const CHUNK_BYTES := 1200

var phase := 0
var seat := 0
var expected_peer := 0
var outgoing := PackedByteArray()
var expected := PackedByteArray()
var received := PackedByteArray()
var counts: Array[int] = [0, 0, 0]
var last_sequence: Array[int] = [-1, -1]
var seen: Array[Dictionary] = [{}, {}]
var sent := 0
var failure := ""
var partial_sent := 0
var partial_received := 0
var retired_received := 0


func reset_transfer(new_phase: int, new_seat: int, peer: int) -> void:
	phase = new_phase
	seat = new_seat
	expected_peer = peer
	received.clear()
	counts = [0, 0, 0]
	last_sequence = [-1, -1]
	seen = [{}, {}]
	sent = 0
	failure = ""
	partial_sent = 0
	partial_received = 0
	retired_received = 0


func send_batch() -> void:
	var total := ceili(float(outgoing.size()) / CHUNK_BYTES)
	for _batch: int in 4:
		if sent >= total:
			break
		var chunk := outgoing.slice(sent * CHUNK_BYTES, (sent + 1) * CHUNK_BYTES)
		if rpc_id(expected_peer, "snapshot_chunk", sent, chunk) != OK:
			failure = "snapshot RPC send failed"
		if sent < SAMPLES:
			if rpc_id(expected_peer, "position", sent, _sample(sent, 0, seat)) != OK:
				failure = "unreliable RPC send failed"
			if rpc_id(expected_peer, "ordered_position", sent, _sample(sent, 1, seat)) != OK:
				failure = "ordered RPC send failed"
		sent += 1


func complete() -> bool:
	return (
		sent == ceili(float(outgoing.size()) / CHUNK_BYTES)
		and received == expected
		and counts[0] > 0
		and counts[1] > 0
	)


func evidence() -> Dictionary:
	return {
		"phase": phase,
		"counts": counts,
		"sent_chunks": sent,
		"received_bytes": received.size(),
		"expected_bytes": expected.size(),
		"partial_sent": partial_sent,
		"partial_received": partial_received,
		"retired_received": retired_received,
		"failure": failure
	}


@rpc("any_peer", "call_remote", "reliable")
func snapshot_chunk(sequence: int, data: PackedByteArray) -> void:
	var start := counts[2] * CHUNK_BYTES
	if (
		multiplayer.get_remote_sender_id() != expected_peer
		or sequence != counts[2]
		or data != expected.slice(start, start + CHUNK_BYTES)
		or start >= expected.size()
	):
		failure = "snapshot RPC sender, sequence or bytes differ"
		return
	received.append_array(data)
	counts[2] += 1


@rpc("any_peer", "call_remote", "unreliable")
func position(sequence: int, data: PackedByteArray) -> void:
	_receive_sample(sequence, data, 0)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func ordered_position(sequence: int, data: PackedByteArray) -> void:
	_receive_sample(sequence, data, 1)


func _receive_sample(sequence: int, data: PackedByteArray, mode: int) -> void:
	if (
		multiplayer.get_remote_sender_id() != expected_peer
		or sequence < 0
		or sequence >= SAMPLES
		or data != _sample(sequence, mode, 1 - seat)
		or seen[mode].has(sequence)
		or (mode == 1 and sequence <= last_sequence[mode])
	):
		failure = "position RPC sender, sequence or bytes differ"
		return
	seen[mode][sequence] = true
	last_sequence[mode] = sequence
	counts[mode] += 1


func _sample(sequence: int, mode: int, sender_seat: int) -> PackedByteArray:
	return (
		("phase=%d seat=%d position=%d mode=%d" % [phase, sender_seat, sequence, mode])
		. to_utf8_buffer()
	)


func send_partial() -> void:
	for sequence: int in 4:
		var chunk := outgoing.slice(sequence * CHUNK_BYTES, (sequence + 1) * CHUNK_BYTES)
		if rpc_id(expected_peer, "partial_chunk", sequence, chunk) != OK:
			failure = "partial snapshot RPC send failed"
		partial_sent += 1


@rpc("any_peer", "call_remote", "reliable")
func partial_chunk(sequence: int, data: PackedByteArray) -> void:
	var start := partial_received * CHUNK_BYTES
	if (
		multiplayer.get_remote_sender_id() != expected_peer
		or sequence != partial_received
		or sequence >= 4
		or data != expected.slice(start, start + CHUNK_BYTES)
	):
		failure = "partial snapshot RPC sender, sequence or bytes differ"
		return
	partial_received += 1


@rpc("any_peer", "call_remote", "reliable")
func retired_chunk(_data: PackedByteArray) -> void:
	retired_received += 1
	failure = "retired RPC executed after link closure"
