import { Engine } from "/reference/engine.js";

window.referenceError = null;
window.referenceSettled = false;
window.referenceResults = [];
window.runReference = async function (
  godotSeat,
  godotOffer,
  mixedTraffic,
  creditTransport,
  slowReferenceReceiver = false,
  closingChannel = "reliable",
  closingSeat = "reference",
  queuedRetirement = false,
  binaryPayloads = null,
  startupBurst = false,
  snapshotBodyBytes = 1024,
  snapshotWindowBytes = 49152,
) {
  const seat = 1 - godotSeat;
  const creditStride = snapshotWindowBytes
    ? [8, 4, 2, 1].find(
        (count) => count * (snapshotBodyBytes + 32) <= snapshotWindowBytes,
      )
    : 8;
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
      const service = window.referenceService
        ? await window.referenceService.begin(phase, seat)
        : null;
      const generation =
        service?.generation ??
        `40000000-0000-0000-0000-${String(phase).padStart(12, "0")}`;
      const outgoing = [];
      const received = [];
      const events = [];
      let paired = false;
      let sent = false;
      let snapshotSent = 0;
      let startupReceived = 0;
      let orderedSent = 0;
      const binarySent = [0, 0, 0];
      const binarySequences = [[], [], []];
      const binaryLabels = ["reliable", "ordered", "unreliable"];
      const binaryPackets = binaryPayloads?.[phase];
      const orderedSequences = [];
      let snapshotReceived = 0;
      let snapshotAck = 0;
      let outstandingBytes = 0;
      let peakOutstandingBytes = 0;
      const heartbeatTimings = [];
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
          for (let sequence = snapshotAck; sequence < count; sequence++)
            outstandingBytes -= chunk("reference", sequence).length;
          snapshotAck = count;
          creditUpdated = performance.now();
        }
      };
      let partialSent = 0;
      let partialAck = 0;
      let partialCreditUpdated = 0;
      let partialBytes = 0;
      let peakPartialBytes = 0;
      let partialReceived = 0;
      const chunk = (sender, sequence, partial = false) =>
        `${partial ? "partial" : "snapshot"}:${phase}:${sender}:${sequence}:` +
        "0123456789abcdef".repeat(snapshotBodyBytes / 16);
      let observed = false;
      let closeRequested = false;
      let closeQueued = false;
      let remoteClosed = false;
      let lateRetirementSent = false;
      let retired = false;
      const queued = [];
      const closedLabels = [];
      const receivePause = {};
      let pauseStarted = 0;
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
      const consume = (label, text) => {
        if (window.referenceError) return false;
        if (text.startsWith("startup:")) {
          const expected =
            `startup:${phase}:godot:${startupReceived}:` +
            "0123456789abcdef".repeat(64);
          if (
            !startupBurst ||
            label !== "reliable" ||
            startupReceived >= 32 ||
            text !== expected
          ) {
            window.referenceError ??= `reference startup bytes or metadata differ: phase=${phase} expected_sequence=${startupReceived} received_sequence=${text.split(":")[3]}`;
            return false;
          }
          startupReceived++;
          return true;
        }
        if (text.startsWith("ordered:")) {
          const sequence = Number(text.split(":")[3]);
          if (
            !engine.nativeProfile ||
            label !== "ordered" ||
            !Number.isInteger(sequence) ||
            sequence < 0 ||
            sequence >= 8 ||
            (orderedSequences.length && sequence <= orderedSequences.at(-1)) ||
            text !== `ordered:${phase}:godot:${sequence}`
          ) {
            window.referenceError ??=
              "reference ordered bytes or metadata differ";
            return false;
          }
          orderedSequences.push(sequence);
          return true;
        }
        if (text.startsWith("heartbeat:")) {
          if (
            !mixedTraffic ||
            label !== "reliable" ||
            heartbeatReceived >= heartbeatSent ||
            text !== heartbeat(heartbeatReceived)
          ) {
            window.referenceError ??=
              "reference heartbeat bytes or metadata differ";
            return false;
          }
          heartbeatTimings[heartbeatReceived].echo_ms = Math.round(
            performance.now() - started,
          );
          heartbeatReceived++;
          return true;
        }
        if (text.startsWith("partial-credit:")) {
          const count = Number(text.split(":").at(-1));
          if (
            label !== "reliable" ||
            text !== `partial-credit:${phase}:godot:reference:${count}` ||
            count !== partialAck + 1 ||
            count > partialSent
          ) {
            window.referenceError ??=
              "reference partial consumption credit differs";
            return false;
          }
          partialBytes -= chunk("reference", partialAck, true).length;
          partialAck = count;
          partialCreditUpdated = performance.now();
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
            (count !== 128 && count % creditStride !== 0)
          ) {
            window.referenceError ??= "reference consumption credit differs";
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
            window.referenceError ??=
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
            window.referenceError ??= `reference snapshot bytes or sequence differ: phase=${phase} label=${label} expected_sequence=${sequence} received_sequence=${text.split(":")[3]} expected_bytes=${chunk("godot", sequence, partial).length} received_bytes=${text.length}`;
            return false;
          }
          if (partial) {
            partialReceived++;
            engine
              .channel("godot", "reliable")
              .send(
                `partial-credit:${phase}:reference:godot:${partialReceived}`,
              );
          } else {
            snapshotReceived++;
            if (slowReferenceReceiver && snapshotReceived === 8) {
              pauseStarted = performance.now();
              Object.assign(receivePause, {
                received: snapshotReceived,
                heartbeat_sent: heartbeatSent,
                heartbeat_received: heartbeatReceived,
                peak_queued: 0,
                resumed: false,
              });
            }
            if (
              snapshotReceived === 128 ||
              snapshotReceived % creditStride === 0
            ) {
              if (creditTransport === "http")
                outgoing.push({
                  marker: `snapshot-ack-${phase}-${snapshotReceived}`,
                });
              else
                engine
                  .channel("godot", "reliable")
                  .send(`credit:${phase}:reference:godot:${snapshotReceived}`);
            }
          }
          return true;
        }
        if (
          !["reliable", "unreliable"].includes(label) ||
          text !== `godot:${phase}:${label}` ||
          received.includes(label)
        ) {
          window.referenceError ??= "reference probe bytes or metadata differ";
          return false;
        }
        received.push(label);
        return true;
      };
      const thisCallbacks = {
        onLocalCandidate: (_peer, _generation, candidate) => {
          if (!window.referenceError)
            outgoing.push({ payload: { IceCandidate: candidate } });
        },
        onPcState: (_peer, _generation, state) => {
          if (!window.referenceError) events.push(["state", state]);
        },
        onChannelOpen: (_peer, _generation, label) => {
          if (window.referenceError) return;
          events.push(["open", label]);
          engine.noteChannelOpen("godot", label);
        },
        onChannelClosed: (_peer, _generation, label, reason) => {
          if (window.referenceError) return;
          events.push(["closed", label, reason]);
          if (!closedLabels.includes(label)) closedLabels.push(label);
        },
        onChannelBinaryMessage: (peer, generation, label, data) => {
          if (window.referenceError) return false;
          if (binaryPackets) {
            const mode = binaryLabels.indexOf(label);
            const sequence = binaryPackets.godot[mode]?.findIndex(
              (packet) =>
                packet.length === data.length &&
                packet.every((byte, index) => byte === data[index]),
            );
            if (sequence !== undefined && sequence >= 0) {
              const received = binarySequences[mode];
              if (
                !received ||
                received.includes(sequence) ||
                (mode !== 2 &&
                  received.length &&
                  sequence <= received.at(-1)) ||
                (mode === 0 && sequence !== received.length)
              )
                throw new Error("reference binary order or metadata differ");
              received.push(sequence);
              return;
            }
          }
          const text = new TextDecoder("utf-8", { fatal: true }).decode(data);
          if (
            !/^(startup:|godot:|snapshot:|partial:|partial-credit:|position:|ordered:|heartbeat:|credit:|retirement:|retired:)/.test(
              text,
            )
          )
            throw new Error("reference unexpected binary packet");
          thisCallbacks.onChannelMessage(peer, generation, label, text);
        },
        onChannelMessage: (_peer, _generation, label, text) => {
          if (window.referenceError) return false;
          if (
            pauseStarted &&
            !receivePause.resumed &&
            /^(snapshot|position):/.test(text)
          ) {
            const snapshots = queued.filter((entry) =>
              entry.text.startsWith("snapshot:"),
            ).length;
            const positions = queued.length - snapshots;
            if ((text.startsWith("snapshot:") ? snapshots : positions) >= 32) {
              window.referenceError ??=
                "reference paused receive queue exceeded its window";
              return false;
            }
            queued.push({ label, text });
            receivePause.peak_queued = Math.max(
              receivePause.peak_queued,
              queued.length,
            );
            return true;
          }
          return consume(label, text);
        },
      };
      engine = new Engine(false, thisCallbacks);
      engine.startupPhase = startupBurst ? phase : 0;
      const evidence = () => ({
        phase,
        phase_started_ms: started,
        startup_burst: startupBurst,
        startup_sent: engine.startupSent ?? 0,
        startup_received: startupReceived,
        slow_reference_receiver: slowReferenceReceiver,
        receive_pause: { ...receivePause },
        queued_application_packets: queued.length,
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
        native_profile: engine.nativeProfile === true,
        binary_traffic: binaryPackets !== undefined,
        binary_sent: binarySent.slice(),
        binary_sequences: binarySequences.map((sequences) => sequences.slice()),
        ordered_sent: orderedSent,
        ordered_sequences: orderedSequences.slice(),
        position_sequences: [...positionsReceived],
        snapshot_body_bytes: snapshotBodyBytes,
        snapshot_window_bytes: snapshotWindowBytes,
        outstanding_snapshot_bytes: outstandingBytes,
        peak_outstanding_snapshot_bytes: peakOutstandingBytes,
        heartbeat_timings: heartbeatTimings.map((entry) => ({ ...entry })),
        snapshot_sent: snapshotSent,
        snapshot_received: snapshotReceived,
        partial_sent: partialSent,
        partial_acknowledged: partialAck,
        partial_credit_wait_age_ms:
          partialSent > partialAck
            ? Math.round(performance.now() - partialCreditUpdated)
            : 0,
        outstanding_partial_bytes: partialBytes,
        peak_outstanding_partial_bytes: peakPartialBytes,
        partial_received: partialReceived,
        received: received.slice(),
        remote_closed: remoteClosed,
        retirement: {
          channel: closingChannel,
          seat: closingSeat,
          closed_labels: closedLabels.slice(),
          queued_retirement: queuedRetirement,
          late_sent: lateRetirementSent,
        },
        events: events.slice(),
        snapshot: engine.diagnosticSnapshot("godot"),
      });
      const sendSignal = async (message) => {
        if (window.referenceError) return;
        if (service && message.payload) {
          service.send(message.payload);
          return;
        }
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
        const messages = await response.json();
        if (service) messages.push(...service.drain(paired));
        for (const message of messages) {
          if (window.referenceError) return;
          if (message.marker === `ready-${phase}` && !paired) {
            paired = true;
            started = performance.now();
            const offer = await engine.pairWith(
              "godot",
              service?.initiate ?? !godotOffer,
              service?.iceServers ?? [],
            );
            if (window.referenceError) return;
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
            queuedRetirement &&
            message.marker === `close-cached-${phase}` &&
            !lateRetirementSent
          ) {
            engine
              .channel("godot", "reliable")
              .send(`retirement:${phase}:reliable`);
            engine
              .channel("godot", "unreliable")
              .send(`retirement:${phase}:tail`);
            lateRetirementSent = true;
          } else if (
            message.marker === `close-selected-${phase}` &&
            !remoteClosed
          ) {
            remoteClosed = true;
            if (service?.rejoin && phase === 1) {
              await service.leave("selected_packet");
            } else if (closingSeat === "reference") {
              const selected = engine.channel("godot", closingChannel);
              if (!selected || selected.readyState !== "open")
                throw new Error("reference closing channel is unavailable");
              selected.close();
            } else outgoing.push({ marker: `close-armed-${phase}` });
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
        while (outgoing.length && !window.referenceError)
          await sendSignal({ generation, ...outgoing.shift() });
      };
      window.referenceProgress = evidence;
      try {
        while (!retired && performance.now() - started < 14000) {
          if (window.referenceError) throw new Error(window.referenceError);
          if (
            pauseStarted &&
            !receivePause.resumed &&
            performance.now() - pauseStarted >= 1500
          ) {
            Object.assign(receivePause, {
              resumed: true,
              elapsed_ms: Math.round(performance.now() - pauseStarted),
              received_at_resume: snapshotReceived,
              heartbeat_sent_at_resume: heartbeatSent,
              heartbeat_received_at_resume: heartbeatReceived,
              queued_snapshots: queued.filter((entry) =>
                entry.text.startsWith("snapshot:"),
              ).length,
              queued_positions: queued.filter((entry) =>
                entry.text.startsWith("position:"),
              ).length,
            });
            for (const { label, text } of queued.splice(0)) {
              if (!consume(label, text)) throw new Error(window.referenceError);
            }
          }
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
                if (!controller.signal.aborted || error?.name !== "AbortError")
                  signalingError = error;
              })
              .finally(() => {
                signalingTask = null;
              });
          }
          if (
            !sent &&
            engine.channel("godot", "reliable")?.readyState === "open" &&
            engine.channel("godot", "unreliable")?.readyState === "open" &&
            (!engine.nativeProfile ||
              engine.channel("godot", "ordered")?.readyState === "open")
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
              const data = chunk("reference", snapshotSent);
              if (
                snapshotWindowBytes &&
                outstandingBytes + data.length > snapshotWindowBytes
              )
                break;
              reliable.send(data);
              snapshotSent++;
              outstandingBytes += data.length;
              peakOutstandingBytes = Math.max(
                peakOutstandingBytes,
                outstandingBytes,
              );
              if (binaryPackets && snapshotSent % 16 === 0) {
                for (const [mode, label] of binaryLabels.entries()) {
                  engine
                    .channel("godot", label)
                    .sendBinary(
                      new Uint8Array(
                        binaryPackets.reference[mode][binarySent[mode]++],
                      ),
                    );
                }
              }
              if (engine.nativeProfile && snapshotSent % 16 === 0)
                engine
                  .channel("godot", "ordered")
                  .send(`ordered:${phase}:reference:${orderedSent++}`);
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
              partialSent < 4
            ) {
              if (transferMs < 0)
                transferMs = Math.round(performance.now() - transferStarted);
              while (partialSent < 4) {
                const data = chunk("reference", partialSent, true);
                if (
                  snapshotWindowBytes &&
                  partialBytes + data.length > snapshotWindowBytes
                )
                  break;
                if (partialSent === 0) partialCreditUpdated = performance.now();
                reliable.send(data);
                partialSent++;
                partialBytes += data.length;
                peakPartialBytes = Math.max(peakPartialBytes, partialBytes);
              }
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
            heartbeatTimings.push({
              sequence: heartbeatSent,
              enqueue_ms: Math.round(performance.now() - started),
            });
            reliable.send(heartbeat(heartbeatSent++));
            nextHeartbeat = performance.now() + 100;
          }
          if (
            closeRequested &&
            !closeQueued &&
            heartbeatReceived === heartbeatSent &&
            partialAck === 4
          ) {
            closeQueued = true;
            if (queuedRetirement)
              engine
                .channel("godot", "unreliable")
                .send(`retirement:${phase}:unreliable`);
            else reliable.send(`retired:${phase}`);
          }
          if (window.referenceError) throw new Error(window.referenceError);
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
      } finally {
        window.referenceTerminal = {
          ...evidence(),
          elapsed_ms: Math.round(performance.now() - started),
          retired,
          paired,
          outgoing_signals: outgoing.length,
        };
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
      await engine.removePeer("godot");
      if (engine.isPaired("godot"))
        throw new Error("reference teardown retained peer");
      if (service) await service.leave();
      await post({ marker: `retired-${phase}` });
    }
    window.referenceDone = true;
  } catch (error) {
    window.referenceError ??= String(error);
    console.error(window.referenceError);
  } finally {
    try {
      await engine?.removePeer("godot");
      window.referenceService?.close();
    } catch (error) {
      window.referenceCleanupError = String(error);
      window.referenceError ??= window.referenceCleanupError;
    } finally {
      window.referenceSettled = true;
    }
  }
};
