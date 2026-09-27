---
description: Why Signal Fish wire and event boundaries retain dynamic GDScript values on Godot 4.3.
triggers: typing, type safe, variant, array, dictionary, wire, event, godot 4.3
category: Research
---

# GDScript Typing Boundaries

Godot 4.3 supports typed arrays. Nested typed arrays are unsupported, and
`Array[Variant]` is the same as `Array`. Typed dictionaries arrived in Godot
4.4, above this addon's 4.3 floor. Typed arrays also retain their element
type at runtime: assigning a raw parsed array to `Array[T]` can fail before
its elements are validated. Sources: [Godot 4.3 GDScript reference][gdscript-43]
and [Godot 4.4 typed dictionaries][dict-44].

[gdscript-43]: https://docs.godotengine.org/en/4.3/tutorials/scripting/gdscript/gdscript_basics.html
[dict-44]: https://godotengine.org/article/dev-snapshot-godot-4-4-dev-2/

## Required dynamic values

| Boundary                                                                    | Reason                                                                                                                                                    |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sf_envelope`, `sf_events`, `sf_types`, `sf_session_types`, `sf_json_guard` | JSON objects and arrays enter as raw `Dictionary`, `Array`, or `Variant`. Validators inspect wrong-typed members before constructors make typed models.   |
| `sf_msgpack`, `sf_binary_codec`, `sf_binary_frames`                         | Binary decoders accept arbitrary wire values or engine result tuples. MessagePack arrays may contain several value types.                                 |
| `sf_types.DecodedEvent.args` and `sf_events._event`                         | One event carries a different argument tuple from another. The client emits separate typed signals after decoding.                                        |
| `signal_fish_client`, `sf_messages`, `sf_type_utils`                        | Game data and signaling payloads are caller-defined JSON values; optional wire fields also use `null`. Roster round trips preserve malformed raw entries. |
| `sf_webrtc_mesh`, `sf_game_data_format`                                     | Engine/browser interfaces and mixed format diagnostics cross dynamic boundaries.                                                                          |

Keep fixed collections typed after conversion. Do not narrow raw inputs before
validation or replace heterogeneous public event arguments with a single
element type. If the engine floor rises above 4.3, recheck typed dictionaries
separately; they cannot be used in this matrix today.

Many client, protocol, and transport test captures with one known element type
were typed in sessions 084-086. Mixed test tuples and malformed input fixtures
stay dynamic so they continue to exercise invalid values.
