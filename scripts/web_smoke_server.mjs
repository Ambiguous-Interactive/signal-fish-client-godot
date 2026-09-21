// Local HTTPS static server + minimal RFC 6455 wss server for the weekly
// web-export browser check. Asserts the browser-set Origin and answers the
// demo's Authenticate/Ping handshake. Machine-readable lines are prefixed
// with "SMOKE " so the Playwright driver can assert on them.
import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import path from "node:path";

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index !== -1 && process.argv[index + 1] !== undefined) {
    return process.argv[index + 1];
  }
  return fallback;
}

const webRoot = path.resolve(arg("web-root", "build/web"));
const httpsPort = Number(arg("https-port", "8443"));
const wssPort = Number(arg("wss-port", "8444"));
const host = arg("host", "127.0.0.1");
const expectedOrigin = arg("expected-origin", `https://${host}:${httpsPort}`);
const tlsOptions = {
  key: fs.readFileSync(arg("key", "build/smoke-certs/key.pem")),
  cert: fs.readFileSync(arg("cert", "build/smoke-certs/cert.pem")),
};

function emit(event, fields) {
  process.stdout.write(`SMOKE ${JSON.stringify({ event, ...fields })}\n`);
}

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

const staticServer = https.createServer(tlsOptions, (request, response) => {
  let urlPath = "";
  try {
    urlPath = decodeURIComponent(new URL(request.url, `https://${host}`).pathname);
  } catch {
    response.writeHead(400);
    response.end("bad request");
    return;
  }
  const filePath = path.join(webRoot, urlPath === "/" ? "index.html" : urlPath);
  const relative = path.relative(webRoot, filePath);
  const insideRoot = relative !== "" && !relative.startsWith("..");
  if (!insideRoot || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    response.writeHead(404);
    response.end("not found");
    return;
  }
  response.writeHead(200, {
    "content-type": MIME_TYPES[path.extname(filePath)] ?? "application/octet-stream",
  });
  fs.createReadStream(filePath).pipe(response);
});

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function acceptKey(key) {
  return crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
}

function encodeTextFrame(text) {
  const payload = Buffer.from(text, "utf8");
  if (payload.length > 0xffff) {
    throw new Error(`smoke frame too large: ${payload.length} bytes`);
  }
  const header = Buffer.from([0x81, payload.length < 126 ? payload.length : 126]);
  const extension = payload.length < 126 ? Buffer.alloc(0) : (() => {
    const bytes = Buffer.alloc(2);
    bytes.writeUInt16BE(payload.length);
    return bytes;
  })();
  return Buffer.concat([header, extension, payload]);
}

// Minimal client-frame reader for the smoke handshake only: text frames
// (0x1), close (0x8), and ping (0x9). Client frames must be masked (RFC
// 6455); anything else fails the connection via onFatal.
function decodeClientFrames(buffer, onText, onClose, onFatal) {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const opcode = buffer[offset] & 0x0f;
    const masked = (buffer[offset + 1] & 0x80) !== 0;
    if (!masked) {
      return onFatal("unmasked client frame");
    }
    if (opcode !== 0x1 && opcode !== 0x8 && opcode !== 0x9) {
      return onFatal(`unexpected opcode ${opcode}`);
    }
    let length = buffer[offset + 1] & 0x7f;
    let frameEnd = offset + 2;
    if (length === 126) {
      if (buffer.length - frameEnd < 2) return offset;
      length = buffer.readUInt16BE(frameEnd);
      frameEnd += 2;
    } else if (length === 127) {
      if (buffer.length - frameEnd < 8) return offset;
      length = Number(buffer.readBigUInt64BE(frameEnd));
      frameEnd += 8;
    }
    const maskKey = buffer.subarray(frameEnd, frameEnd + 4);
    frameEnd += 4;
    if (buffer.length - frameEnd < length) return offset;
    const payload = Buffer.from(buffer.subarray(frameEnd, frameEnd + length));
    for (let i = 0; i < payload.length; i += 1) {
      payload[i] ^= maskKey[i % 4];
    }
    offset = frameEnd + length;
    if (opcode === 0x1) onText(payload.toString("utf8"));
    if (opcode === 0x8) onClose();
  }
  return offset;
}

const wssServer = https.createServer(tlsOptions);
wssServer.on("upgrade", (request, socket) => {
  const originOk = request.headers.origin === expectedOrigin;
  emit("ws_open", { origin: request.headers.origin ?? null, origin_ok: originOk });
  if (!originOk || !request.headers["sec-websocket-key"]) {
    socket.destroy();
    return;
  }
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${acceptKey(request.headers["sec-websocket-key"])}\r\n\r\n`,
  );
  let pending = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    const consumed = decodeClientFrames(
      pending,
      (text) => {
        let type = "";
        try {
          type = String(JSON.parse(text).type ?? "");
        } catch {
          type = "<unparseable>";
        }
        emit("message", { type });
        if (type === "Authenticate") {
          socket.write(
            encodeTextFrame(
              JSON.stringify({
                type: "Authenticated",
                data: {
                  app_name: "web-smoke",
                  organization: "smoke",
                  rate_limits: { per_minute: 60, per_hour: 600, per_day: 6000 },
                },
              }),
            ),
          );
        } else if (type === "Ping") {
          socket.write(encodeTextFrame(JSON.stringify({ type: "Pong" })));
          emit("pong_sent", {});
        }
      },
      () => {
        emit("ws_close", {});
        socket.end();
      },
      (reason) => {
        emit("ws_fatal", { reason });
        socket.destroy();
        return 0;
      },
    );
    pending = pending.subarray(consumed);
  });
});

function listenOrFail(server, role, port) {
  server.on("error", (error) => {
    emit("fatal", { role, error: String(error) });
    process.exit(1);
  });
  server.listen(port, host, () => emit("listening", { role, port }));
}

listenOrFail(staticServer, "https", httpsPort);
listenOrFail(wssServer, "wss", wssPort);

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  staticServer.close();
  wssServer.close();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
