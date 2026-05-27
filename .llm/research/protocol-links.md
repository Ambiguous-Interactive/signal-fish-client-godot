---
description: Curated upstream references for Signal Fish protocol and client compatibility work.
triggers: signal fish, upstream, protocol, server, rust client, cloud
category: Research
---

# Signal Fish Upstream References

Use this file as the launch point for protocol research. Prefer upstream code
over assumptions when implementing message semantics.

## Repositories

- Signal Fish Cloud:
  https://github.com/Ambiguous-Interactive/signal-fish-cloud
- Signal Fish Server:
  https://github.com/Ambiguous-Interactive/signal-fish-server
- Signal Fish Rust Client:
  https://github.com/Ambiguous-Interactive/signal-fish-client-rust

## Current Notes

- The server repository advertises an in-memory Signal Fish server
  implementation.
- The Rust client repository advertises a client SDK for the Signal Fish server
  and protocol.
- Both related repositories already use `.llm` context folders, so keep this
  repo's harness compatible with that style.
- This Godot client should mirror Rust client behavior where client semantics
  are already established.
- Do not implement concrete wire formats, authentication flow, reconnect
  behavior, or error semantics until the upstream path and commit defining each
  detail are recorded.

## Research Workflow

1. Identify the upstream repo that owns the behavior.
2. Record the upstream path and commit if a detail affects implementation.
3. Summarize only durable facts here; place task-specific notes in issues or PRs.
4. If protocol schemas are copied into fixtures, note the upstream source.

## Facts To Verify Before Runtime Implementation

- Wire message envelope and payload schemas.
- Required handshake or authentication flow.
- Reconnect behavior and session resumption rules.
- Error payload shape and close code semantics.
- Ordering, deduplication, and retry expectations.

