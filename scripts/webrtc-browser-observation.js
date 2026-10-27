(() => {
  const EnginePeer = window.RTCPeerConnection;
  const peers = new Map();
  let created = 0;
  let closed = 0;
  let sampling = false;
  const callbackChannels = [];
  const drops = [];
  let dropsOmitted = 0;
  let precedingCallback = null;
  const reportError = console.error;
  console.error = function (...args) {
    if (
      args.some((value) =>
        String(value).includes("Buffer full! Dropping data."),
      )
    ) {
      if (drops.length < 128)
        drops.push({
          ms: performance.now(),
          preceding_callback: precedingCallback,
        });
      else dropsOmitted++;
    }
    return Reflect.apply(reportError, this, args);
  };
  window.webrtcDropSnapshot = () => ({
    records: drops.map((drop) => ({
      ...drop,
      preceding_callback: drop.preceding_callback
        ? { ...drop.preceding_callback }
        : null,
    })),
    dropped: dropsOmitted,
  });
  window.webrtcCallbackSnapshot = () =>
    callbackChannels.map((channel) => ({
      ...channel,
      callbacks: channel.callbacks.slice(),
    }));
  window.RTCPeerConnection = new Proxy(EnginePeer, {
    construct(target, args, newTarget) {
      const peer = Reflect.construct(target, args, newTarget);
      const id = ++created;
      const observedChannels = [];
      peers.set(peer, { id, pending: null, observedChannels });
      const createChannel = peer.createDataChannel;
      peer.createDataChannel = function (label, options) {
        const channel = Reflect.apply(createChannel, this, [label, options]);
        const received = {
          peer: id,
          id: channel.id,
          label: channel.label,
          packets: 0,
          bytes: 0,
          callbacks: [],
          dropped: 0,
        };
        observedChannels.push(received);
        callbackChannels.push(received);
        if (callbackChannels.length > 32) callbackChannels.shift();
        channel.addEventListener("message", (event) => {
          const bytes =
            typeof event.data === "string"
              ? new TextEncoder().encode(event.data).byteLength
              : (event.data.byteLength ?? event.data.size);
          received.packets++;
          received.bytes += bytes;
          if (received.callbacks.length < 1024) {
            const prefix =
              event.data instanceof ArrayBuffer
                ? new TextDecoder().decode(
                    new Uint8Array(event.data, 0, Math.min(96, bytes)),
                  )
                : typeof event.data === "string"
                  ? event.data.slice(0, 96)
                  : "";
            const match =
              /^(snapshot|partial|heartbeat|startup|position):(1|2):(godot|reference):(\d+):/.exec(
                prefix,
              );
            const finite = /^(ordered):(1|2):(godot|reference):(\d+)$/.exec(
              prefix,
            );
            const probe =
              /^(godot|reference):(1|2):(reliable|unreliable)$/.exec(prefix);
            const credit =
              /^(credit|partial-credit|startup-credit):(1|2):(godot|reference):(godot|reference):(\d+)$/.exec(
                prefix,
              );
            received.callbacks.push({
              ms: performance.now(),
              bytes,
              packet:
                (match ?? finite ?? probe ?? credit)?.slice(1).join(":") ??
                null,
            });
          } else received.dropped++;
          precedingCallback = {
            peer: id,
            label: channel.label,
            ...(received.callbacks.at(-1) ?? {}),
          };
          if (received.dropped) precedingCallback = null;
        });
        console.log(
          "WEBRTC_BROWSER_CHANNEL " +
            JSON.stringify({
              peer: id,
              id: channel.id,
              label: channel.label,
              negotiated: channel.negotiated,
              ordered: channel.ordered,
              max_packet_life_time: channel.maxPacketLifeTime,
              max_retransmits: channel.maxRetransmits,
              requested_lifetime: options?.maxPacketLifeTime ?? null,
              requested_misspelled_lifetime: options?.maxPacketLifetime ?? null,
            }),
        );
        return channel;
      };
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
            callbacks: entry.observedChannels.map((channel) => ({
              ...channel,
              callbacks: channel.callbacks.slice(),
            })),
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
