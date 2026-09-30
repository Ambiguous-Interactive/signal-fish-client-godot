# Session 158: Bound wire values echoed in binary decode errors (issue #289)

Branch: `session-158-binary-decode-echo-bounds` from `origin/main` at `1d0a94d`.

## Why

- #289 (residual of the session 157 adversarial sweep): both
  `_decode_byte_array` errors in `sf_binary_codec.gd` embedded
  `var_to_str(value)` of a wire-derived payload entry raw. Godot's
  `var_to_str` escapes quotes but leaves control characters raw, so a
  hostile `GameDataBinary` payload could put up to the inbound frame cap
  of text into one diagnostic line and forge log lines with embedded
  newlines. The error reaches the `protocol_error` signal and the client
  log through `sf_events.gd`, violating the diagnostic contract
  (issues #279/#282).

## Changes

- `sf_binary_codec.gd`: both byte-array decode errors render the echoed
  value through `SFDiagnostics.render_key(var_to_str(value))`: 32-char
  cap before escaping plus control-character escaping, so the token is
  bounded and single-line. Neighbor check: `_decode_base64` and
  `_normalize_base64` errors are code-owned text only.
- `tests/protocol/fuzz_decode_tests.gd`: new
  `_test_binary_codec_decode_echo_bounded` pins the readable echo for
  legit values (doubled-quoted `"1"`, quoted `0.5` - tokens that only
  exist post-fix) and the hostile bound: a 60 KB newline-laden string
  entry refuses with a single-line diagnostic under 200 chars, newlines
  rendered as `\x0A`.
- `tests/protocol/protocol_hardening_tests.gd`: the same hostile payload
  rides the full `decode_envelope` path into `protocol_error`; the
  message stays single-line and bounded at the sink.

## Verification

- Red-green: the hostile vectors failed against the unbounded echo (the
  diagnostic carried 60,047 chars with raw newlines), then went green.
  The readable-echo pins were tightened after an adversarial review so
  they discriminate old vs new behavior (`""1""` / `"0.5"` quoting).
- Adversarial probe of both error branches: the non-number branch can
  carry any Variant and stays bounded single-line; the outside-0..255
  branch only sees INT/FLOAT (`var_to_str` under 21 chars, no control
  characters), so its render_key wrap is defense in depth. Worst-case
  rendered error stays under the 200-char pin for any physically
  realizable frame.
- Neighbor sweep over `addons/**`: no remaining wire-derived text reaches
  diagnostics unbounded (`render_key`/`bound_item` cover events, frames,
  json guard, msgpack, and game data; the one raw `%s` interpolation is
  provably code-owned).
- `python3 -E scripts/run-runtime-checks.py all` green; `changed` loop
  green; gdformat/gdlint/private-helper/warning-pin checks clean.
