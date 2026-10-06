---
description: "JSON and binary game data: send, receive, MessagePack decode, raw-byte pass-through, and strict frame rules."
---

# Game Data

Game data is your application payload. The protocol is open-ended: the
client never inspects or wraps it.

## JSON game data

`send_game_data(data)` sends your payload as the JSON `GameData`
message:

```gdscript
client.send_game_data({"action": "move", "x": 30, "y": 40})
```

Receive it on `game_data_received(from_player, data)`.

### Outbound payload rules

The client serializes your payload to JSON exactly as given: floats are
written with full round-trip precision, and JSON `null` passes through
verbatim. Values that cannot be represented losslessly are refused with
`protocol_error` (and nothing is sent) rather than corrupted:

- Engine-only Variants (`Vector2`, `Color`, objects, ...) - including
  the Godot conveniences `StringName` and `Packed*Array` values.
  Convert them to plain JSON data at the call site.
- Non-finite floats (`nan`, `inf`) - no JSON parser accepts them.
- Floats the engine's own JSON formatters cannot round-trip (observed
  only for very small magnitudes, which come back re-rounded or
  flattened rather than preserved).

A payload nested more than 14 levels deep is also refused, mirroring
the inbound decode bound measured from the message envelope.

## Binary game data

The `game_data_format` config field negotiates the format with the server.
Accepted values are `""` (JSON), `json`, `message_pack`, and the opaque
`rkyv`/`protobuf` pass-through encodings.

`send_game_data_binary(bytes)` sends one raw binary frame:

```gdscript
client.send_game_data_binary(payload_bytes)
```

- There is no per-send `encoding` parameter. The server tags inbound binary
  with the negotiated format.
- On a `json`-negotiated connection the client refuses the send locally
  with `ERR_UNAVAILABLE`. The server drops binary frames on JSON
  connections anyway.

## Raw-byte pass-through

For opaque bytes your game already encodes, keep the default decode off
(`decode_msgpack_payloads = false`) and use `message_pack`: the payload
crosses the envelope untouched and the frame still carries `from_player`,
so the recipient gets the exact bytes plus a sender identity.

## Receiving

Two signals cover inbound game data:

| Signal                                                      | Payload                                                                       |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `game_data_received(from_player, data)`                     | Decoded JSON, or decoded MessagePack with opt-in decode on.                   |
| `game_data_binary_received(from_player, encoding, payload)` | Envelope payload bytes plus the `encoding` enum (`SFTypes.GameDataEncoding`). |

## MessagePack decode

MessagePack payload decoding is opt-in through
`config.decode_msgpack_payloads` (default `false`):

- Default: `game_data_binary_received` exposes the payload bytes as
  `PackedByteArray` with the `encoding` enum. No transcoding happens.
- Opt-in: decoded values surface through `game_data_received`.
- An undecodable payload falls back to the bytes path and adds a
  `protocol_error` diagnostic.
- Duplicate map keys in a decoded payload are rejected with
  `protocol_error` (raw bytes still surface).

## Opaque encodings (rkyv, protobuf)

`rkyv` and `protobuf` are opaque pass-through encodings: the server relays
their payloads as raw bytes and never decodes them. Deployments negotiate
them only with the opt-in `enable_rkyv_game_data` /
`enable_protobuf_game_data` knobs on (server issue #627).

Request one with `game_data_format = "rkyv"` or `"protobuf"`:

- Binary sends carry your encoded bytes; received frames surface through
  `game_data_binary_received` with the frame's `encoding` label.
- The opaque wire shapes are v3-only (a v2 negotiation has no sender
  attribution). The client falls back to JSON - logged at WARN - when the
  server does not advertise the requested format or negotiates v2.
- The server cannot convert between formats: delivering opaque bytes to a
  recipient on another format reports `unsupported_format` upstream, so
  every peer needs the same negotiated encoding.

For raw bytes without a deployment knob, use `message_pack` with
`decode_msgpack_payloads = false` (see
[Raw-byte pass-through](#raw-byte-pass-through)). A v3 frame whose envelope
`encoding` token is an opaque format still decodes - the payload surfaces
as bytes with the sender identity attached.

## Strict binary-frame decode

`sf_binary_frames.gd` decodes binary game-data frames strictly, pinned to
the server's `websocket/sending.rs`:

- Map keys must be strings.
- Duplicate and unknown fields are rejected.
- No trailing bytes are allowed.

A malformed frame emits `protocol_error` and keeps the connection alive.
