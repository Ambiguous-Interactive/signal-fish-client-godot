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
  envelopes (below noise), _slower_ on v3 and **13% slower** on MessagePack
  decode. The engine's typed stream getters beat hand-rolled value indexing;
  interpreted statement count, not allocations, dominates. Also required
  manual big-endian assembly -- `PackedByteArray.decode_u16/u32/u64` are
  little-endian and MessagePack is big-endian (a silent-corruption trap for
  any future attempt; floats additionally have no big-endian decode at all).
- **`StreamPeerBuffer` + `get_data()` wrapper arrays** (one `[Error, bytes]`
  Array per binary field): covered by the cursor experiment; keeping the
  stream is the faster shape.
- **Guard object-dense shape / key-set pooling** -- session-061 (round 3)
  measured pooling and pre-sizing neutral; the interpreted per-byte scan is
  the floor. A native first-of-set byte scan would change this; Godot 4.3
  does not expose one to scripts.
- **Text-path double UTF-8 conversion** (`payload.get_string_from_utf8()` in
  the client, then the guard's `to_utf8_buffer()`): 0.6 us for a control
  frame -- noise; keeping the String-based public API.
- **UUID cache-miss formatting** (~3.9 us/miss): rare (one per new sender)
  and bounded (clear-on-full).
- **MessagePack array reservation** (`Array.resize(count)` and indexed
  writes): adjacent Godot 4.3 bench runs moved 256 values from 176.6 to
  171.7 us and 4096 values from 2800 to 2687 us. Both changes are below
  the 12-15% measurement floor, so the append loop stays.

## Shipped: unescaped JSON key fast path

`SFJsonGuard._collect_key` used a GDScript append loop even for ordinary
keys with no backslash. A native byte slice plus native backslash check now
returns those keys directly; escaped keys keep the canonicalizing loop.
Adjacent best-of-five Godot 4.3 runs moved the clean control frame's guard
from 31.3 to 24.1 us. The whole text decode moved from roughly 87 to 77 us
in the full bench. A cap-bound frame of escaped keys moved from 37.9 to 39.6
ms, inside the measurement floor. Duplicate-key, escape, and NUL vectors
remain in the protocol suite.

## Shipped: float wire-text memo

`SFEnvelope._stringify_float` proves each float round-trip-exact by JSON
parse-back, which dominated float-heavy encode (96 us for the 16-float
bench envelope uncached vs 71 us warm). It is a pure value-to-text function,
so verified texts are memoized under the float (256-entry, clear-on-full,
zeros bypass because float keys cannot distinguish -0.0 from 0.0).
`encode_floats_cold` keeps the uncached cost measured. Wire bytes are
identical to the uncached path; pinned by byte-identity, eviction-survival,
and negative-zero wire tests.

## Round 6: algorithmic-complexity sweep (2026-09-30)

Owner ask (2026-09-28): prove hostile inputs cannot drive any decoder
super-linear. Method: doubling-size probes on Godot 4.3 headless; a 4x
input growth costing ~4x time is linear, a constant cost is O(1).

Time verdicts (all surfaces linear or constant):

- JSON guard byte scan: brace flood, object+key flood, and
  backslash-quote adversarial strings all cost ~4x per 4x of input
  (~0.5 us/input byte). The per-byte interpreted scan stays the floor.
- MessagePack: hostile nesting fast-fails at the depth cap (0.02 ms at
  any declared depth to 1M); a declared huge count with a truncated
  stream refuses in ~5 us, independent of the declared count.
- Binary payload byte-array path: 3.2-3.9x per 4x input (linear).
- UUID gate: constant per call; a 1 MiB hostile string costs 0.3 us
  behind the length check (36-char scan only for well-shaped text).

Space verdict, fixed: `SFJsonGuard.duplicate_key_error` allocated a
key-set Dictionary per opened container, so a 256 KiB `{` flood peaked
near 33 MB (~128x the frame) and ~117 ms before any refusal. The
tracked-depth cap (`_MAX_TRACKED_DEPTH`, 1024) bounds the bookkeeping;
every decoded payload position nests at most MAX_MESSAGE_DEPTH (16)
levels, so the cap only relocates where an already-refused frame fails
closed, independent of engine version. The engine JSON parser refuses
deep documents near the same depth anyway (arrays accepted to 1025,
objects to 1024 on 4.3). Post-fix: the flood refuses in 0.8 ms with
sub-MB peak and a
"nesting exceeds depth 1024" diagnostic; the object+key flood drops
137 ms to 2.5 ms (probe frames ~1.5 MB, above the 256 KiB inbound frame
cap; both shapes are linear so the verdict is unchanged). Clean-frame
guard cost unchanged (31.4 -> 29.2 us, inside noise). Pinned by the
duplicate-key depth-cap vectors, including a duplicate at the boundary
level and a clean frame one level past the cap. The remaining per-frame
latency floor is the interpreted byte scan (~0.5 us per input byte),
linear and inside the round's bar.

Session-state surfaces (roster/spectator upserts, mesh reconciliation)
are O(session size) per event through linear scans, bounded by
`SFTypeUtils.MAX_TRACKED_PEERS` = 256 (issue #274): roster baselines and
plan/new-peer reconciliation clamp to the cap with one diagnostic per
refused event, and the secret-redaction list evicts its oldest rotating
token past `MAX_REMEMBERED_SECRETS` (pinned credential and passwords
never age out), so hostile input can no longer grow client session
state. Decode inputs stay the only peer/hostile-input amplification
surface.

Follow-up verdicts recorded for later rounds: `SFMsgpack` map decode
silently last-wins duplicate keys (`_read_counted_map`), while the text
path (issue #92) and the binary envelope decoder refuse them - a
fail-closed parity gap on the opt-in payload path; linear in time and
space, so outside round 6's bar (closed by round 7 below).

## Round 7: MessagePack duplicate-key verdict (2026-09-30, issue #273)

Decision: refuse duplicate keys in decoded maps (fail closed), not
last-wins upstream parity. The client's JSON path already refuses
duplicates even though `serde_json` last-wins, so the divergence is the
established local contract: no hostile frame may silently substitute a
payload value. Cost stays linear - one extra hash probe per map entry on
the opt-in decode path - and refusal degrades exactly like every other
payload decode failure (`protocol_error` plus raw bytes via
`game_data_binary_received`). Pinned by one-level, nested-level, and
capped-diagnostic vectors in the hostile matrix
(`tests/protocol/binary_frame_tests.gd`); the refusal is per map, so the
same key in sibling or nested maps still decodes.

## Engine facts worth remembering

- `StreamPeerBuffer.get_data(n)` returns an `[Error, PackedByteArray]` Array
  on 4.3 (allocation per call).
- `PackedByteArray.decode_u16/u32/u64/float/double` are little-endian.
- The engine JSON parser has a hard nesting limit that depends on the
  container kind: arrays accepted to depth 1025, objects to 1024,
  refused one level past each ("JSON structure is too deep"; measured
  on Godot 4.3). Deep hostile JSON therefore fails closed at the
  engine; the text guard's 1024 tracked-depth cap sits just under the
  array boundary (issue #161).
- A true runtime `-0.0` reliably formats `"-0"` and `+0.0` formats `"0"`;
  both round-trip (`"-0.0"`/`"0.0"` after normalization). Subnormals and the
  min normal format as `"0"` through both engine formatters, so those floats
  refuse at JSON-envelope encode by design (the MessagePack codec handles
  them bit-exactly).
- GDScript folds subnormal decimal literals (`5e-324`) to `+0.0` at parse
  time, and `+/-0.0` literal folding is per-script and unreliable -- build
  extreme doubles from bit patterns at runtime
  (`fuzz_decode_tests.gd::_double_from_bits`).
