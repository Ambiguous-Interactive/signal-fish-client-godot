---
description: Measured verdicts for issue #161 hot-path audit ideas (allocations, value-typed cursor decoders, float wire-text memo) so no session repeats them without new engine capabilities.
triggers: performance, allocation, hot path, cursor, StreamPeerBuffer, decode_u, float, memo, benchmark, decode_bench, messagepack, json guard
category: Research
---

# Hot-Path Audit Verdicts (issue #161)

Paranoid-audit measurements on Godot 4.3 headless (best-of-runs,
`tests/protocol/decode_bench.gd`). Re-run before trusting any number below:
cross-run absolutes swing more than the within-run 12-15% noise floor
(container CPU state); within one bench invocation the ratios held.

## Closed with data (do not re-try without a new engine capability)

- **Value-indexed cursor decoders** (drop `StreamPeerBuffer`, walk a
  `PackedByteArray` with an int cursor + `decode_*`): -3.5% on binary v2
  envelopes (below noise), *slower* on v3 and **13% slower** on MessagePack
  decode. The engine's typed stream getters beat hand-rolled value indexing;
  interpreted statement count, not allocations, dominates. Also required
  manual big-endian assembly — `PackedByteArray.decode_u16/u32/u64` are
  little-endian and MessagePack is big-endian (a silent-corruption trap for
  any future attempt; floats additionally have no big-endian decode at all).
- **`StreamPeerBuffer` + `get_data()` wrapper arrays** (one `[Error, bytes]`
  Array per binary field): covered by the cursor experiment; keeping the
  stream is the faster shape.
- **Guard object-dense shape / key-set pooling** — session-061 (round 3)
  measured pooling and pre-sizing neutral; the interpreted per-byte scan is
  the floor. A native first-of-set byte scan would change this; Godot 4.3
  does not expose one to scripts.
- **Text-path double UTF-8 conversion** (`payload.get_string_from_utf8()` in
  the client, then the guard's `to_utf8_buffer()`): 0.6 us for a control
  frame — noise; keeping the String-based public API.
- **UUID cache-miss formatting** (~3.9 us/miss): rare (one per new sender)
  and bounded (clear-on-full).

## Shipped: float wire-text memo

`SFEnvelope._stringify_float` proves each float round-trip-exact by JSON
parse-back, which dominated float-heavy encode (~31 us per 16-float
envelope). It is a pure value→text function, so verified texts are memoized
under the float (256-entry, clear-on-full, zeros bypass because float keys
cannot distinguish -0.0 from 0.0). Steady state 71 us vs 96 us uncached
(same run, same shape; `encode_floats_cold` keeps the uncached cost
measured). Wire bytes are identical to the uncached path; pinned by
byte-identity, eviction-survival, and negative-zero wire tests.

## Engine facts worth remembering

- `StreamPeerBuffer.get_data(n)` returns an `[Error, PackedByteArray]` Array
  on 4.3 (allocation per call).
- `PackedByteArray.decode_u16/u32/u64/float/double` are little-endian.
- `String.num(±0.0, 17)` returns `"-0"`/`"0"` inconsistently (both
  round-trip; `-0.0` reliably formats `"-0"`); subnormals and the min normal
  format as `"0"`, so floats that tiny refuse at encode by design.
- GDScript folds subnormal literals (`5e-324`) to `0.0` in const context —
  build extreme doubles from bit patterns at runtime
  (`fuzz_decode_tests.gd::_double_from_bits`).
