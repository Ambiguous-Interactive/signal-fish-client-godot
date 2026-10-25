import { Engine } from "/reference/engine.js";

window.referenceError = null;
window.referenceResults = [];
window.runReference = async function (
  godotSeat,
  godotOffer,
  mixedTraffic,
  creditTransport,
) {
  const seat = 1 - godotSeat;
  const post = async (message) => {
    const response = await fetch(`/signal/${godotSeat}`, {
      method: "POST",
      body: JSON.stringify(message),
    });
    if (!response.ok) throw new Error(`relay POST ${response.status}`);
  };
  let engine;
  try {
    for (let phase = 1; phase <= 2; phase++) {
      const generation = `40000000-0000-0000-0000-${String(phase).padStart(12, "0")}`;
      const outgoing = [];
      const received = [];
      const events = [];
      let paired = false;
      let sent = false;
      let snapshotSent = 0;
      let snapshotReceived = 0;
      let snapshotAck = 0;
      let positionsSent = 0;
      const positionsReceived = new Set();
      let peakOutstanding = 0;
      let creditUpdated = performance.now();
      let maxCreditWaitMs = 0;
      let transferStarted = 0;
      let transferMs = -1;
      const position = (sender, sequence) =>
        `position:${phase}:${sender}:${sequence}:` +
        "0123456789abcdef".repeat(4);
      const acceptCredit = (count) => {
        if (count > snapshotAck) {
          maxCreditWaitMs = Math.max(
            maxCreditWaitMs,
            Math.round(performance.now() - creditUpdated),
          );
          snapshotAck = count;
          creditUpdated = performance.now();
        }
      };
      let partialSent = 0;
      let partialReceived = 0;
      const chunk = (sender, sequence, partial = false) =>
        `${partial ? "partial" : "snapshot"}:${phase}:${sender}:${sequence}:` +
        "0123456789abcdef".repeat(64);
      let observed = false;
      let closeRequested = false;
      let closeQueued = false;
      let remoteClosed = false;
      let retired = false;
      let heartbeatSent = 0;
      let heartbeatReceived = 0;
      let nextHeartbeat = 0;
      const heartbeat = (sequence) =>
        `heartbeat:${phase}:reference:${sequence}:` +
        "0123456789abcdef".repeat(4);
      const controller = new AbortController();
      let signalingTask = null;
      let signalingError = null;
      let started = performance.now();
      let nextProgress = 0;
      engine = new Engine(false, {
        onLocalCandidate: (_peer, _generation, candidate) =>
          outgoing.push({ payload: { IceCandidate: candidate } }),
        onPcState: (_peer, _generation, state) => events.push(["state", state]),
        onChannelOpen: (_peer, _generation, label) => {
          events.push(["open", label]);
          engine.noteChannelOpen("godot", label);
        },
        onChannelClosed: (_peer, _generation, label, reason) =>
          events.push(["closed", label, reason]),
        onChannelMessage: (_peer, _generation, label, text) => {
          if (text.startsWith("heartbeat:")) {
            if (
              !mixedTraffic ||
              label !== "reliable" ||
              heartbeatReceived >= heartbeatSent ||
              text !== heartbeat(heartbeatReceived)
            ) {
              window.referenceError =
                "reference heartbeat bytes or metadata differ";
              return false;
            }
            heartbeatReceived++;
            return true;
          }
          if (text.startsWith("credit:")) {
            const count = Number(text.split(":").at(-1));
            if (
              creditTransport !== "webrtc" ||
              label !== "reliable" ||
              text !== `credit:${phase}:godot:reference:${count}` ||
              !Number.isInteger(count) ||
              count <= snapshotAck ||
              count > snapshotSent ||
              count % 8 !== 0
            ) {
              window.referenceError = "reference consumption credit differs";
              return false;
            }
            acceptCredit(count);
            return true;
          }
          if (text.startsWith("position:")) {
            const sequence = Number(text.split(":")[3]);
            if (
              !mixedTraffic ||
              label !== "unreliable" ||
              !Number.isInteger(sequence) ||
              sequence < 0 ||
              sequence >= 32 ||
              positionsReceived.has(sequence) ||
              text !== position("godot", sequence)
            ) {
              window.referenceError =
                "reference position bytes or metadata differ";
              return false;
            }
            positionsReceived.add(sequence);
            return true;
          }
          if (label === "reliable" && /^(snapshot|partial):/.test(text)) {
            const partial = text.startsWith("partial:");
            const sequence = partial ? partialReceived : snapshotReceived;
            if (
              sequence >= (partial ? 4 : 128) ||
              text !== chunk("godot", sequence, partial)
            ) {
              window.referenceError =
                "reference snapshot bytes or sequence differ";
              return false;
            }
            if (partial) partialReceived++;
            else {
              snapshotReceived++;
              if (snapshotReceived % 8 === 0) {
                if (creditTransport === "http")
                  outgoing.push({
                    marker: `snapshot-ack-${phase}-${snapshotReceived}`,
                  });
                else
                  engine
                    .channel("godot", "reliable")
                    .send(
                      `credit:${phase}:reference:godot:${snapshotReceived}`,
                    );
              }
            }
            return true;
          }
          if (
            !["reliable", "unreliable"].includes(label) ||
            text !== `godot:${phase}:${label}` ||
            received.includes(label)
          ) {
            window.referenceError = "reference probe bytes or metadata differ";
            return false;
          }
          received.push(label);
          return true;
        },
      });
      const evidence = () => ({
        phase,
        heartbeat_sent: heartbeatSent,
        heartbeat_received: heartbeatReceived,
        signaling_pending: signalingTask !== null,
        mixed_traffic: mixedTraffic,
        credit_transport: creditTransport,
        max_credit_wait_ms: maxCreditWaitMs,
        snapshot_acknowledged: snapshotAck,
        positions_sent: positionsSent,
        positions_received: positionsReceived.size,
        peak_outstanding: peakOutstanding,
        credit_wait_age_ms:
          snapshotSent > snapshotAck
            ? Math.round(performance.now() - creditUpdated)
            : 0,
        transfer_ms: transferMs,
        sent,
        snapshot_sent: snapshotSent,
        snapshot_received: snapshotReceived,
        partial_sent: partialSent,
        partial_received: partialReceived,
        received: received.slice(),
        remote_closed: remoteClosed,
        events: events.slice(),
        snapshot: engine.diagnosticSnapshot("godot"),
      });
      const sendSignal = async (message) => {
        const response = await fetch(`/signal/${godotSeat}`, {
          method: "POST",
          body: JSON.stringify(message),
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`relay POST ${response.status}`);
      };
      const exchange = async () => {
        const response = await fetch(`/signal/${seat}`, {
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`relay GET ${response.status}`);
        for (const message of await response.json()) {
          if (message.marker === `ready-${phase}` && !paired) {
            paired = true;
            started = performance.now();
            const offer = await engine.pairWith("godot", !godotOffer, []);
            outgoing.push({ marker: `ready-${phase}` });
            if (offer) outgoing.push({ payload: { Offer: offer } });
          } else if (
            creditTransport === "http" &&
            message.marker?.startsWith(`snapshot-ack-${phase}-`)
          ) {
            acceptCredit(Number(message.marker.split("-").at(-1)));
          } else if (
            message.marker === `close-ready-${phase}` &&
            !closeQueued
          ) {
            closeRequested = true;
          } else if (
            message.marker === `close-selected-${phase}` &&
            !remoteClosed
          ) {
            remoteClosed = true;
            engine.channel("godot", "reliable").close();
            window.referenceResults.at(-1).remote_closed = true;
          } else if (message.marker === `retired-${phase}`) {
            retired = true;
          } else if (message.payload && message.generation === generation) {
            const payload = message.payload;
            if (payload.Offer)
              outgoing.push({
                payload: {
                  Answer: await engine.handleOffer("godot", payload.Offer),
                },
              });
            if (payload.Answer)
              await engine.handleAnswer("godot", payload.Answer);
            if (payload.IceCandidate)
              await engine.handleRemoteCandidate("godot", payload.IceCandidate);
          }
        }
        while (outgoing.length)
          await sendSignal({ generation, ...outgoing.shift() });
      };
      window.referenceProgress = evidence;
      try {
        while (!retired && performance.now() - started < 14000) {
          if (snapshotSent > snapshotAck)
            maxCreditWaitMs = Math.max(
              maxCreditWaitMs,
              Math.round(performance.now() - creditUpdated),
            );
          if (performance.now() >= nextProgress) {
            nextProgress = performance.now() + 1000;
            console.log(
              "WEBRTC_INTEROP_PROGRESS " +
                JSON.stringify({
                  ...evidence(),
                  runtime: "reference",
                  elapsed_ms: Math.round(performance.now() - started),
                  paired,
                  snapshot_ack: snapshotAck,
                  close_queued: closeQueued,
                }),
            );
          }
          if (signalingError) throw signalingError;
          if (signalingTask === null) {
            signalingTask = exchange()
              .catch((error) => {
                signalingError = error;
              })
              .finally(() => {
                signalingTask = null;
              });
          }
          if (
            !sent &&
            engine.channel("godot", "reliable")?.readyState === "open" &&
            engine.channel("godot", "unreliable")?.readyState === "open"
          ) {
            sent = true;
            transferStarted = performance.now();
            creditUpdated = transferStarted;
            for (const label of ["reliable", "unreliable"])
              engine
                .channel("godot", label)
                .send(`reference:${phase}:${label}`);
          }
          const reliable = engine.channel("godot", "reliable");
          if (sent && reliable?.readyState === "open") {
            for (
              let batch = 0;
              batch < 4 &&
              snapshotSent < 128 &&
              snapshotSent - snapshotAck < 32;
              batch++
            ) {
              reliable.send(chunk("reference", snapshotSent++));
              peakOutstanding = Math.max(
                peakOutstanding,
                snapshotSent - snapshotAck,
              );
              if (mixedTraffic && snapshotSent % 4 === 0)
                engine
                  .channel("godot", "unreliable")
                  .send(position("reference", positionsSent++));
            }
            if (
              snapshotReceived === 128 &&
              snapshotAck === 128 &&
              partialSent === 0
            ) {
              transferMs = Math.round(performance.now() - transferStarted);
              for (; partialSent < 4; partialSent++)
                reliable.send(chunk("reference", partialSent, true));
            }
          }
          if (paired && !observed && performance.now() - started >= 6000) {
            observed = true;
            const observation = evidence();
            window.referenceResults.push({ ...observation, observation });
            outgoing.push({ marker: `observed-${phase}` });
          }
          if (
            mixedTraffic &&
            sent &&
            reliable?.readyState === "open" &&
            heartbeatSent < 128 &&
            performance.now() >= nextHeartbeat &&
            partialSent === 0
          ) {
            reliable.send(heartbeat(heartbeatSent++));
            nextHeartbeat = performance.now() + 100;
          }
          if (
            closeRequested &&
            !closeQueued &&
            heartbeatReceived === heartbeatSent
          ) {
            closeQueued = true;
            reliable.send(`retired:${phase}`);
          }
          if (window.referenceError) throw new Error(window.referenceError);
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
      } finally {
        controller.abort();
        await signalingTask;
      }
      if (signalingError && !retired) throw signalingError;
      if (!retired) throw new Error(`phase ${phase} missing Godot teardown`);
      Object.assign(window.referenceResults.at(-1), evidence());
      console.log(
        "WEBRTC_REFERENCE_PHASE " +
          JSON.stringify(window.referenceResults.at(-1)),
      );
      engine.removePeer("godot");
      if (engine.isPaired("godot"))
        throw new Error("reference teardown retained peer");
      await post({ marker: `retired-${phase}` });
    }
    window.referenceDone = true;
  } catch (error) {
    window.referenceError = String(error);
    console.error(window.referenceError);
  } finally {
    engine?.removePeer("godot");
  }
};
