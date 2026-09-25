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
Accepted values are `""` (JSON), `json`, and `message_pack`.

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

| Signal | Payload |
| --- | --- |
| `game_data_received(from_player, data)` | Decoded JSON, or decoded MessagePack with opt-in decode on. |
| `game_data_binary_received(from_player, encoding, payload)` | Envelope payload bytes plus the `encoding` enum (`SFTypes.GameDataEncoding`). |

## MessagePack decode

MessagePack payload decoding is opt-in through
`config.decode_msgpack_payloads` (default `false`):

- Default: `game_data_binary_received` exposes the payload bytes as
  `PackedByteArray` with the `encoding` enum. No transcoding happens.
- Opt-in: decoded values surface through `game_data_received`.
- An undecodable payload falls back to the bytes path and adds a
  `protocol_error` diagnostic.

## Rkyv

The server reserves `rkyv` as an internal format and never negotiates it,
so `game_data_format = "rkyv"` is refused at `configure()` (issue #146):
requesting it would downgrade to JSON and every binary send would fail.

For raw bytes, use `message_pack` with `decode_msgpack_payloads = false`
(see [Raw-byte pass-through](#raw-byte-pass-through)). A v3 frame whose
envelope `encoding` token is `rkyv` still decodes — the token remains a
reserved wire encoding, and its payload surfaces as bytes.

## Strict binary-frame decode

`sf_binary_frames.gd` decodes binary game-data frames strictly, pinned to
the server's `websocket/sending.rs`:

- Map keys must be strings.
- Duplicate and unknown fields are rejected.
- No trailing bytes are allowed.

A malformed frame emits `protocol_error` and keeps the connection alive.
