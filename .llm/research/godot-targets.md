---
description: Compatibility notes for targeting major Godot versions from a GDScript Signal Fish addon.
triggers: godot 3, Godot 3, godot 4, Godot 4, compatibility, gdscript, client, runtime client, SignalFishClient, connect, connection, browser export, web export, WebSocketPeer, WebSocketClient, addon
category: Research
---

# Godot Target Notes

The repo targets major Godot versions with a GDScript-first client. Keep this
file updated as the supported version matrix becomes explicit.

## Target Posture

- Godot 4 is the primary target for modern users and browser exports.
- Godot 3.6 compatibility was evaluated and deferred on 2026-10-06; see the
  decision below.
- C# should not be required for runtime use because Godot 4 web exports do not
  support it.

## MVP Rule

Implement the first usable runtime client for Godot 4 only. The Godot 3
compatibility decision landed 2026-10-06 as "defer"; see the decision below
for the data and the revisit triggers.

## Version Matrix

- Godot 4.x: primary target. Prefer `WebSocketPeer`, `PackedByteArray`,
  `@export`, `@onready`, `await`, typed GDScript, and signal objects.
- Godot 3.6: deferred (see the decision below). Expect `WebSocketClient`,
  `PoolByteArray`, `export`, `onready`, `yield`, unordered Dictionaries, and
  string-based signal connection syntax.
- Browser exports: require GDScript runtime code, non-blocking polling,
  browser-supported transports, and production `wss://` endpoints.

## Areas Likely To Need Version Adapters

- WebSocket APIs and connection lifecycle.
- Typed GDScript syntax.
- Signal declaration and connection syntax.
- Packed arrays and serialization helpers.
- Editor plugin registration.
- File and time helpers renamed between Godot 3 and Godot 4.

## Addon Packaging Notes

- Keep runtime code under `addons/signal_fish`.
- Avoid requiring project-wide autoloads unless the API explicitly documents
  that choice.
- Prefer portable examples that users can paste into a scene script.
- Keep editor tooling optional; runtime client code should not depend on editor
  classes.

## Validation Ideas

- Add a minimal Godot 4 smoke project when runtime code exists.
- Add a Godot 3 compatibility smoke project only if the codebase commits to
  supporting it.
- Add browser export smoke tests for WebSocket behavior once CI can run them.
- Add fake transport tests before live networking so adapter behavior is
  deterministic.

## Godot 3.6 Compatibility Decision (2026-10-06)

Decision: stay Godot 4.x only. The v1 gate ("separate compatibility
decision") resolves as "defer", with the data below. Revisit only on a
revisit trigger.

### Method

- Parse probe: gdtoolkit 3.6.0 (Godot 3 GDScript grammar, Python 3.12)
  over every runtime and test `.gd` file at `e1a63df`.
- Grep sweep for Godot 4-only constructs over `addons/`.
- Upstream facts: Godot release history; the Godot 4.0 Dictionary
  ordering change.

### Data (at `e1a63df`)

- Runtime (`addons/signal_fish`, 23 files, 7,809 lines): 21 files fail the
  Godot 3 grammar. The 2 passing files (transport layer) reference
  `WebSocketPeer`, which does not exist in Godot 3, so nothing runs.
- Tests (29 files, 17,394 lines): 0 files parse.
- Godot 4-only constructs in runtime code: 464 typed return annotations,
  108 typed for-loop variables, 37 typed signal parameters, typed arrays
  in 11 files, 63 StringName literals (`&"..."`), 23 Godot 4 annotations
  (`@tool`/`@export`/`@onready`/`@warning_ignore`), 4 `static var`
  (Godot 3 has no static variables), and 9 `Callable` uses, plus
  `WebSocketPeer`, `Time.get_ticks_usec`, `JSON.parse_string`,
  `to_utf8_buffer()`, and `Engine.get_singleton()` call sites.
- No `await` in runtime code (polling design); that port cost is zero.
- Godot 4.0 made Dictionaries insertion-ordered; Godot 3.x iteration order
  is unspecified. `sf_msgpack.gd` and the JSON envelope encode iterate
  dictionaries directly, and the suite pins encode bytes (upstream
  samples, byte-identity tests, float wire-text memo). On 3.x the encoder
  output order would be unstable, so the byte-pin verification strategy
  would need a redesign (key canonicalization or per-generation
  fixtures).
- The dialects cannot share files: Godot 3 keywords (`export`, `onready`,
  `tool`, `yield`) were removed in Godot 4, and Godot 4 syntax fails to
  parse on Godot 3. One addon folder serves one engine generation.
- Godot 3.6 remains in maintenance (3.6.3, Aug 2026) and ships no
  official Linux ARM64 build (4.3+ does). GodotSteam 3.x is a separate
  branch with an API shape different from the GodotSteam 4.x GDExtension
  the Steam bootstrap maps.

### Verdict

Godot 3.6 support is a permanent parallel fork: a full runtime and test
dialect port, a `WebSocketClient` adapter, a 3.x smoke suite, a toolchain
split (gdtoolkit 3.x vs 4.x format and lint), per-generation warning
pins, a wider CI matrix, and re-validation of every issue #161 hot-path
verdict per engine. The demand signal is currently zero. Defer.

### Revisit triggers

- Sustained user demand for Godot 3.x (Asset Library comments, an issue
  cluster).
- A concrete partner or sponsor requirement naming Godot 3.x.
- A tooling change that removes a structural blocker above.

If revived, open a new gate: fork plan, `WebSocketClient` adapter behind
`SFTransport`, 3.x smoke tests, CI matrix addition, then the rest.

## Source Notes

- Godot stable WebSocket and WebRTC docs define the current Godot 4 API shape.
- Godot 3.6 docs are the compatibility reference for `WebSocketClient`.
- See `.llm/research/godot-networking-web.md` for transport and browser links.
