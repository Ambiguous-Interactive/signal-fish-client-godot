const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function main() {
  await require("./test_webrtc_native_reference.cjs")();
  let sample;
  const output = [];
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
  await sample();
  let report = output.at(-1);
  assert.equal(report.created, 1);
  assert.equal(report.peers[0].channels[0].messages_received, 9);
  assert.equal(report.peers[0].channels[0].bytes_received, 90);
  assert.equal(report.peers[0].transports[0].bytes_sent, 100);
  assert.equal(report.peers[0].candidate_pairs.length, 1);
  assert.equal(report.peers[0].candidate_pairs[0].round_trip_seconds, 0.1);
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
