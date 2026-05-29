---
description: Use when code may run in browser exports, WebSocket or WebRTC transport, storage, crypto, or platform-specific Godot behavior.
triggers: web export, browser export, html5, browser, websocket, WebSocketPeer, WebSocketClient, client, runtime client, connect, connection, webrtc, cors, origin, mixed content, tls, storage, crypto, Godot 4
category: Godot
---

# Godot Web Export Constraints

## Trigger

Use this skill for networking, storage, crypto, threading, file access, and any
runtime behavior that must work in Godot browser exports.

## Constraints

- Godot 4 web exports cannot use C# runtime code.
- Browsers restrict raw sockets; plan around WebSocket or browser-supported
  transports.
- Browser security policies affect TLS, cookies, redirects, local storage,
  WebSocket `Origin`, mixed content, and HTTP CORS.
- HTTP CORS applies to browser HTTP APIs such as `fetch`, not to WebSocket in
  the same way. WebSocket handshakes carry a browser-controlled `Origin` header;
  servers may validate it, but client code cannot set arbitrary handshake
  headers in browser exports.
- Mixed-content blocking is separate from CORS: an HTTPS page cannot open
  `ws://` even if HTTP CORS headers are permissive.
- Long-running blocking calls can freeze the page.
- File-system access is sandboxed and differs from desktop exports.
- Browser WebSocket clients cannot rely on custom handshake headers, TCP
  options, or host/port inspection available in native builds.
- Threaded web exports need specific cross-origin isolation headers; prefer the
  simplest single-threaded export path unless threads are required.

## Transport Guidance

- Prefer `WebSocketPeer` or a thin adapter around the Godot-supported WebSocket
  API for the target version.
- Keep transport lifecycle observable through signals.
- Make connection state explicit: disconnected, connecting, connected, closing,
  closed, failed.
- Handle close codes and reconnect policy deliberately.
- Use `wss://` in production and avoid `ws://` from HTTPS pages because browsers
  block mixed-content WebSocket connections.
- Configure the server to accept only intended browser `Origin` values; do not
  model this as an HTTP CORS fix unless an HTTP endpoint is involved.
- Authenticate after the socket opens at the protocol layer unless a reviewed
  cookie, query token, or subprotocol design is intentional.
- Test browser exports separately from editor/native runs because origin, TLS,
  and hosting behavior differ.
- Treat WebRTC as a separate peer-to-peer feature requiring signaling, STUN, and
  often TURN.

## Security Guidance

- Do not log tokens, session secrets, or user identifiers by default.
- Prefer TLS endpoints for production.
- Avoid storing long-lived secrets in browser-accessible storage unless the
  product decision explicitly accepts that risk.

## Review Checklist

- Is this API available in the targeted Godot web versions?
- Does it avoid blocking the main thread?
- Does it handle browser connection failures clearly?
- Are secrets protected from logs and unnecessary persistence?
- Does it avoid assuming native-only socket features in browser exports?
- Are WebSocket `Origin`, mixed-content, and HTTP CORS concerns separated?

