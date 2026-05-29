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
- Godot 3.6 compatibility should be deliberate and tested before claiming
  support.
- C# should not be required for runtime use because Godot 4 web exports do not
  support it.

## MVP Rule

Implement the first usable runtime client for Godot 4 only. Add Godot 3 support
only after a separate compatibility decision, isolated adapter plan, and smoke
tests prove the `WebSocketClient` path.

## Version Matrix

- Godot 4.x: primary target. Prefer `WebSocketPeer`, `PackedByteArray`,
  `@export`, `@onready`, `await`, typed GDScript, and signal objects.
- Godot 3.6: compatibility target only after smoke tests. Expect
  `WebSocketClient`, `PoolByteArray`, `export`, `onready`, `yield`, and older
  signal connection syntax.
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

## Source Notes

- Godot stable WebSocket and WebRTC docs define the current Godot 4 API shape.
- Godot 3.6 docs are the compatibility reference for `WebSocketClient`.
- See `.llm/research/godot-networking-web.md` for transport and browser links.

