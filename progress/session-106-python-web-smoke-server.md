# Session 106: move the web smoke server to Python

Branch: `codex/session-106-python-web-smoke-server` from `origin/main` at
`eed183f`.

- Replaced the weekly web export smoke server with a Python standard library
  server. The Playwright browser check still uses HTTPS and WSS.
- Verified static files, path containment, browser Origin, WebSocket upgrade,
  Authenticate, Ping, and the full browser export checklist locally.
- #168 stays open for the remaining automation migration.
