extends RefCounted


static func run() -> Dictionary:
	var connection := WebRTCPeerConnection.new()
	var result := {"engine": Engine.get_version_info()["string"], "valid": false, "channels": []}
	if connection.initialize({}) != OK:
		return result
	var valid := true
	# The Web bridge converts an unset browser property (null) to zero (#433).
	var unset := 0 if OS.has_feature("web") else -1
	for index: int in 4:
		var options := {"negotiated": true, "id": 10 + index, "ordered": index != 2}
		if index in [1, 2]:
			options["maxPacketLifeTime"] = 100
		elif index == 3:
			options["maxPacketLifetime"] = 100
		var channel := connection.create_data_channel("lifetime-control-%d" % index, options)
		if channel == null:
			valid = false
			continue
		var lifetime := channel.get_max_packet_life_time()
		var retransmits := channel.get_max_retransmits()
		var expected := 100 if index in [1, 2] else unset
		valid = valid and lifetime == expected and retransmits == unset
		valid = valid and channel.is_ordered() == options["ordered"]
		var channels: Array = result["channels"]
		channels.append(
			{
				"options": options,
				"max_packet_life_time": lifetime,
				"max_retransmits": retransmits,
				"ordered": channel.is_ordered()
			}
		)
		channel.close()
	connection.close()
	result["valid"] = valid
	return result
