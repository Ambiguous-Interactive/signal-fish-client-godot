import { Engine } from "/reference/engine.js";

window.referenceError = null;
window.referenceResults = [];
window.runReference = async function (godotSeat, godotOffer) {
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
      let partialSent = 0;
      let partialReceived = 0;
      const chunk = (sender, sequence, partial = false) =>
        `${partial ? "partial" : "snapshot"}:${phase}:${sender}:${sequence}:` +
        "0123456789abcdef".repeat(64);
      let observed = false;
      let retired = false;
      let started = performance.now();
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
              if (snapshotReceived % 8 === 0)
                outgoing.push({
                  marker: `snapshot-ack-${phase}-${snapshotReceived}`,
                });
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
      while (!retired && performance.now() - started < 14000) {
        const response = await fetch(`/signal/${seat}`);
        if (!response.ok) throw new Error(`relay GET ${response.status}`);
        for (const message of await response.json()) {
          if (message.marker === `ready-${phase}` && !paired) {
            paired = true;
            started = performance.now();
            const offer = await engine.pairWith("godot", !godotOffer, []);
            outgoing.push({ marker: `ready-${phase}` });
            if (offer) outgoing.push({ payload: { Offer: offer } });
          } else if (message.marker?.startsWith(`snapshot-ack-${phase}-`)) {
            snapshotAck = Math.max(
              snapshotAck,
              Number(message.marker.split("-").at(-1)),
            );
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
        if (
          !sent &&
          engine.channel("godot", "reliable")?.readyState === "open" &&
          engine.channel("godot", "unreliable")?.readyState === "open"
        ) {
          sent = true;
          for (const label of ["reliable", "unreliable"])
            engine.channel("godot", label).send(`reference:${phase}:${label}`);
        }
        const reliable = engine.channel("godot", "reliable");
        if (sent && reliable?.readyState === "open") {
          for (
            let batch = 0;
            batch < 4 && snapshotSent < 128 && snapshotSent - snapshotAck < 32;
            batch++
          )
            reliable.send(chunk("reference", snapshotSent++));
          if (
            snapshotReceived === 128 &&
            snapshotAck === 128 &&
            partialSent === 0
          ) {
            for (; partialSent < 4; partialSent++)
              reliable.send(chunk("reference", partialSent, true));
          }
        }
        if (paired && !observed && performance.now() - started >= 6000) {
          observed = true;
          window.referenceResults.push({
            phase,
            sent,
            snapshot_sent: snapshotSent,
            snapshot_received: snapshotReceived,
            partial_sent: partialSent,
            partial_received: partialReceived,
            received: received.slice(),
            events: events.slice(),
            snapshot: engine.diagnosticSnapshot("godot"),
          });
          console.log(
            "WEBRTC_REFERENCE_PHASE " +
              JSON.stringify(window.referenceResults.at(-1)),
          );
          outgoing.push({ marker: `observed-${phase}` });
        }
        while (outgoing.length) await post({ generation, ...outgoing.shift() });
        if (window.referenceError) throw new Error(window.referenceError);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      if (!retired) throw new Error(`phase ${phase} missing Godot teardown`);
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
