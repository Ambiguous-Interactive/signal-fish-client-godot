(() => {
  const sockets = [];
  const rejections = [];
  let omitted = 0;
  let active = null;
  const originalError = console.error;
  console.error = function (...args) {
    if (
      args.some((value) =>
        /(Buffer (payload )?full!|Too many packets in queue!) Dropping data\./.test(
          String(value),
        ),
      )
    ) {
      if (rejections.length < 4096) {
        rejections.push({
          browser_ms: performance.now(),
          reason: args.some((value) =>
            String(value).includes("Too many packets in queue!"),
          )
            ? "packet_capacity"
            : "payload_capacity",
          callback_scope: active ? "engine_onmessage" : null,
          callback: active ? { ...active } : null,
        });
      } else omitted++;
    }
    return Reflect.apply(originalError, this, args);
  };
  window.websocketReceiveSnapshot = () => ({
    sockets: sockets.map((socket) => ({
      ...socket,
      callbacks: socket.callbacks.slice(),
    })),
    rejections: rejections.slice(),
    omitted,
  });
  const Original = window.WebSocket;
  window.WebSocket = new Proxy(Original, {
    construct(target, args, newTarget) {
      const socket = Reflect.construct(target, args, newTarget);
      const record = {
        connection: sockets.length + 1,
        callbacks: [],
        received: 0,
        omitted: 0,
        wrapped: false,
      };
      if (sockets.length >= 32) {
        omitted++;
        return socket;
      }
      sockets.push(record);
      let owner = socket;
      let property;
      while (owner && !property) {
        property = Object.getOwnPropertyDescriptor(owner, "onmessage");
        owner = Object.getPrototypeOf(owner);
      }
      if (!property?.get || !property?.set) return socket;
      const events = new WeakMap();
      socket.addEventListener("message", (event) => {
        record.received++;
        if (record.callbacks.length >= 16384) {
          record.omitted++;
          return;
        }
        const data = event.data;
        const bytes =
          typeof data === "string"
            ? new TextEncoder().encode(data).length
            : (data.byteLength ?? data.size);
        const prefix =
          typeof data === "string"
            ? data.slice(0, 96)
            : data instanceof ArrayBuffer
              ? new TextDecoder().decode(
                  new Uint8Array(data, 0, Math.min(bytes, 96)),
                )
              : null;
        let relaySequence = null;
        if (
          typeof data === "string" &&
          bytes <= 16384 &&
          prefix?.includes('"GameData"')
        ) {
          try {
            const message = JSON.parse(data);
            const payload = message?.data?.data;
            if (
              message.type === "GameData" &&
              Number.isSafeInteger(payload?.sequence) &&
              payload.sequence >= 0 &&
              payload.body === "0123456789abcdef".repeat(256)
            )
              relaySequence = payload.sequence;
          } catch {}
        }
        const callback = {
          connection: record.connection,
          ordinal: record.received,
          browser_ms: performance.now(),
          bytes,
          prefix,
          relay_sequence: relaySequence,
        };
        record.callbacks.push(callback);
        events.set(event, callback);
      });
      let handler = null;
      Object.defineProperty(socket, "onmessage", {
        configurable: true,
        enumerable: property.enumerable,
        get: () => handler,
        set(value) {
          handler = typeof value === "function" ? value : null;
          const assigned = handler;
          property.set.call(
            socket,
            assigned
              ? function (event) {
                  const previous = active;
                  active = events.get(event) ?? null;
                  try {
                    return Reflect.apply(assigned, this, [event]);
                  } finally {
                    active = previous;
                  }
                }
              : null,
          );
          record.wrapped = handler !== null;
        },
      });
      return socket;
    },
  });
})();
