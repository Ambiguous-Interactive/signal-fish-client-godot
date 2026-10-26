let tail = Promise.resolve();
let current = null;
let polling = false;
let pendingBatch = null;

function command(value) {
  const packet = value.op === "send" || value.op === "send_binary";
  if (packet && pendingBatch && pendingBatch.packets.length < 256) {
    pendingBatch.packets.push(value);
    return pendingBatch.result;
  }
  const batch = packet ? { packets: [value] } : null;
  pendingBatch = batch;
  const result = tail.then(async () => {
    if (pendingBatch === batch) pendingBatch = null;
    if (batch && window.referenceError) throw new Error(window.referenceError);
    const response = await fetch("/native/command", {
      method: "POST",
      body: JSON.stringify(
        batch ? { op: "send_batch", packets: batch.packets } : value,
      ),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? "native command failed");
    return body.result;
  });
  if (batch) batch.result = result;
  tail = result.catch((error) => {
    window.referenceError ??= String(error);
  });
  return result;
}

async function pump() {
  if (polling) return;
  polling = true;
  try {
    while (!window.referenceDone && !window.referenceError) {
      const response = await fetch("/native/events");
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? "native events failed");
      for (const event of body.result) {
        if (window.referenceError) break;
        current?.dispatch(event);
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  } catch (error) {
    window.referenceError ??= String(error);
  } finally {
    polling = false;
  }
}

export class Engine {
  constructor(_verbose, callbacks) {
    this.callbacks = callbacks;
    this.nativeProfile = true;
    this.channels = new Map();
    this.startupPhase = 0;
    this.startupSent = 0;
    this.paired = false;
    this.generation = null;
    this.pending = [];
    this.candidates = [];
    this.signaling = 0;
    current = this;
    void pump();
  }
  async signalCommand(value) {
    this.signaling++;
    try {
      return await command(value);
    } finally {
      setTimeout(() => {
        this.signaling--;
        this.flushCandidates();
      }, 0);
    }
  }
  flushCandidates() {
    if (window.referenceError || this.signaling || !this.paired) return;
    for (const event of this.candidates.splice(0))
      this.callbacks.onLocalCandidate(
        "godot",
        event.generation,
        event.candidate,
      );
  }
  async pairWith(_peer, offer, servers) {
    this.paired = true;
    const result = await this.signalCommand({
      op: "pair",
      offer,
      ice_servers: servers,
      startup_phase: this.startupPhase,
    });
    this.generation = result.generation;
    for (const event of this.pending) this.dispatch(event);
    this.pending = [];
    return result.offer;
  }
  async handleOffer(_peer, sdp) {
    return await this.signalCommand({ op: "offer", sdp });
  }
  async handleAnswer(_peer, sdp) {
    await this.signalCommand({ op: "answer", sdp });
  }
  async handleRemoteCandidate(_peer, candidate) {
    await command({ op: "candidate", candidate });
  }
  noteChannelOpen() {}
  channel(_peer, label) {
    return this.channels.get(label);
  }
  diagnosticSnapshot() {
    return {
      backend: "native",
      generation: this.generation,
      startup_sent: this.startupSent,
      channels: Object.fromEntries(
        [...this.channels].map(([label, channel]) => [
          label,
          { readyState: channel.readyState, ...channel.properties },
        ]),
      ),
    };
  }
  async removePeer() {
    if (!this.paired) return;
    const snapshot = await command({ op: "snapshot" });
    window.nativeReferenceSnapshots ??= [];
    window.nativeReferenceSnapshots.push(snapshot);
    if ((await command({ op: "remove" })) !== true)
      throw new Error("native teardown retained peer");
    this.paired = false;
    for (const channel of this.channels.values()) channel.readyState = "closed";
  }
  isPaired() {
    return this.paired;
  }
  dispatch(event) {
    if (window.referenceError || !this.paired) return;
    if (this.generation === null) {
      this.pending.push(event);
      return;
    }
    if (event.generation !== this.generation) return;
    const args = ["godot", event.generation];
    switch (event.event) {
      case "candidate":
        this.candidates.push(event);
        this.flushCandidates();
        break;
      case "state":
        this.callbacks.onPcState(...args, event.state);
        break;
      case "open":
        this.channels.set(event.label, {
          readyState: "open",
          properties: event.properties,
          send: (text) =>
            void command({ op: "send", label: event.label, text }),
          sendBinary: (data) => {
            if (!(data instanceof Uint8Array))
              throw new Error("native binary send needs Uint8Array");
            void command({
              op: "send_binary",
              label: event.label,
              data_base64: btoa(
                Array.from(data, (byte) => String.fromCharCode(byte)).join(""),
              ),
            });
          },
          close: () => void command({ op: "close", label: event.label }),
        });
        this.callbacks.onChannelOpen(...args, event.label);
        break;
      case "startup_sent":
        this.startupSent = event.count;
        break;
      case "closed":
        if (this.channels.has(event.label))
          this.channels.get(event.label).readyState = "closed";
        this.callbacks.onChannelClosed(...args, event.label, "native callback");
        break;
      case "message":
        this.callbacks.onChannelMessage(...args, event.label, event.text);
        break;
      case "binary":
        if (typeof this.callbacks.onChannelBinaryMessage !== "function")
          throw new Error("native binary callback is missing");
        this.callbacks.onChannelBinaryMessage(
          ...args,
          event.label,
          Uint8Array.from(atob(event.data_base64), (byte) =>
            byte.charCodeAt(0),
          ),
        );
        break;
      case "receive_rejected":
        throw new Error(
          `native receive rejected: generation=${event.generation} channel=${event.label}`,
        );
      default:
        throw new Error("unknown native event");
    }
  }
}
