---
description: "How the deterministic Godot test suite works, what it covers, and how to run it locally."
---

# Deterministic Testing

The test suite has no framework dependency and no network. Custom
`SceneTree` runners under `tests/` run with `godot --headless --script` and
produce deterministic results:

- **Byte-pinned fixtures.** Codec tests compare exact bytes against
  fixture files.
- **Injected clocks.** Reconnect backoff tests step time manually. No
  sleeps, no wall-clock waiting.
- **Synchronous fake transport.** `SFFakeTransport` is an in-memory test
  double with injectors (`inject_open()`, `inject_text()`,
  `inject_server_message()`, `inject_binary()`, `inject_close()`,
  `inject_failure()`) and recorded `sent_text` / `sent_binary` buffers.

## Suites

- **Protocol fixtures.** The upstream v2 samples (server v0.9.2) are
  vendored byte-identically under `tests/fixtures/upstream/`, and the codec
  is pinned to them. Hand-built fixtures cover all 24 server message
  variants plus malformed input.
- **Transport.** The `WebSocketPeer` adapter runs against fakes for
  connect, receive, send, close, error, and backpressure behavior.
- **Client.** Connect, authenticate, join, game data, authority,
  spectators, reconnection, and the WebRTC mesh all run on fake transports
  and injected clocks.

## Run locally

```bash
bash scripts/run-runtime-checks.sh all
```

`all` runs the private-helper guard, format checks, lint, and the Godot
suites. Subcommands for targeted runs:

- `static`: private-helper guard, format, and lint. No Godot install.
- `private-helpers`: the private-helper static guard.
- `format`: gdformat checks.
- `lint`: gdlint.
- `godot`: the SceneTree suites.

### Smoke (opt-in)

```bash
bash scripts/run-runtime-checks.sh smoke
```

`smoke` is never part of `all`. It drives a real `WebSocketPeer` round-trip
against a local RFC 6455 test server: open, echo round-trips, close
handshakes in both directions, and refused-dial failure.

## Type strictness

All GDScript in the addon is fully explicitly typed. The project promotes
`untyped_declaration` and the `unsafe_*` Variant-access checks to errors,
so untyped declarations or unsafe property and method access fail CI.
