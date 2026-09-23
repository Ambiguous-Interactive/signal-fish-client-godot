---
description: Use when handling tokens, user identifiers, logs, persistence, networking, or dependency decisions.
triggers: security, privacy, token, secret, logging, storage, tls, dependency
category: Protocol
---

# Security And Privacy

## Trigger

Use this skill for authentication, credentials, persistence, logging, telemetry,
transport security, or dependency choices.

## Baselines

- Do not commit secrets, credentials, exported tokens, or private endpoints.
- Do not log tokens, session IDs, or user identifiers unless explicitly required
  for a local debugging task.
- Keep production connections on TLS.
- Treat browser storage as user-accessible.
- Keep dependency footprint small for Godot addon consumers.

## Godot Client Guidance

- Prefer explicit configuration for endpoint URLs and credentials.
- Make insecure local-development settings visually obvious in names and docs.
- Separate debug logging from normal runtime logging.
- Redact sensitive fields in error messages.
- Avoid storing long-lived secrets by default.
- For browser WebSocket exports, do not assume `Authorization` or other custom
  handshake headers are available. Prefer protocol-level auth after open unless
  a reviewed browser-compatible alternative is required.
- Treat query-string tokens and browser storage as exposed to users, logs,
  history, and hosting infrastructure unless proven otherwise.

## Repo Checklist (Signal Fish client)

- `app_id`, reconnection `auth_token`, and the reconnection token are never
  logged at the default level; `sf_log.gd` redacts them on all paths. Full
  payload debug logging is opt-in and local-only. Note tokens also ride in
  consumer-visible `raw`/`to_dict()` — document that logging whole payloads
  leaks them.
- `SignalFishConfig.credential` is a plain (non-exported) var so the Resource
  pipeline can never persist it. It rides `Authenticate` as the upstream
  `connect_token` field; values only (never globals), never stitched into
  URLs, absent from `to_string()`/debug output.
- Tokens never appear in fixtures (fake placeholders only), error messages,
  or signal payloads. Reviewers check every committed fixture.
- Authenticate **after** socket open — no `Authorization`/custom handshake
  headers in browsers. Production is `wss://`; `ws://` from a secure page is
  a loud `ERR_INVALID_PARAMETER` (no silent fallback). `Origin` is a
  server-side policy; the client cannot set it in a browser.
- Persist browser tokens only with an explicit, documented decision; treat
  `localStorage`/query strings as user-visible.
- CI secrets (`GODOT_ASSET_LIBRARY_*`) exist only in the publish job, least
  permissions, never echoed, never exposed to fork PRs. Release artifacts
  contain no tokens/`.env`/local config (verify the packaged file list).
- Keep the dependency footprint small (the pure-GDScript JSON path needs no
  third-party runtime dep); any new dep goes through a decision gate.

## Review Checklist

- Are secrets excluded from logs and fixtures?
- Does a failure path expose sensitive payloads?
- Can a web export leak data through browser storage or console output?
- Does the change introduce a dependency that is difficult for addon users to
  audit or update?
- Are insecure local endpoints and `ws://` examples clearly labeled as local
  development only?
