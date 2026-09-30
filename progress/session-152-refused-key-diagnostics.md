# Session 152: Cap and escape hostile keys in refusal diagnostics (issue #279)

Branch: `session-152-refused-key-diagnostics` from `origin/main` at
`c27432e`.

## Why

- #279: refusal diagnostics embedded hostile wire keys uncapped and
  unescaped. The binary envelope decoder (always on for MessagePack
  game data) embedded the full key in duplicate-field and unknown-field
  errors, and the JSON guard and MessagePack renderers passed control
  characters through, so a crafted key could forge or flood log lines
  and the `protocol_error` signal.

## Changes

- New `sf_diagnostics.gd`: one shared `render_key` caps a rendered key
  at 32 characters and escapes C0 controls plus DEL as `\xNN`, so the
  rendered token stays one log line.
- `sf_binary_frames.gd`: duplicate-field, unknown-field, and encoding
  token errors render the key through the shared helper.
- `sf_json_guard.gd` and `sf_msgpack.gd`: their private renderers fold
  into the shared helper. The JSON guard now caps characters (was
  bytes); multibyte keys render up to 32 whole characters.
- `tests/protocol/binary_frame_tests.gd`: the envelope hostile matrix
  gains capped and escaped key vectors (duplicate, unknown, encoding
  token) and pins the named known-field errors. The MessagePack hostile
  vectors gain a newline-key escape pin. Both loops accept
  `error_not_contains`, so each surface also pins that the raw hostile
  form is absent.
- `tests/protocol/duplicate_key_tests.gd`: JSON guard vectors pin the
  32-character cap on a multibyte key and the newline escape.

## Verification

- Red-green: reverting the three decoders to `origin/main` turns 15
  assertions red across all three surfaces; with the fix, the full
  local gate is green (`python3 -E scripts/run-runtime-checks.py all`).
