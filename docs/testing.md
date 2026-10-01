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
python3 -E scripts/run-runtime-checks.py all
```

`all` runs the private-helper guard, GDScript and Python format/lint checks,
strict Python typing, the Prettier check, and the Godot suites. Subcommands
for targeted runs:

- `static`: private-helper guard, format/lint, and Python types. No Godot install.
- `python-types`: Python format, lint, and strict types.
- `private-helpers`: the private-helper static guard.
- `format`: gdformat checks.
- `lint`: gdlint.
- `prettier`: the Prettier half of CI's Source formatting job. Needs `npm ci --ignore-scripts` first.
- `godot`: the SceneTree suites.

### Smoke (opt-in)

```bash
python3 -E scripts/run-runtime-checks.py smoke
```

`smoke` is never part of `all`. It drives a real `WebSocketPeer` round-trip
against a local RFC 6455 test server: open, echo round-trips, close
handshakes in both directions, and refused-dial failure.

## Type strictness

Every GDScript warning class the engine matrix registers is pinned to error
level in `project.godot` except three: `:=` type inference and discarded
return values stay ignorable by style, and the 4.7-only `missing_await`
stays unpinned because a marker naming it is a parse error on engines that
lack the class. The checks apply to the addon as well:
the engine default `exclude_addons` is explicitly disabled, so a warning
regression fails CI anywhere in the repo. The small set of statements that
are not yet fully typed carry an explicit `@warning_ignore` marker naming
exactly what they trigger: grep for `@warning_ignore` in `addons/` for the
live list.
