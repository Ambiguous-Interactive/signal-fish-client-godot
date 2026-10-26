let tail = Promise.resolve();
let current = null;
let polling = false;

function command(value) {
  const result = tail.then(async () => {
    const response = await fetch("/native/command", {
      method: "POST",
      body: JSON.stringify(value),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? "native command failed");
    return body.result;
  });
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
      for (const event of body.result) current?.dispatch(event);
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
    if (this.signaling || !this.paired) return;
    for (const event of this.candidates.splice(0))
      this.callbacks.onLocalCandidate(
        "godot",
        event.generation,
        event.candidate,
      );
  }
  async pairWith(_peer, offer, _servers) {
    this.paired = true;
    const result = await this.signalCommand({ op: "pair", offer });
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
    if (!this.paired) return;
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
          close: () => void command({ op: "close", label: event.label }),
        });
        this.callbacks.onChannelOpen(...args, event.label);
        break;
      case "closed":
        if (this.channels.has(event.label))
          this.channels.get(event.label).readyState = "closed";
        this.callbacks.onChannelClosed(...args, event.label, "native callback");
        break;
      case "message":
        this.callbacks.onChannelMessage(...args, event.label, event.text);
        break;
      default:
        throw new Error("unknown native event");
    }
  }
}
