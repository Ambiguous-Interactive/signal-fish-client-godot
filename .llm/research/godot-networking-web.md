---
description: Source-backed notes for Godot WebSocket, WebRTC, browser export, and cross-platform networking decisions.
triggers: websocket, websocketpeer, WebSocketPeer, WebSocketClient, webrtc, browser, browser export, web export, client, runtime client, connect, connection, multiplayer, godot networking, Godot 3, Godot 4, protocol fixture
category: Research
---

# Godot Networking And Web Notes

## Sources Checked

The `stable` Godot links below are drifting references for the current stable
docs. When pinning implementation behavior, cite versioned docs for the target
engine line, such as Godot 4.x `WebSocketPeer` or Godot 3.6 `WebSocketClient`.

- Godot high-level multiplayer:
  https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- Godot WebSocket tutorial:
  https://docs.godotengine.org/en/stable/tutorials/networking/websocket.html
- Godot `WebSocketPeer`:
  https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html
- Godot `WebSocketMultiplayerPeer`:
  https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html
- Godot WebRTC tutorial:
  https://docs.godotengine.org/en/stable/tutorials/networking/webrtc.html
- Godot `WebRTCMultiplayerPeer`:
  https://docs.godotengine.org/en/stable/classes/class_webrtcmultiplayerpeer.html
- Godot web export docs:
  https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html
- Godot 4.3 web export progress:
  https://godotengine.org/article/progress-report-web-export-in-4-3/
- Godot WebRTC article:
  https://evanwildenha.in/posts/godot_webrtc/
- Godot WebRTC native extension:
  https://github.com/godotengine/webrtc-native

## Current Conclusions

- Use `WebSocketPeer` as the primary Godot 4 transport for a custom Signal Fish
  client protocol.
- Implement Godot 4 first. Add Godot 3 support only after a separate
  compatibility decision and smoke tests against `WebSocketClient`.
- Use `WebSocketMultiplayerPeer` only for Godot high-level multiplayer/RPC
  features, not for the default protocol client abstraction.
- Avoid old third-party WebSocket implementations for new Godot 4 code; built-in
  APIs are the maintained path.
- Browser exports cannot use raw TCP/UDP/ENet. Plan around WebSocket and, only
  when justified, WebRTC.
- WebRTC is a peer-to-peer transport family that requires signaling, SDP/ICE,
  STUN, and often TURN. It should remain optional research until protocol needs
  justify it.

## Browser Checklist

- Use `wss://` in production and ensure the hostname matches the certificate.
- Do not rely on custom WebSocket handshake headers in browser exports.
- Authenticate at the protocol layer after open, or deliberately design a safe
  cookie, query token, or subprotocol flow.
- Do not serve `ws://` from an HTTPS page because browsers reject mixed content;
  this is distinct from HTTP CORS.
- Treat WebSocket `Origin` handling as a server policy decision. Browser clients
  send an `Origin` header, but Godot browser export code cannot freely set
  handshake headers.
- Test with real browser exports; editor and native exports do not exercise the
  same hosting, origin, and TLS constraints.
- Avoid blocking loops. Poll from `_process` or an explicit bounded tick.

## Implementation Notes

- Keep transport adapters byte-oriented and push message schemas into protocol
  code.
- Drain all available packets after each poll.
- Keep polling during close to capture close code and reason.
- Track buffered output so callers can react to backpressure.
- Add fake transport tests before live network tests.
- Pin protocol fixtures to upstream Signal Fish paths and commits before using
  them as compatibility proof.
