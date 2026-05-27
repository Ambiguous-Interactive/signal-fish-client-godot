---
description: Sketch of the intended GDScript-facing Signal Fish client shape.
triggers: gdscript, client, runtime client, SignalFishClient, connect, connection, client api, signals, websocket, WebSocketPeer, WebSocketClient, Godot 3, Godot 4, browser export, protocol fixture, example
category: Code Sample
---

# GDScript Client Shape

This is a design sketch, not a committed runtime API or drop-in runtime code.

```gdscript
extends Node
class_name SignalFishClient

signal connected
signal disconnected(code, reason)
signal message_received(message)
signal protocol_error(error)

enum State {
    # Idle before any transport is opened, or after explicit cleanup.
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    CLOSING,
    # A transport close frame or close event was observed.
    CLOSED,
    # Client abstraction for unrecoverable open, send, parse, or protocol errors.
    # Do not treat this as a Signal Fish wire state unless upstream defines it.
    FAILED,
}

var state: int = State.DISCONNECTED
var endpoint_url: String = ""
var transport = null

# Minimal transport adapter contract, kept below the public client API:
# - signal opened()
# - signal packet_received(packet: PackedByteArray)
# - signal closed(code: int, reason: String)
# - signal failed(error: String)
# - connect_to_url(url), poll(), send_packet(packet), get_buffered_amount(), close()

func connect_to_server(url: String) -> void:
    if state == State.CONNECTING or state == State.CONNECTED:
        protocol_error.emit("Connection already active")
        return
    endpoint_url = url
    _set_state(State.CONNECTING)
    transport = _make_transport()
    transport.opened.connect(_on_transport_opened)
    transport.packet_received.connect(_on_transport_packet)
    transport.closed.connect(_on_transport_closed)
    transport.failed.connect(_on_transport_failed)
    transport.connect_to_url(url)

func _process(_delta: float) -> void:
    if transport != null:
        transport.poll()

func send_message(message: Dictionary) -> bool:
    if state != State.CONNECTED:
        protocol_error.emit("Cannot send while not connected")
        return false
    # Encode through the protocol layer before touching transport.
    var packet: PackedByteArray = _encode_message(message)
    if transport.get_buffered_amount() > _max_buffered_amount():
        protocol_error.emit("Transport backpressure")
        return false
    return transport.send_packet(packet)

func close() -> void:
    if state == State.DISCONNECTED or state == State.CLOSED:
        return
    _set_state(State.CLOSING)
    if transport != null:
        transport.close()

func _on_transport_opened() -> void:
    _set_state(State.CONNECTED)
    connected.emit()

func _on_transport_closed(code: int, reason: String) -> void:
    transport = null
    _set_state(State.CLOSED)
    disconnected.emit(code, reason)

func _on_transport_failed(error: String) -> void:
    transport = null
    _set_state(State.FAILED)
    protocol_error.emit(error)

func _set_state(next_state: int) -> void:
    state = next_state
```

## Design Notes

- Keep Godot-facing signals and `SignalFishClient` names stable once runtime
  code exists.
- Keep protocol encoding separate from WebSocket lifecycle.
- Prefer explicit failure signals over hidden retries.
- Confirm final naming against upstream Rust client behavior before shipping.
- Treat `DISCONNECTED` as an idle/no-transport state, `CLOSED` as an observed
  transport close, and `FAILED` as a client-side abstraction.
- Keep version-specific `WebSocketPeer` or `WebSocketClient` details inside the
  transport adapter.
- Translate syntax deliberately for Godot 3 examples; this sketch uses Godot 4
  naming such as `PackedByteArray`.

