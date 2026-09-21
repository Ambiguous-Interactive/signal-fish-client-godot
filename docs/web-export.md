---
description: "Running the Signal Fish client in Godot browser exports: scheme rules, auth, Origin, and storage cautions."
---

# Web Export

The client is pure GDScript on top of `WebSocketPeer`. Browser exports run
it with no native code and no extra build steps.

## Scheme rules

- Use `wss://` in production.
- Dialing `ws://` from a secure page fails loudly with
  `ERR_INVALID_PARAMETER` before any dial, and browsers themselves block
  insecure `ws://` dials to non-loopback hosts from HTTPS pages. The client
  never silently downgrades. The static
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

## Checklist automation

The browser checklist runs automatically in the weekly Web Export Smoke
workflow: the exported demo boots in headless Chromium over local HTTPS,
dials a local `wss://` server (the browser-set `Origin` is asserted server
side), round-trips `Authenticate`/`Ping`, and dials `ws://` from the secure
page, which the client refuses before any network traffic (the predial
check; loopback hosts are exempt from browser mixed-content blocking, so
that browser-level block only applies to production hosts). No manual
steps remain for the standard build.

Before shipping to production, still verify the host-specific items:

- Your HTTPS certificate is trusted by players' browsers.
- Your server accepts your page's `Origin`.

## Export preset and CI

The demo project ships a "Web" export preset that builds the demo straight
to a browser build. The preset exports all project resources (dev trees
excluded): scene-only exports do not follow `preload()` chains in scripts,
which left addon scripts out of the pack and broke the page at boot.

CI runs the scheduled web-export smoke: it imports the project, exports the
preset, asserts that the build produces `index.html` and `index.wasm`, and
runs the automated browser checklist above.
