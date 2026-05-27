---
description: Use when writing or reviewing Godot addon code, GDScript APIs, scenes, resources, or exports.
triggers: godot, gdscript, addon, plugin, scene, resource, export, api
category: Godot
---

# Godot GDScript Bindings

## Trigger

Use this skill for runtime addon code, editor plugin code, project structure,
GDScript API design, and examples.

## Goals

- Prefer GDScript-first APIs so the client works on Godot web exports.
- Support major Godot versions intentionally; do not assume one version unless
  the task says so.
- Follow the MVP rule: implement Godot 4 first, then add Godot 3 only after a
  separate compatibility decision and `WebSocketClient` smoke tests.
- Keep public API names idiomatic for Godot users.
- Avoid C#-only guidance for runtime behavior.

## Compatibility Notes

- Godot 4 web exports do not support C#.
- GDScript and engine APIs differ between Godot 3.x and 4.x.
- Isolate version-specific logic behind small adapter files when practical.
- Avoid engine features that are unavailable or restricted on HTML5 exports.
- Prefer Godot 4 syntax in new examples unless a Godot 3 compatibility example
  is explicitly labeled.

## Expected Addon Shape

Use conventional Godot addon layout when implementation begins:

```text
addons/signal_fish/
  plugin.cfg
  signal_fish_client.gd
  transport/
  protocol/
  tests/
```

## API Design Rules

- Emit Godot signals for connection, message, error, and close events.
- Keep async behavior explicit; document whether callbacks run in `_process`,
  signal callbacks, or awaited coroutines.
- Use typed GDScript where supported, but avoid breaking older target versions
  unless the compatibility plan says so.
- Keep serialization boundaries narrow and testable.
- Keep transport adapters byte-oriented; public client code should not reach
  directly into `WebSocketPeer` unless the adapter is the public surface.

## Review Checklist

- Does the code run without C#?
- Is web export behavior considered?
- Are Godot 3 and Godot 4 differences called out?
- Are public names stable and easy for GDScript users?
- Is transport lifecycle delegated to `.llm/skills/godot-transport.md` guidance?

## See Also

- `.llm/code-samples/gdscript-client-shape.md` for the current public API sketch.
- `.llm/skills/godot-transport.md` for WebSocket, WebRTC, polling, and adapter
  rules.

