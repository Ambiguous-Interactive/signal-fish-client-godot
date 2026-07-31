---
description: Use when implementing or reviewing Godot transport adapters for WebSocket, WebRTC, polling, reconnect, or multiplayer APIs.
triggers: godot transport, client, runtime client, connect, connection, websocketpeer, WebSocketPeer, WebSocketClient, websocketmultiplayerpeer, browser export, Godot 3, Godot 4, webrtc, poll, reconnect, networking, protocol fixture
category: Godot
---

# Godot Transport Adapters

## Trigger

Use this skill for transport code under `addons/signal_fish/transport`,
connection lifecycle, polling, reconnect, backpressure, or choosing between
Godot networking APIs.

## Default Posture

- Build the Signal Fish service client on a thin WebSocket adapter first.
- Keep public client API, protocol encoding, and transport I/O separate.
- Implement Godot 4 first. Add Godot 3 only after a separate compatibility
  decision and smoke tests prove the `WebSocketClient` path.
- Treat WebRTC as optional peer-to-peer research, not the default client-server
  Signal Fish transport.

## WebSocket Guidance

- For Godot 4, prefer `WebSocketPeer` for raw protocol messages.
- Call `poll()` from a deterministic driver such as `_process` or an explicit
  client `poll()` method; never block waiting for packets.
- Read all available packets after polling, then hand decoded bytes to the
  protocol layer.
- Model states explicitly: disconnected, connecting, connected, closing, closed,
  failed. Treat failed as a client abstraction unless upstream defines a wire
  state with that name.
- Treat `opened`, `closed`, and `failed` as per-session lifecycle signals.
  Reset emission guards only when a fresh `connect_to_url` starts, suppress
  packets and later terminal signals after `closed` or `failed`, and keep fake
  transports behaviorally aligned with the real adapter. Closing while still
  connecting is a failed open, not a normal close.
- Close any active native peer before replacing or clearing it during reconnect
  or reset paths; never drop a live socket reference without closing it.
- Continue polling during close so close codes and reasons are observed.
- Inspect outbound buffered bytes before unbounded sends and expose
  backpressure to the caller.
- Use `WebSocketMultiplayerPeer` only when the feature is intentionally built
  around Godot high-level multiplayer or RPC.

## Version Adapters

- Godot 4 uses `WebSocketPeer`; Godot 3 uses `WebSocketClient` plus peer access
  through its connection lifecycle.
- Isolate API deltas in small adapter files instead of scattering version
  checks through the public client.
- Keep examples labeled by engine version when syntax differs, especially
  `await` versus `yield`, `@export` versus `export`, and packed array names.

## WebRTC Guidance

- WebRTC needs signaling, SDP offer/answer exchange, ICE candidates, STUN, and
  often TURN. Do not add it as a hidden dependency of the basic client.
- `WebRTCMultiplayerPeer` fits peer-to-peer gameplay. It is not a replacement
  for a service WebSocket unless Signal Fish explicitly adds a WebRTC transport.
- Native exports may require the Godot WebRTC native extension; browser exports
  use browser WebRTC support.

## Review Checklist

- Is the transport adapter free of protocol-specific parsing?
- Does every connection path require bounded polling instead of blocking?
- Are close code, close reason, timeout, and failed states surfaced?
- Are browser limitations from `.llm/skills/web-export.md` respected?
- Are Godot 3 and Godot 4 APIs separated cleanly?
