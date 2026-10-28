const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function testReferenceFirstFailure() {
  for (const binary of [false, true]) {
    let callbacks;
    let removed = false;
    let posted = 0;
    const context = {
      window: {},
      TextDecoder,
      AbortController,
      performance: { now: () => 1 },
      console: { log() {}, error() {} },
      setTimeout: (callback) => setImmediate(callback),
      fetch: async (_url, options) => {
        if (options?.method === "POST") posted++;
        return { ok: true, json: async () => [{ marker: "ready-1" }] };
      },
      Engine: class {
        nativeProfile = true;
        constructor(_verbose, handlers) {
          callbacks = handlers;
        }
        async pairWith() {
          await Promise.resolve();
          for (const sequence of [4, 11, 0]) {
            const text =
              `snapshot:1:godot:${sequence}:` + "0123456789abcdef".repeat(64);
            if (binary)
              callbacks.onChannelBinaryMessage(
                "godot",
                1,
                "reliable",
                new TextEncoder().encode(text),
              );
            else callbacks.onChannelMessage("godot", 1, "reliable", text);
          }
          callbacks.onChannelMessage(
            "godot",
            1,
            "unreliable",
            "position:1:godot:0:" + "0123456789abcdef".repeat(4),
          );
          callbacks.onChannelClosed("godot", 1, "reliable", "late");
          return null;
        }
        channel() {
          return null;
        }
        diagnosticSnapshot() {
          return {};
        }
        async removePeer() {
          removed = true;
        }
      },
    };
    vm.runInNewContext(
      fs
        .readFileSync("tests/smoke/webrtc_reference.js", "utf8")
        .replace(/^import .*;\n/, ""),
      context,
    );
    await context.window.runReference(0, true, true, "http");
    assert.match(
      context.window.referenceError,
      /expected_sequence=0 received_sequence=4 /,
    );
    const evidence = context.window.referenceProgress();
    assert.equal(evidence.snapshot_received, 0);
    assert.equal(evidence.positions_received, 0);
    assert.equal(evidence.retirement.closed_labels.length, 0);
    assert.equal(posted, 0);
    assert.equal(removed, true);
    assert.equal(context.window.referenceSettled, true);
  }
  console.log("Reference first-failure tests passed");
}

async function testSmallSnapshotWindows() {
  for (const [slots, stride] of [
    [1, 1],
    [2, 2],
    [4, 4],
    [7, 4],
    [8, 8],
  ]) {
    for (const transport of ["http", "webrtc"]) {
      let clock = 1;
      let hooks;
      let ready = false;
      const acknowledgements = [];
      const pending = [];
      const context = {
        window: {},
        AbortController,
        performance: { now: () => clock },
        console: { log() {}, error() {} },
        setTimeout: (callback) =>
          setImmediate(() => {
            clock += 20;
            callback();
          }),
        Engine: class {
          constructor(_verbose, callbacks) {
            hooks = callbacks;
          }
          async pairWith() {
            return null;
          }
          channel() {
            return {
              readyState: "open",
              send(text) {
                if (text.startsWith("snapshot:")) {
                  const sequence = Number(text.split(":")[3]);
                  queueMicrotask(() => {
                    hooks.onChannelMessage(
                      "godot",
                      1,
                      "reliable",
                      `snapshot:1:godot:${sequence}:` +
                        "0123456789abcdef".repeat(64),
                    );
                    const count = sequence + 1;
                    if (count % stride === 0 || count === 128) {
                      if (transport === "webrtc")
                        hooks.onChannelMessage(
                          "godot",
                          1,
                          "reliable",
                          `credit:1:godot:reference:${count}`,
                        );
                      else pending.push({ marker: `snapshot-ack-1-${count}` });
                    }
                  });
                } else if (text.startsWith("credit:"))
                  acknowledgements.push(Number(text.split(":").at(-1)));
              },
            };
          }
          diagnosticSnapshot() {
            return {};
          }
          async removePeer() {}
        },
        fetch: async (_url, options) => {
          if (options?.method === "POST") {
            const marker = JSON.parse(options.body).marker;
            if (marker?.startsWith("snapshot-ack-"))
              acknowledgements.push(Number(marker.split("-").at(-1)));
          }
          return {
            ok: true,
            json: async () => {
              if (options?.method === "POST") return [];
              if (!ready) {
                ready = true;
                return [{ marker: "ready-1" }];
              }
              return pending.splice(0);
            },
          };
        },
      };
      vm.runInNewContext(
        fs
          .readFileSync("tests/smoke/webrtc_reference.js", "utf8")
          .replace(/^import .*;\n/, ""),
        context,
      );
      await context.window.runReference(
        1,
        false,
        false,
        transport,
        false,
        "reliable",
        "reference",
        false,
        null,
        false,
        1024,
        slots * 1056,
      );
      const evidence = context.window.referenceProgress();
      assert.equal(evidence.snapshot_sent, 128, `${slots} slots ${transport}`);
      assert.equal(evidence.snapshot_received, 128);
      assert.equal(evidence.snapshot_acknowledged, 128);
      assert.equal(evidence.outstanding_snapshot_bytes, 0);
      assert.ok(evidence.peak_outstanding_snapshot_bytes <= slots * 1056);
      const expected = [];
      for (let count = stride; count < 128; count += stride)
        expected.push(count);
      expected.push(128);
      assert.deepEqual(acknowledgements, expected);
      assert.match(context.window.referenceError, /missing Godot teardown/);
    }
  }
  console.log("Small snapshot window tests passed");
}

