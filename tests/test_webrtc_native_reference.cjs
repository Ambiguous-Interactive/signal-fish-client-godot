const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

module.exports = async function testNativeReference() {
  const operations = [];
  const releaseSignals = [];
  const context = {
    window: {},
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
  channel.send("first");
  channel.send("second");
  await engine.removePeer("godot");
  assert.deepEqual(
    operations.map((op) => op.op),
    ["pair", "send", "send", "snapshot", "remove"],
  );
  assert.deepEqual(
    operations.filter((op) => op.op === "send").map((op) => op.text),
    ["first", "second"],
  );
  assert.equal(context.window.nativeReferenceSnapshots[0].generation, 2);
  assert.equal(engine.isPaired("godot"), false);
  assert.equal(channel.readyState, "closed");
  engine.dispatch({
    event: "message",
    generation: 2,
    label: "reliable",
    text: "late",
  });
  assert.equal(received.length, 3);

  context.fetch = async () => ({
    ok: false,
    json: async () => ({ error: "native failure" }),
  });
  const failed = new context.Engine(false, callbacks);
  await assert.rejects(failed.pairWith("godot", false, []), /native failure/);
  assert.match(context.window.referenceError, /native failure/);
  console.log("Native reference bridge tests passed");
};
