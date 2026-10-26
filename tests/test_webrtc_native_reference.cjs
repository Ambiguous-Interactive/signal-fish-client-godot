const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

module.exports = async function testNativeReference() {
  const operations = [];
  const releaseSignals = [];
  const context = {
    window: {},
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
  const pairing = engine.pairWith("godot", true, []);
  engine.dispatch({ event: "candidate", generation: 2, candidate: "early" });
  engine.dispatch({
    event: "message",
    generation: 1,
    label: "reliable",
    text: "stale",
  });
  engine.dispatch({
    event: "open",
    generation: 2,
    label: "reliable",
    properties: { lifetime: null },
  });
  assert.equal(await pairing, "sdp");
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
  assert.throws(() => channel.sendBinary([0, 255]), /needs Uint8Array/);
  channel.send("first");
  for (const data of payloads) channel.sendBinary(data);
  channel.send("second");
  await engine.removePeer("godot");
  assert.deepEqual(
    operations.map((op) => op.op),
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
    operations.filter((op) => op.op === "send").map((op) => op.text),
    ["first", "second"],
  );
  assert.deepEqual(
    operations
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
  assert.equal(received.length, beforeRetired);

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
  console.log("Native reference bridge tests passed");
};
