---
description: Use when implementing protocol messages, transports, sessions, auth, or compatibility with upstream Signal Fish projects.
triggers: signal fish, protocol, websocket, session, auth, message, rust client, server
category: Protocol
---

# Signal Fish Protocol

## Trigger

Use this skill when changing protocol semantics, message schemas, connection
state, authentication, reconnection, or upstream compatibility.

## Ground Truth

Check upstream before guessing:

- Server: https://github.com/Ambiguous-Interactive/signal-fish-server
- Rust client: https://github.com/Ambiguous-Interactive/signal-fish-client-rust
- Cloud: https://github.com/Ambiguous-Interactive/signal-fish-cloud
- Curated notes: `.llm/research/protocol-links.md`

## Implementation Rules

- Treat the Rust client as the reference for client-side behavior.
- Treat the server as the reference for accepted message shapes and lifecycle.
- Before runtime implementation, anchor concrete wire formats,
  authentication flow, reconnect behavior, and error semantics to upstream
  file paths and commits.
- Preserve wire compatibility over local convenience.
- Keep transport, message encoding, and Godot-facing API separate.
- Never silently swallow protocol errors; surface them through explicit results,
  errors, or Godot signals.
- Do not rely on WebSocket handshake headers for browser exports. If upstream
  requires auth metadata, verify whether it can be sent after open as a
  protocol message or through an explicitly reviewed browser-compatible flow.
- Treat close codes, reconnect timing, duplicate messages, and backpressure as
  protocol-visible design questions before shipping automatic retries.

## Questions To Answer Before Coding

- Which upstream commit or release defines the behavior?
- Is the message direction client-to-server, server-to-client, or both?
- Does behavior differ for reconnects, duplicate messages, or partial failures?
- Is ordering, idempotency, or retry behavior required?
- Does the feature require secure storage or user secrets?
- Does the chosen transport work in Godot web exports without native-only socket
  features?

## Test Expectations

- Add fixtures for message encoding and decoding.
- Include failure cases for malformed input.
- Include transport-free tests where possible.
- Add integration tests only after deterministic unit coverage exists.
- Use fake transport adapters for reconnect, close, and backpressure tests
  before adding live WebSocket tests.

