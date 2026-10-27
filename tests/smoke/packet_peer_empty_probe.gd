extends SceneTree


class ProbePeer:
	extends MultiplayerPeerExtension

	var writes: Array[PackedByteArray] = []
	var reads: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray([42])]

	func _put_packet_script(buffer: PackedByteArray) -> int:
		writes.append(buffer)
		return OK

	func _get_packet_script() -> PackedByteArray:
		return reads.pop_front()

	func _get_available_packet_count() -> int:
		return reads.size()


func _initialize() -> void:
	var peer := ProbePeer.new()
	var empty_send := peer.put_packet(PackedByteArray())
	var writes_after_empty := peer.writes.size()
	var nonempty_send := peer.put_packet(PackedByteArray([42]))
	var empty_receive := peer.get_packet()
	var empty_error := peer.get_packet_error()
	var remaining_after_empty := peer.get_available_packet_count()
	var nonempty_receive := peer.get_packet()
	var nonempty_error := peer.get_packet_error()
	var controls_passed: bool = (
		nonempty_send == OK
		and peer.writes.size() == writes_after_empty + 1
		and peer.writes.back() == PackedByteArray([42])
		and remaining_after_empty == 1
		and nonempty_receive == PackedByteArray([42])
		and nonempty_error == OK
	)
	var empty_passed := (
		empty_send == OK
		and writes_after_empty == 1
		and empty_receive.is_empty()
		and empty_error == OK
	)
	print(
		(
			"PACKET_PEER_EMPTY "
			+ (
				JSON
				. stringify(
					{
						"engine": Engine.get_version_info(),
						"empty_send_error": empty_send,
						"empty_send_callbacks": writes_after_empty,
						"empty_receive_error": empty_error,
						"remaining_after_empty": remaining_after_empty,
						"nonempty_controls_passed": controls_passed,
						"empty_packets_passed": empty_passed,
					}
				)
			)
		)
	)
	quit(0 if controls_passed and empty_passed else 1)
