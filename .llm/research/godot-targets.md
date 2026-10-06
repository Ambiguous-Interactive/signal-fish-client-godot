---
description: Godot 4.x target notes for the GDScript Signal Fish addon, with the recorded Godot 3.6 compatibility deferral.
triggers: godot 3, Godot 3, godot 4, Godot 4, compatibility, gdscript, client, runtime client, SignalFishClient, connect, connection, browser export, web export, WebSocketPeer, WebSocketClient, addon
category: Research
---

# Godot Target Notes

The repo targets Godot 4.x with a GDScript-first client; Godot 3.6
support is deferred (decision below).

## Target Posture

- Godot 4 is the target for modern users and browser exports.
- Godot 3.6 compatibility was evaluated and deferred on 2026-10-06; see the
  decision below.
- C# should not be required for runtime use because Godot 4 web exports do not
  support it.

## MVP Rule

Implement the first usable runtime client for Godot 4 only. The Godot 3
compatibility decision landed 2026-10-06 as "defer"; see the decision below
for the data and the revisit triggers.

## Version Matrix

- Godot 4.x: the target. Prefer `WebSocketPeer`, `PackedByteArray`,
  `@export`, `@onready`, `await`, typed GDScript, and signal objects.
- Godot 3.6: deferred (see the decision below). Expect `WebSocketClient`,
  `PoolByteArray`, `export`, `onready`, `yield`, unordered Dictionaries, and
  string-based signal connection syntax.
- Browser exports: require GDScript runtime code, non-blocking polling,
  browser-supported transports, and production `wss://` endpoints.

## Areas Likely To Need Version Adapters

Pre-decision notes, kept for context; the decision below answers them.

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
- Add browser export smoke tests for WebSocket behavior once CI can run them.
- Add fake transport tests before live networking so adapter behavior is
  deterministic.

## Godot 3.6 Compatibility Decision (2026-10-06)

Decision: stay Godot 4.x only. The v1 gate ("separate compatibility
decision") resolves as "defer", with the data below. Revisit only on a
revisit trigger.

### Method

- Engine probe: Godot 3.6.3-stable (official Linux ARM64 build) run
  headless with `--check-only -s` over every runtime and test `.gd` file
  at `e1a63df`, counting per-file parse errors.
- Cross-check: gdtoolkit 3.6.0 (Godot 3 GDScript grammar, Python 3.12).
- Grep sweep for Godot 4-only constructs over `addons/`.
- Upstream facts: Godot release history; the Godot 4.0 Dictionary
  ordering change.

### Data (at `e1a63df`)

- Runtime (`addons/signal_fish`, 23 files, 7,809 lines): 23 of 23 files
  fail the Godot 3.6.3 engine parser. First failures include
  `Unexpected '@'` (Godot 4 annotations), `Unknown class: "RefCounted"`
  (Godot 3 names the base class `Reference`), typed `signal` parameters,
  typed `const` arrays, and typed for-loop variables.
- Cross-check: under the gdtoolkit 3.6.0 grammar, 21 of 23 runtime files
  fail; the 2 survivors (transport layer) still fail the engine on
  `RefCounted`, and they use the standalone `WebSocketPeer` API
  (`connect_to_url`, `poll`, ready-state constants), which Godot 3 does
  not expose (3.x peers are handles from `WebSocketClient` and
  `WebSocketServer`).
- Tests (29 files, 17,394 lines): 0 of 29 load under the engine probe.
- Godot 4-only constructs in runtime code: 464 typed return annotations,
  108 typed for-loop variables, 37 typed signal parameters, typed arrays
  in 11 files, 63 StringName literals (`&"..."`), 23 Godot 4 annotations
  (`@tool`/`@export`/`@warning_ignore`), 4 `static var`
  (Godot 3 has no static variables), and 9 `Callable` uses, plus
  standalone `WebSocketPeer` usage, `JSON.parse_string`, and
  `to_utf8_buffer()` call sites (checked against the 3.6.3 engine's
  `ClassDB`).
- No `await` in runtime code (polling design); that port cost is zero.
- Godot 4.0 made Dictionaries insertion-ordered; Godot 3.x iteration order
  is unspecified. `sf_envelope.gd` and `sf_msgpack.gd` iterate
  dictionaries during encode, and the suite asserts encoder output
  against pinned fixture lines (`run_protocol_tests.gd`,
  `v3_protocol_tests.gd` vs the `tests/fixtures/*_messages.jsonl` sets).
  Unspecified 3.x order makes those pins unverifiable; the
  encode-vs-encode byte-identity checks would keep passing on 3.x while
  proving little. The byte-pin strategy would need key
  canonicalization or per-generation fixtures.
- The dialects cannot share files: Godot 3 keywords (`export`, `onready`,
  `tool`, `yield`) were removed in Godot 4, and Godot 4 syntax fails to
  parse on Godot 3. One addon folder serves one engine generation.
- Godot 3.6 remains in maintenance (3.6.3, Aug 2026); official Linux
  ARM64 builds exist for both engine lines, so platform coverage is not
  a differentiator, and this probe ran on the arm64 build. GodotSteam
  3.x is a separate branch with an API shape different from the
  GodotSteam 4.x GDExtension the Steam bootstrap maps.

### Verdict

Godot 3.6 support is a permanent parallel fork: a full runtime and test
dialect port, a `WebSocketClient` adapter, a 3.x smoke suite, a toolchain
split (gdtoolkit 3.x vs 4.x format and lint), per-generation warning
pins, a wider CI matrix, and re-validation of every issue #161 hot-path
verdict per engine. Cheaper shapes die on the same rocks: a godot-3
release branch still carries the full dialect port and split toolchain,
and a syntax-transpile step still has to bridge the API renames
(`Reference`, `Pool*` arrays, `WebSocketClient`) plus the unordered
Dictionary hazard. The demand signal is currently zero. Defer.

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
