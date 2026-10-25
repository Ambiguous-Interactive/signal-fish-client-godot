(() => {
  const EnginePeer = window.RTCPeerConnection;
  const peers = new Map();
  let created = 0;
  let closed = 0;
  let sampling = false;
  window.RTCPeerConnection = new Proxy(EnginePeer, {
    construct(target, args, newTarget) {
      const peer = Reflect.construct(target, args, newTarget);
      const id = ++created;
      peers.set(peer, { id, pending: null });
      peer.addEventListener("connectionstatechange", () => {
        if (peer.connectionState === "closed" && peers.delete(peer)) closed++;
      });
      return peer;
    },
  });
  setInterval(async () => {
    if (sampling) return;
    sampling = true;
    try {
      for (const peer of peers.keys()) {
        if (peer.connectionState === "closed") {
          peers.delete(peer);
          closed++;
        }
      }
      const snapshots = await Promise.all(
        [...peers].map(async ([peer, entry]) => {
          const snapshot = {
            id: entry.id,
            connection: peer.connectionState,
            ice: peer.iceConnectionState,
            sctp: peer.sctp?.state ?? null,
            channels: [],
            transports: [],
            candidate_pairs: [],
          };
          let timeout;
          try {
            if (entry.pending)
              throw new Error("previous getStats request pending");
            entry.pending = Promise.resolve(peer.getStats()).finally(() => {
              entry.pending = null;
            });
            const stats = await Promise.race([
              entry.pending,
              new Promise((_, reject) => {
                timeout = setTimeout(
                  () => reject(new Error("getStats timed out after 750ms")),
                  750,
                );
              }),
            ]);
            stats.forEach((stat) => {
              if (stat.type === "data-channel") {
                snapshot.channels.push({
                  channel: stat.dataChannelIdentifier,
                  state: stat.state,
                  messages_sent: stat.messagesSent,
                  messages_received: stat.messagesReceived,
                  bytes_sent: stat.bytesSent,
                  bytes_received: stat.bytesReceived,
                });
              } else if (stat.type === "transport") {
                snapshot.transports.push({
                  dtls: stat.dtlsState,
                  bytes_sent: stat.bytesSent,
                  bytes_received: stat.bytesReceived,
                });
              } else if (stat.type === "candidate-pair" && stat.nominated) {
                snapshot.candidate_pairs.push({
                  state: stat.state,
                  bytes_sent: stat.bytesSent,
                  bytes_received: stat.bytesReceived,
                  round_trip_seconds: stat.currentRoundTripTime,
                });
              }
            });
          } catch (error) {
            snapshot.error = String(error);
          } finally {
            clearTimeout(timeout);
          }
          return snapshot;
        }),
      );
      console.log(
        "WEBRTC_BROWSER_STATS " +
          JSON.stringify({ created, closed, peers: snapshots }),
      );
    } finally {
      sampling = false;
    }
  }, 1000);
})();
