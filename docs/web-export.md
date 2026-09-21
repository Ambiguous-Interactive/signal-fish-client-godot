---
description: "Running the Signal Fish client in Godot browser exports: scheme rules, auth, Origin, and storage cautions."
---

# Web Export

The client is pure GDScript on top of `WebSocketPeer`. Browser exports run
it with no native code and no extra build steps.

## Scheme rules

- Use `wss://` in production.
- Dialing `ws://` from a secure page fails loudly with
  `ERR_INVALID_PARAMETER` before any dial. The mixed-content check is
  local, and the client never silently downgrades. The static
  `insecure_scheme_error(url, is_web_platform, secure_page)` predial check
  produces this error.

## Authentication

Browsers cannot set WebSocket handshake headers, so authentication happens
after the socket opens. `connect_to_server()` auto-sends `Authenticate` on
open. No `Authorization` header is involved anywhere in the flow.

## Polling

The client is single-threaded and non-blocking. `poll()` drains the socket
from `_process` (or from your own loop) and never blocks, which fits the
browser's single-threaded runtime.

## Origin

`Origin` is a server-side policy. The browser sets it; the client cannot.
Allow-list your hosting origins on the server.

## Storage

Treat browser `localStorage` and query strings as user-visible. Keep
reconnection tokens in memory. Persist them only with an explicit,
documented decision, and never log them.

## Manual checklist

Before shipping a browser build, verify:

- The page is hosted over HTTPS.
- The client dials `wss://`.
- The server accepts your page's `Origin`.
- A `ws://` dial from the HTTPS page fails loudly instead of silently
  downgrading.
- Nothing in the build assumes threads or native sockets.

## Export preset and CI

The demo project ships a "Web" export preset that builds `demo/main.tscn`
straight to a browser build. CI runs a scheduled web-export smoke: it
imports the project, exports the preset, and asserts that the build
produces `index.html` and `index.wasm`.