async function testStartupCredit() {
  for (const kind of [
    "valid",
    "absent",
    "stale-phase",
    "wrong-mode",
    "duplicate",
    "packet-only",
  ]) {
    let clock = 0;
    let hooks;
    let paired = false;
    let creditDelivered = false;
    let startupDelivered = false;
    const sent = [];
    const context = {
      window: {},
      TextEncoder,
      TextDecoder,
      AbortController,
      performance: { now: () => clock },
      console: { log() {}, error() {} },
      setTimeout: (callback) =>
        setImmediate(() => {
          clock += 20;
          if (paired && !startupDelivered) {
            startupDelivered = true;
            for (let sequence = 0; sequence < 32; sequence++) {
              hooks.onChannelBinaryMessage(
                "godot",
                1,
                "reliable",
                new TextEncoder().encode(
                  `startup:1:godot:${sequence}:` +
                    "0123456789abcdef".repeat(64),
                ),
              );
            }
          }
          if (
            paired &&
            clock >= 1000 &&
            !creditDelivered &&
            kind !== "absent" &&
            kind !== "packet-only"
          ) {
            if (kind === "valid")
              assert.equal(
                sent.filter((item) => item.text.startsWith("snapshot:")).length,
                0,
                "snapshots must wait for startup consumption credit",
              );
            creditDelivered = true;
            const text = `startup-credit:${kind === "stale-phase" ? 2 : 1}:godot:reference:32`;
            hooks.onChannelBinaryMessage(
              "godot",
              1,
              kind === "wrong-mode" ? "unreliable" : "reliable",
              new TextEncoder().encode(text),
            );
            if (kind === "duplicate")
              hooks.onChannelMessage("godot", 1, "reliable", text);
          }
          callback();
        }),
      Engine: class {
        nativeProfile = true;
        constructor(_verbose, callbacks) {
          hooks = callbacks;
        }
        async pairWith() {
          paired = true;
          return null;
        }
        channel() {
          return {
            readyState: "open",
            send(text) {
              sent.push({ text, clock });
              if (text.startsWith("heartbeat:"))
                queueMicrotask(() =>
                  hooks.onChannelMessage("godot", 1, "reliable", text),
                );
            },
          };
        }
        diagnosticSnapshot() {
          return { startup_sent: 32 };
        }
        async removePeer() {}
      },
      fetch: async (_url, options) => ({
        ok: true,
        json: async () =>
          options?.method === "POST" ? [] : [{ marker: "ready-1" }],
      }),
    };
    vm.runInNewContext(
      fs
        .readFileSync("tests/smoke/webrtc_reference.js", "utf8")
        .replace(/^import .*;\n/, ""),
      context,
    );
    await context.window.runReference(
      0,
      true,
      true,
      "webrtc",
      false,
      "reliable",
      "reference",
      false,
      null,
      true,
      4096,
      kind === "packet-only" ? 0 : 49152,
    );
    const snapshots = sent.filter((item) => item.text.startsWith("snapshot:"));
    const heartbeats = sent.filter(
      (item) => item.text.startsWith("heartbeat:") && item.clock < 1000,
    );
    assert.ok(heartbeats.length >= 5, kind);
    assert.ok(
      context.window.referenceProgress().heartbeat_received >=
        heartbeats.length,
      kind,
    );
    const credits = sent.filter((item) =>
      item.text.startsWith("startup-credit:"),
    );
    assert.equal(credits.length, kind === "packet-only" ? 0 : 1, kind);
    if (credits.length)
      assert.equal(credits[0].text, "startup-credit:1:reference:godot:32");
    if (kind === "valid") {
      assert.ok(snapshots.length > 0);
      assert.ok(snapshots.every((item) => item.clock >= 1000));
      assert.equal(
        context.window.referenceProgress().snapshot_startup_credit,
        32,
      );
    } else if (kind === "packet-only") {
      assert.ok(snapshots.some((item) => item.clock < 1000));
      assert.equal(context.window.referenceProgress().startup_credit, false);
    } else {
      assert.equal(snapshots.length, 0, kind);
      if (kind !== "absent")
        assert.match(
          context.window.referenceError,
          /startup consumption credit differs/,
        );
    }
  }
  console.log("Startup consumption credit tests passed");
}

