const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

module.exports = async function testHttpRequest() {
  const source = fs
    .readFileSync("tests/smoke/webrtc_http_request.gd", "utf8")
    .split('const WEB_SOURCE := """')[1]
    .split('"""')[0];
  const pending = [];
  const context = {
    window: {},
    AbortController,
    fetch: (url, options) =>
      new Promise((resolve, reject) => {
        pending.push({ url, options, resolve, reject });
      }),
  };
  vm.runInNewContext(source, context);
  const bridge = new context.window.SFDrillHttpRequest();
  const settle = () => new Promise(setImmediate);
  const calls = [];
  const callback = (...args) => calls.push(args);
  bridge.request(
    "/signal/1",
    "POST",
    '{"marker":"credit-8"}',
    '["Content-Type: application/json", "X-Trace: phase:1"]',
    callback,
  );
  await settle();
  assert.equal(pending[0].options.body, '{"marker":"credit-8"}');
  assert.equal(
    JSON.stringify(pending[0].options.headers),
    JSON.stringify([
      ["Content-Type", "application/json"],
      ["X-Trace", "phase:1"],
    ]),
  );
  pending.shift().resolve({ status: 503, text: async () => "unavailable" });
  await settle();
  assert.deepEqual(calls.shift(), [true, 503, "unavailable"]);

  bridge.request("/signal/0", "GET", "", "[]", callback);
  await settle();
  assert.equal(pending[0].options.method, "GET");
  assert.equal(pending[0].options.body, undefined);
  pending.shift().reject(new Error("network failure"));
  await settle();
  assert.deepEqual(calls.shift(), [false, 0, ""]);

  for (const failure of [false, true]) {
    bridge.request("/signal/0", "GET", "", "[]", callback);
    await settle();
    const old = pending.shift();
    bridge.cancel();
    assert.equal(old.options.signal.aborted, true);
    bridge.request("/signal/0", "GET", "", "[]", callback);
    await settle();
    if (failure) old.reject(new Error("cancelled"));
    else old.resolve({ status: 200, text: async () => "stale" });
    await settle();
    assert.equal(calls.length, 0);
    pending
      .shift()
      .resolve({ status: 200, text: async () => '[{"marker":"fresh"}]' });
    await settle();
    assert.deepEqual(calls.shift(), [true, 200, '[{"marker":"fresh"}]']);
  }

  bridge.request("/signal/0", "GET", "", "[]", callback);
  await settle();
  const slowBody = pending.shift();
  let releaseBody;
  slowBody.resolve({
    status: 200,
    text: () =>
      new Promise((resolve) => {
        releaseBody = resolve;
      }),
  });
  await settle();
  bridge.cancel();
  releaseBody("cancelled while reading body");
  await settle();
  assert.equal(calls.length, 0);
};
