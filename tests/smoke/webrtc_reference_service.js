export function configureReferenceService(url, appId) {
  const socket = new WebSocket(url);
  const inbox = [];
  const evidence = [];
  let failure = null;
  let signalsSent = 0;
  let signalsReceived = 0;
  const send = (type, data) => {
    if (socket.readyState !== WebSocket.OPEN)
      throw new Error("reference service socket is not open");
    socket.send(JSON.stringify(data === undefined ? { type } : { type, data }));
  };
  socket.onopen = () =>
    send("Authenticate", {
      app_id: appId,
      protocol_version: 3,
      supported_transports: ["relay", "webrtc"],
      supported_topologies: ["host"],
    });
  socket.onerror = () => {
    failure = new Error("reference service socket error");
  };
  socket.onclose = () => {
    failure ??= new Error("reference service socket closed");
  };
  socket.onmessage = ({ data }) => {
    try {
      const frame = JSON.parse(data);
      if (
        ["Error", "AuthenticationError", "RoomJoinFailed"].includes(frame.type)
      )
        throw new Error(
          `reference service ${frame.type}: ${JSON.stringify(frame.data)}`,
        );
      inbox.push(frame);
    } catch (error) {
      failure = error;
    }
  };
  const wait = async (predicate, label) => {
    const deadline = performance.now() + 15000;
    while (performance.now() < deadline) {
      if (failure) throw failure;
      const found = await predicate();
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`reference service timeout: ${label}`);
  };
  const take = (type) => {
    const index = inbox.findIndex((frame) => frame.type === type);
    return index < 0 ? null : (inbox.splice(index, 1)[0].data ?? true);
  };
  let loggedIn = false;
  window.referenceService = {
    async begin(phase, seat) {
      if (!loggedIn) {
        await wait(() => take("Authenticated"), "login");
        const protocol = await wait(() => take("ProtocolInfo"), "protocol");
        if (protocol.protocol_version !== 3)
          throw new Error("reference service did not negotiate v3");
        loggedIn = true;
      }
      const room = await wait(async () => {
        const response = await fetch(`/signal/${seat}`);
        if (!response.ok)
          throw new Error(`reference marker GET ${response.status}`);
        const messages = await response.json();
        const unexpected = messages.filter(
          (message) => message.marker !== `service-room-${phase}`,
        );
        if (unexpected.length)
          throw new Error("unexpected message before service room");
        return messages[0];
      }, "Godot room marker");
      send("JoinRoom", {
        game_name: room.game_name,
        room_code: room.room_code,
        player_name: "Reference",
        max_players: 2,
        supports_authority: false,
        join_only: true,
      });
      const joined = await wait(() => take("RoomJoined"), "room admission");
      send("PlayerReady");
      await wait(() => take("GameStarting"), "game start");
      const plan = await wait(() => take("SessionPlan"), "session plan");
      if (
        plan.transport !== "webrtc" ||
        plan.peers.length !== 1 ||
        plan.peers[0].player_id !== room.player_id ||
        !plan.peers[0].initiate
      )
        throw new Error(
          "reference service needs an initiating WebRTC host plan",
        );
      const record = {
        phase,
        room_id: joined.room_id,
        generation: plan.generation,
        player_id: joined.player_id,
        peer_id: room.player_id,
        signals_sent: 0,
        signals_received: 0,
        left: false,
      };
      const sentBefore = signalsSent;
      const receivedBefore = signalsReceived;
      evidence.push(record);
      window.referenceServiceEvidence = evidence;
      return {
        generation: plan.generation,
        initiate: plan.peers[0].initiate,
        iceServers: plan.ice_servers ?? [],
        send(payload) {
          send("Signal", {
            to: room.player_id,
            generation: plan.generation,
            signal: payload,
          });
          signalsSent++;
        },
        drain() {
          if (failure) throw failure;
          const messages = [];
          for (let i = 0; i < inbox.length;) {
            const frame = inbox[i];
            if (frame.type === "Signal") {
              inbox.splice(i, 1);
              if (
                frame.data.from !== room.player_id ||
                frame.data.generation !== plan.generation
              )
                throw new Error("reference service signal identity differs");
              signalsReceived++;
              messages.push({
                generation: plan.generation,
                payload: frame.data.signal,
              });
            } else i++;
          }
          return messages;
        },
        async leave() {
          record.signals_sent = signalsSent - sentBefore;
          record.signals_received = signalsReceived - receivedBefore;
          send("LeaveRoom");
          await wait(() => take("RoomLeft"), "room leave");
          record.left = true;
          console.log("WEBRTC_REFERENCE_SERVICE " + JSON.stringify(record));
          inbox.length = 0;
        },
      };
    },
    close() {
      socket.close();
    },
  };
}
