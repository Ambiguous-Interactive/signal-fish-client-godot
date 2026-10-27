const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function testRetirementCollection() {
  for (const closeSeat of ["godot", "reference"]) {
    for (const closeKind of [
      "valid",
      "absent",
      "wrong-channel",
      "deadline",
      "cleanup",
    ]) {
      let clock = 0;
      let active;
      let currentPhase = 0;
      let ready = false;
      let retiringAt = null;
      const phases = [];
      const context = {
        window: {},
        AbortController: class extends AbortController {
          abort() {
            if (closeKind === "cleanup") {
              clock += 20;
              active.callbacks.onChannelClosed(
                "godot",
                currentPhase,
                "reliable",
                "timeout cleanup",
              );
            }
            super.abort();
          }
        },
        performance: { now: () => clock },
        console: { log() {}, error() {} },
        setTimeout: (callback) =>
          setImmediate(() => {
            clock += 20;
            if (
              closeKind !== "absent" &&
              closeKind !== "cleanup" &&
              retiringAt !== null &&
              (closeKind === "deadline"
                ? clock >= 14000
                : clock - retiringAt >= 100)
            ) {
              retiringAt = null;
              active.callbacks.onChannelClosed(
                "godot",
                currentPhase,
                closeKind !== "wrong-channel" || closeSeat === "reference"
                  ? "ordered"
                  : "unknown",
                "delayed",
              );
              if (closeSeat === "reference" && closeKind !== "wrong-channel")
                active.callbacks.onChannelClosed(
                  "godot",
                  currentPhase,
                  "reliable",
                  "delayed",
                );
            }
            callback();
          }),
        Engine: class {
          nativeProfile = true;
          paired = false;
          constructor(_verbose, callbacks) {
            this.callbacks = callbacks;
            active = this;
            currentPhase++;
            ready = false;
          }
          async pairWith() {
            this.paired = true;
            return null;
          }
          channel() {
            return null;
          }
          diagnosticSnapshot() {
            return {};
          }
          async removePeer() {
            this.paired = false;
            phases.push(
              context.window.referenceResults
                .at(-1)
                ?.retirement.closed_labels.slice(),
            );
          }
          isPaired() {
            return this.paired;
          }
        },
        fetch: async (_url, options) => ({
          ok: true,
          json: async () => {
            if (options?.method === "POST") return [];
            if (!ready) {
              ready = true;
              return [{ marker: `ready-${currentPhase}` }];
            }
            if (
              context.window.referenceResults.length === currentPhase &&
              retiringAt === null
            ) {
              retiringAt = clock;
              return [{ marker: `retired-${currentPhase}` }];
            }
            return [];
          },
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
        false,
        "http",
        false,
        "reliable",
        closeSeat,
      );
      if (closeKind === "valid") {
        assert.equal(context.window.referenceError, null);
        assert.equal(context.window.referenceDone, true);
        assert.equal(context.window.referenceResults.length, 2);
        for (const result of context.window.referenceResults) {
          assert.ok(result.retirement.closed_labels.includes("ordered"));
          if (closeSeat === "reference")
            assert.ok(result.retirement.closed_labels.includes("reliable"));
        }
        assert.ok(phases[0].length > 0);
      } else {
        assert.match(
          context.window.referenceError,
          /missing reference channel-close callback/,
        );
        assert.equal(context.window.referenceDone, undefined);
        assert.ok(context.window.referenceTerminal.elapsed_ms >= 14000);
        assert.equal(currentPhase, 1);
        if (closeKind === "cleanup")
          assert.equal(
            context.window.referenceTerminal.retirement.closed_labels.length,
            0,
          );
        if (closeKind === "deadline")
          assert.ok(
            context.window.referenceTerminal.retirement.closed_labels.length >
              0,
          );
      }
    }
  }
}

module.exports = async function testNativeReference() {
  await testRetirementCollection();
  const operations = [];
  const releaseSignals = [];
  const context = {
    window: {},
    performance,
    Uint8Array,
    atob,
    btoa,
    setTimeout(callback, delay) {
      if (delay === 0) releaseSignals.push(callback);
    },
    fetch: async (url, options) => {
      if (url === "/native/events")
        return { ok: true, json: async () => ({ result: [] }) };
      const operation = JSON.parse(options.body);
      operations.push(operation);
      return {
        ok: true,
        json: async () => ({
          result:
            operation.op === "pair"
              ? { generation: 2, offer: "sdp" }
              : operation.op === "snapshot"
                ? { generation: 2 }
                : operation.op === "remove",
        }),
      };
    },
  };
  vm.runInNewContext(
    fs
      .readFileSync("tests/smoke/webrtc_native_reference.js", "utf8")
      .replace("export class Engine", "globalThis.Engine = class Engine"),
    context,
  );
  const received = [];
  const callbacks = {
    onLocalCandidate: (...args) => received.push(["candidate", ...args]),
    onChannelOpen: (...args) => received.push(["open", ...args]),
    onChannelMessage: (...args) => received.push(["message", ...args]),
    onChannelBinaryMessage: (...args) => received.push(["binary", ...args]),
    onChannelClosed: (...args) => received.push(["closed", ...args]),
  };
  const engine = new context.Engine(false, callbacks);
  engine.startupPhase = 2;
  const iceServers = [{ urls: ["stun:127.0.0.1:3478"] }];
  const pairing = engine.pairWith("godot", true, iceServers);
  engine.dispatch({ event: "candidate", generation: 2, candidate: "early" });
  engine.dispatch({
    event: "message",
    generation: 1,
    label: "reliable",
    text: "stale",
  });
  engine.dispatch({ event: "startup_sent", generation: 2, count: 32 });
  engine.dispatch({
    event: "open",
    generation: 2,
    label: "reliable",
    properties: { lifetime: null },
  });
  assert.equal(await pairing, "sdp");
  assert.equal(operations[0].startup_phase, 2);
  assert.deepEqual(operations[0].ice_servers, iceServers);
  assert.equal(engine.diagnosticSnapshot().startup_sent, 32);
  engine.dispatch({ event: "startup_sent", generation: 1, count: 99 });
  assert.equal(engine.diagnosticSnapshot().startup_sent, 32);
  assert.equal(received.length, 1);
  assert.equal(received[0][0], "open");
  releaseSignals.splice(0).forEach((callback) => callback());
  assert.equal(received.at(-1)[0], "candidate");
  assert.equal(received.at(-1).at(-1), "early");
  engine.dispatch({
    event: "message",
    generation: 1,
    label: "reliable",
    text: "stale",
  });
  engine.dispatch({
    event: "message",
    generation: 2,
    label: "reliable",
    text: "exact\0bytes",
  });
  assert.equal(received.at(-1).at(-1), "exact\0bytes");
  for (let index = 0; index < 130; index++) {
    engine.dispatch({
      event: "binary",
      generation: index === 0 ? 1 : 2,
      label: "reliable",
      data_base64: btoa(`heartbeat:1:reference:${index}:body`),
      probe_us: 1234 + index,
      received_us: 1000 + index,
    });
  }
  const heartbeatTrace = engine.diagnosticSnapshot();
  assert.equal(heartbeatTrace.native_heartbeat_received.length, 128);
  assert.equal(
    heartbeatTrace.native_heartbeat_received[0].marker,
    "heartbeat:1:reference:1",
  );
  assert.equal(heartbeatTrace.native_heartbeat_received[0].probe_us, 1235);
  assert.equal(heartbeatTrace.native_heartbeat_received[0].received_us, 1001);
  assert.equal(
    typeof heartbeatTrace.native_heartbeat_received[0].callback_ms,
    "number",
  );
  assert.equal(heartbeatTrace.native_heartbeat_received_dropped, 1);
  const channel = engine.channel("godot", "reliable");
  const payloads = [
    new Uint8Array(),
    new Uint8Array([0, 65, 194, 162]),
    new Uint8Array([255, 128, 192, 175, 0]),
    Uint8Array.from({ length: 256 }, (_, index) => index),
    Uint8Array.from({ length: 65536 }, (_, index) => index % 256),
  ];
  for (const label of ["reliable", "ordered", "unreliable"]) {
    for (const data of payloads) {
      const before = received.length;
      const data_base64 = Buffer.from(data).toString("base64");
      engine.dispatch({ event: "binary", generation: 1, label, data_base64 });
      assert.equal(received.length, before);
      engine.dispatch({ event: "binary", generation: 2, label, data_base64 });
      assert.equal(received.length, before + 1);
      assert.deepEqual(received.at(-1), ["binary", "godot", 2, label, data]);
    }
  }
  const binaryCallback = callbacks.onChannelBinaryMessage;
  delete callbacks.onChannelBinaryMessage;
  assert.throws(
    () =>
      engine.dispatch({
        event: "binary",
        generation: 2,
        label: "reliable",
        data_base64: "",
      }),
    /binary callback is missing/,
  );
  callbacks.onChannelBinaryMessage = binaryCallback;
  engine.dispatch({
    event: "receive_rejected",
    generation: 1,
    label: "unreliable",
  });
  for (const label of ["reliable", "ordered", "unreliable"]) {
    assert.throws(
      () =>
        engine.dispatch({ event: "receive_rejected", generation: 2, label }),
      /native receive rejected: generation=2 channel=/,
    );
  }
  assert.throws(
    () =>
      engine.dispatch({
        event: "binary",
        generation: 2,
        label: "reliable",
        data_base64: "!",
      }),
    /Invalid character/,
  );
  engine.dispatch({
    event: "closed",
    generation: 1,
    label: "reliable",
    probe_us: 10,
  });
  assert.equal(engine.diagnosticSnapshot().native_closed.length, 0);
  engine.dispatch({
    event: "closed",
    generation: 2,
    label: "reliable",
    probe_us: 20,
  });
  const closeTrace = engine.diagnosticSnapshot().native_closed;
  assert.equal(closeTrace.length, 1);
  assert.equal(closeTrace[0].label, "reliable");
  assert.equal(closeTrace[0].generation, 2);
  assert.equal(closeTrace[0].probe_us, 20);
  assert.equal(typeof closeTrace[0].callback_ms, "number");
  closeTrace[0].label = "mutated copy";
  assert.equal(engine.diagnosticSnapshot().native_closed[0].label, "reliable");
  assert.throws(() => channel.sendBinary([0, 255]), /needs Uint8Array/);
  channel.send("first");
  for (const data of payloads) channel.sendBinary(data);
  channel.send("second");
  await engine.removePeer("godot");
  assert.equal(operations.filter((op) => op.op === "send_batch").length, 1);
  const expanded = operations.flatMap((op) =>
    op.op === "send_batch" ? op.packets : [op],
  );
  assert.deepEqual(
    expanded.map((op) => op.op),
    [
      "pair",
      "send",
      ...payloads.map(() => "send_binary"),
      "send",
      "snapshot",
      "remove",
    ],
  );
  assert.deepEqual(
    expanded.filter((op) => op.op === "send").map((op) => op.text),
    ["first", "second"],
  );
  assert.deepEqual(
    expanded
      .filter((op) => op.op === "send_binary")
      .map((op) => Array.from(Buffer.from(op.data_base64, "base64"))),
    payloads.map((data) => Array.from(data)),
  );
  assert.equal(context.window.nativeReferenceSnapshots[0].generation, 2);
  assert.equal(engine.isPaired("godot"), false);
  assert.equal(channel.readyState, "closed");
  const beforeRetired = received.length;
  engine.dispatch({
    event: "message",
    generation: 2,
    label: "reliable",
    text: "late",
  });
  engine.dispatch({
    event: "binary",
    generation: 2,
    label: "reliable",
    data_base64: "",
  });
  engine.dispatch({
    event: "closed",
    generation: 2,
    label: "unreliable",
    probe_us: 30,
  });
  assert.equal(engine.diagnosticSnapshot().native_closed.length, 1);
  assert.equal(received.length, beforeRetired);

  const boundaryStart = operations.length;
  const bounded = new context.Engine(false, callbacks);
  await bounded.pairWith("godot", true, []);
  bounded.dispatch({
    event: "open",
    generation: 2,
    label: "reliable",
    properties: {},
  });
  const boundedChannel = bounded.channel("godot", "reliable");
  for (let i = 0; i < 260; i++) boundedChannel.send(String(i));
  const fence = bounded.handleRemoteCandidate("godot", "fence");
  boundedChannel.send("after");
  await fence;
  await bounded.removePeer("godot");
  const boundaryOps = operations.slice(boundaryStart);
  assert.deepEqual(
    boundaryOps.map((op) => op.op),
    [
      "pair",
      "send_batch",
      "send_batch",
      "candidate",
      "send_batch",
      "snapshot",
      "remove",
    ],
  );
  assert.deepEqual(
    boundaryOps
      .filter((op) => op.op === "send_batch")
      .map((op) => op.packets.length),
    [256, 4, 1],
  );
  assert.deepEqual(
    boundaryOps.flatMap((op) => op.packets ?? []).map((op) => op.text),
    [...Array.from({ length: 260 }, (_, i) => String(i)), "after"],
  );

  const timed = new context.Engine(false, callbacks);
  await timed.pairWith("godot", true, []);
  timed.dispatch({
    event: "open",
    generation: 2,
    label: "reliable",
    properties: {},
  });
  const originalFetch = context.fetch;
  let releaseSend;
  const heldSend = new Promise((resolve) => {
    releaseSend = resolve;
  });
  context.fetch = async (url, options) => {
    if (
      url === "/native/command" &&
      JSON.parse(options.body).op === "send_batch"
    )
      await heldSend;
    return originalFetch(url, options);
  };
  const timedChannel = timed.channel("godot", "reliable");
  timedChannel.send("heartbeat:1:reference:0:body");
  for (let tick = 0; tick < 10; tick++) await Promise.resolve();
  timedChannel.send("heartbeat:1:reference:1:body");
  let timings = timed.diagnosticSnapshot().packet_timings.slice(-2);
  assert.equal(timings[0].marker, "heartbeat:1:reference:0");
  assert.equal(typeof timings[0].dispatch_ms, "number");
  assert.equal(timings[0].complete_ms, undefined);
  assert.equal(timings[1].dispatch_ms, undefined);
  releaseSend();
  await timed.handleRemoteCandidate("godot", "timing fence");
  timings = timed.diagnosticSnapshot().packet_timings.slice(-2);
  for (const timing of timings) {
    assert.ok(timing.enqueue_ms <= timing.dispatch_ms);
    assert.ok(timing.dispatch_ms <= timing.complete_ms);
  }
  for (const generation of [1, 2])
    timed.dispatch({
      event: "sent",
      generation,
      label: "reliable",
      marker: "heartbeat:1:reference:0",
      probe_us: 500,
    });
  const nativeSent = timed.diagnosticSnapshot().native_sent;
  assert.equal(nativeSent.length, 1);
  assert.equal(nativeSent[0].probe_us, 500);
  assert.equal(typeof nativeSent[0].callback_ms, "number");
  await timed.removePeer("godot");
  context.fetch = originalFetch;

  const failingSend = new context.Engine(false, callbacks);
  await failingSend.pairWith("godot", true, []);
  failingSend.dispatch({
    event: "open",
    generation: 2,
    label: "reliable",
    properties: { lifetime: null },
  });
  context.fetch = async () => ({
    ok: false,
    json: async () => ({ error: "native failure" }),
  });
  failingSend.channel("godot", "reliable").sendBinary(payloads[3]);
  await assert.rejects(
    failingSend.handleRemoteCandidate("godot", "candidate"),
    /native failure/,
  );
  assert.match(context.window.referenceError, /native failure/);
  const failed = new context.Engine(false, callbacks);
  await assert.rejects(failed.pairWith("godot", false, []), /native failure/);
  assert.match(context.window.referenceError, /native failure/);
  let releaseBatch;
  const eventBatch = new Promise((resolve) => {
    releaseBatch = resolve;
  });
  const batchContext = {
    window: {},
    performance,
    setTimeout: (callback) => setImmediate(callback),
    fetch: async (url) => ({
      ok: true,
      json: async () => ({
        result: url === "/native/events" ? await eventBatch : { generation: 2 },
      }),
    }),
  };
  vm.runInNewContext(
    fs
      .readFileSync("tests/smoke/webrtc_native_reference.js", "utf8")
      .replace("export class Engine", "globalThis.Engine = class Engine"),
    batchContext,
  );
  let dispatched = 0;
  const batchEngine = new batchContext.Engine(false, {
    onChannelMessage: (_peer, _generation, _label, text) => {
      dispatched++;
      batchContext.window.referenceError = text;
    },
  });
  await batchEngine.pairWith("godot", true, []);
  releaseBatch([
    {
      event: "message",
      generation: 2,
      label: "reliable",
      text: "first failure",
    },
    {
      event: "message",
      generation: 2,
      label: "reliable",
      text: "later failure",
    },
  ]);
  await new Promise(setImmediate);
  assert.equal(dispatched, 1);
  assert.equal(batchContext.window.referenceError, "first failure");
  console.log("Native reference bridge tests passed");
};