async function testIndependentPositions() {
  for (const interval of [20, 100, 200, 0]) {
    let clock = 0;
    let hooks;
    const sent = [];
    const context = {
      window: {},
      TextEncoder,
      TextDecoder,
      AbortController,
      performance: { now: () => clock },
      console: { log() {}, error() {} },
      setTimeout: (callback) =>
        setImmediate(() => {
          clock += 20;
          if (clock === 1000) clock += 500;
          callback();
        }),
      Engine: class {
        nativeProfile = true;
        constructor(_verbose, callbacks) {
          hooks = callbacks;
        }
        async pairWith() {
          return null;
        }
        channel(_peer, label) {
          return {
            readyState: "open",
            send(text) {
              sent.push({ text, clock, label });
              if (text.startsWith("heartbeat:"))
                queueMicrotask(() =>
                  hooks.onChannelMessage("godot", 1, "reliable", text),
                );
            },
          };
        }
        diagnosticSnapshot() {
          return {};
        }
        async removePeer() {}
      },
      fetch: async (_url, options) => ({
        ok: true,
        json: async () =>
          options?.method === "POST" ? [] : [{ marker: "ready-1" }],
      }),
    };
    vm.runInNewContext(
      fs
        .readFileSync("tests/smoke/webrtc_reference.js", "utf8")
        .replace(/^import .*;\n/, ""),
      context,
    );
    await context.window.runReference(
      0,
      true,
      true,
      "webrtc",
      false,
      "reliable",
      "reference",
      false,
      null,
      false,
      16384,
      49152,
      0,
      0,
      interval,
    );
    const snapshots = sent.filter((item) => item.text.startsWith("snapshot:"));
    const positions = sent.filter((item) => item.text.startsWith("position:"));
    assert.equal(
      snapshots.length,
      2,
      "withheld credit must keep the bulk window full",
    );
    assert.equal(
      positions.length,
      interval ? 32 : 0,
      "independent positions must progress while snapshot credit is withheld",
    );
    for (const [sequence, packet] of positions.entries()) {
      assert.equal(packet.label, "unreliable");
      assert.equal(
        packet.text,
        `position:1:reference:${sequence}:` + "0123456789abcdef".repeat(4),
      );
      if (sequence)
        assert.ok(packet.clock - positions[sequence - 1].clock >= interval);
    }
    assert.ok(
      sent.filter((item) => item.text.startsWith("heartbeat:")).length >= 5,
    );
    const report = context.window.referenceProgress();
    assert.equal(report.position_interval_ms, interval);
    assert.equal(report.position_timings.length, positions.length);
    for (const sample of report.position_timings) {
      assert.equal(sample.snapshot_acknowledged, 0);
      assert.ok(sample.snapshot_sent <= 2);
    }
    assert.match(context.window.referenceError, /missing Godot teardown/);
  }
  console.log("Independent position cadence tests passed");
}

