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

## Review Checklist

- Are secrets excluded from logs and fixtures?
- Does a failure path expose sensitive payloads?
- Can a web export leak data through browser storage or console output?
- Does the change introduce a dependency that is difficult for addon users to
  audit or update?
- Are insecure local endpoints and `ws://` examples clearly labeled as local
  development only?