async function main() {
  await require("./test_webrtc_native_reference.cjs")();
  await require("./test_webrtc_http_request.cjs")();
  await testReferenceFirstFailure();
  await testSmallSnapshotWindows();
  await testStartupCredit();
  await testIndependentPositions();
  let sample;
  const output = [];
  const errors = [];
  const channels = [];
  const timers = new Map();
  let nextTimer = 0;
  class Peer {
    static marker = 42;
    connectionState = "connected";
    iceConnectionState = "connected";
    sctp = { state: "connected" };
    fail = false;
    deferred = null;
    calls = 0;
    addEventListener() {}
    createDataChannel(label, options) {
      return {
        addEventListener(_event, listener) {
          this.receive = listener;
        },
        id: options.id,
        label,
        negotiated: true,
        ordered: options.ordered,
        maxPacketLifeTime: options.maxPacketLifeTime ?? null,
        maxRetransmits: null,
      };
    }
    async getStats() {
      this.calls++;
      if (this.deferred) return this.deferred;
      if (this.fail) throw new Error("sample unavailable");
      return new Map([
        [
          0,
          {
            type: "data-channel",
            dataChannelIdentifier: 3,
            state: "open",
            messagesSent: 7,
            messagesReceived: 9,
            bytesSent: 70,
            bytesReceived: 90,
          },
        ],
        [
          1,
          {
            type: "transport",
            dtlsState: "connected",
            bytesSent: 100,
            bytesReceived: 120,
          },
        ],
        [
          2,
          {
            type: "candidate-pair",
            nominated: true,
            state: "succeeded",
            bytesSent: 100,
            bytesReceived: 120,
            currentRoundTripTime: 0.1,
          },
        ],
        [3, { type: "candidate-pair", nominated: false, bytesSent: 1 }],
      ]);
    }
  }
  const context = {
    window: { RTCPeerConnection: Peer },
    performance,
    TextEncoder,
    TextDecoder,
    ArrayBuffer,
    setInterval(callback, period) {
      assert.equal(period, 1000);
      sample = callback;
    },
    setTimeout(callback, period) {
      assert.equal(period, 750);
      timers.set(++nextTimer, callback);
      return nextTimer;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    console: {
      error(...args) {
        errors.push(args);
      },
      log(line) {
        if (line.startsWith("WEBRTC_BROWSER_CHANNEL ")) {
          channels.push(
            JSON.parse(line.slice("WEBRTC_BROWSER_CHANNEL ".length)),
          );
        } else {
          output.push(JSON.parse(line.slice("WEBRTC_BROWSER_STATS ".length)));
        }
      },
    },
  };
  vm.runInNewContext(
    fs.readFileSync("scripts/webrtc-browser-observation.js", "utf8"),
    context,
  );
  assert.equal(context.window.RTCPeerConnection.marker, 42);
  const peer = new context.window.RTCPeerConnection();
  assert.ok(peer instanceof Peer);
  const channel = peer.createDataChannel("ordered", {
    id: 2,
    ordered: true,
    maxPacketLifetime: 1,
  });
  assert.equal(channel.maxPacketLifeTime, null);
  assert.equal(channels[0].max_packet_life_time, null);
  assert.equal(channels[0].requested_misspelled_lifetime, 1);
  assert.equal(channels[0].requested_lifetime, null);
  const finite = peer.createDataChannel("control", {
    id: 10,
    ordered: false,
    maxPacketLifeTime: 100,
  });
  assert.equal(finite.maxPacketLifeTime, 100);
  assert.equal(channels[1].max_packet_life_time, 100);
  assert.equal(channels[1].max_retransmits, null);
  assert.equal(channels[1].requested_lifetime, 100);
  channel.receive({ data: new Uint8Array([1, 2, 3]).buffer });
  channel.receive({ data: "ab" });
  await sample();
  let report = output.at(-1);
  assert.equal(report.created, 1);
  assert.equal(report.peers[0].callbacks[0].packets, 2);
  assert.equal(report.peers[0].callbacks[0].bytes, 5);
  assert.equal(report.peers[0].callbacks[0].callbacks[0].bytes, 3);
  assert.equal(report.peers[0].callbacks[0].dropped, 0);
  assert.equal(report.peers[0].channels[0].messages_received, 9);
  assert.equal(report.peers[0].channels[0].bytes_received, 90);
  assert.equal(report.peers[0].transports[0].bytes_sent, 100);
  assert.equal(report.peers[0].candidate_pairs.length, 1);
  assert.equal(report.peers[0].candidate_pairs[0].round_trip_seconds, 0.1);
  for (let i = 0; i < 1025; i++)
    channel.receive({ data: new Uint8Array([0]).buffer });
  await sample();
  assert.equal(output.at(-1).peers[0].callbacks[0].callbacks.length, 1024);
  assert.equal(output.at(-1).peers[0].callbacks[0].dropped, 3);
  assert.equal(output.at(-1).peers[0].callbacks[0].packets, 1027);
  const traced = peer.createDataChannel("reliable", { id: 1, ordered: true });
  for (const packet of [
    "snapshot:1:reference:7:",
    "heartbeat:1:reference:3:",
    "credit:1:reference:godot:8",
    "startup-credit:1:reference:godot:32",
    "partial-credit:2:reference:godot:4",
  ]) {
    traced.receive({ data: new TextEncoder().encode(packet).buffer });
  }
  const finitePackets = [
    "reference:1:unreliable",
    "reference:1:reliable",
    "ordered:2:reference:7",
    "position:2:reference:3:body",
    "startup:2:reference:31:body",
  ];
  const finiteTrace = peer.createDataChannel("unreliable", {
    id: 3,
    ordered: false,
  });
  for (const packet of finitePackets)
    finiteTrace.receive({ data: new TextEncoder().encode(packet).buffer });
  assert.deepEqual(
    Array.from(
      context.window.webrtcCallbackSnapshot().at(-1).callbacks,
      (row) => row.packet,
    ),
    finitePackets.map((packet) => packet.replace(/:body$/, "")),
  );
  const captured = context.window.webrtcCallbackSnapshot().at(-2);
  assert.deepEqual(
    Array.from(captured.callbacks, (row) => row.packet),
    [
      "snapshot:1:reference:7",
      "heartbeat:1:reference:3",
      "credit:1:reference:godot:8",
      "startup-credit:1:reference:godot:32",
      "partial-credit:2:reference:godot:4",
    ],
  );
  assert.ok(captured.callbacks.every((row) => Number.isFinite(row.ms)));
  traced.receive({ data: "partial-credit:2:reference:godot:4" });
  context.console.error("ERROR: Buffer full! Dropping data.", "preserved");
  const drop = context.window.webrtcDropSnapshot();
  assert.equal(drop.records.length, 1);
  assert.equal(
    drop.records[0].preceding_callback.packet,
    "partial-credit:2:reference:godot:4",
  );
  assert.equal(drop.records[0].preceding_callback.label, "reliable");
  assert.ok(drop.records[0].ms >= drop.records[0].preceding_callback.ms);
  assert.deepEqual(errors[0], [
    "ERROR: Buffer full! Dropping data.",
    "preserved",
  ]);
  drop.records[0].preceding_callback.packet = "mutated copy";
  assert.equal(
    context.window.webrtcDropSnapshot().records[0].preceding_callback.packet,
    "partial-credit:2:reference:godot:4",
  );
  for (let i = 0; i < 130; i++)
    context.console.error("Buffer full! Dropping data.");
  assert.equal(context.window.webrtcDropSnapshot().records.length, 128);
  assert.equal(context.window.webrtcDropSnapshot().dropped, 3);
  peer.fail = true;
  await sample();
  assert.match(output.at(-1).peers[0].error, /sample unavailable/);
  peer.connectionState = "closed";
  await sample();
  report = output.at(-1);
  assert.equal(report.closed, 1);
  assert.equal(report.peers.length, 0);
  await sample();
  assert.equal(output.at(-1).closed, 1);
  const stuck = new context.window.RTCPeerConnection();
  const healthy = new context.window.RTCPeerConnection();
  let resolveStats;
  stuck.deferred = new Promise((resolve) => {
    resolveStats = resolve;
  });
  const pendingSample = sample();
  // Flush resolved getStats calls before firing only the remaining timeout.
  for (let tick = 0; tick < 10; tick++) await Promise.resolve();
  assert.equal(timers.size, 1);
  for (const timer of [...timers.values()]) timer();
  await pendingSample;
  report = output.at(-1);
  assert.match(report.peers[0].error, /timed out after 750ms/);
  assert.equal(report.peers[1].channels[0].bytes_received, 90);
  assert.equal(stuck.calls, 1);
  const healthyCalls = healthy.calls;
  stuck.connectionState = "disconnected";
  await sample();
  report = output.at(-1);
  assert.equal(report.peers[0].connection, "disconnected");
  assert.match(report.peers[0].error, /previous getStats request pending/);
  assert.equal(stuck.calls, 1);
  assert.equal(healthy.calls, healthyCalls + 1);
  assert.equal(report.peers[1].channels[0].messages_received, 9);
  resolveStats(new Map());
  for (let tick = 0; tick < 10; tick++) await Promise.resolve();
  stuck.deferred = null;
  await sample();
  report = output.at(-1);
  assert.equal(stuck.calls, 2);
  assert.equal(report.peers[0].channels[0].bytes_received, 90);
  assert.equal(report.peers[0].error, undefined);
  stuck.deferred = new Promise(() => {});
  const closingSample = sample();
  for (let tick = 0; tick < 10; tick++) await Promise.resolve();
  for (const timer of [...timers.values()]) timer();
  await closingSample;
  const callsBeforeClose = stuck.calls;
  stuck.connectionState = "closed";
  await sample();
  report = output.at(-1);
  assert.equal(report.closed, 2);
  assert.equal(report.peers.length, 1);
  assert.equal(stuck.calls, callsBeforeClose);
  assert.equal(report.peers[0].channels[0].bytes_received, 90);
  assert.equal(timers.size, 0);
  console.log("Browser WebRTC observation tests passed");
}
let completed = false;
process.on("beforeExit", () => {
  if (!completed) {
    console.error("Browser observation tests did not complete");
    process.exitCode = 1;
  }
});
main()
  .then(() => {
    completed = true;
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
