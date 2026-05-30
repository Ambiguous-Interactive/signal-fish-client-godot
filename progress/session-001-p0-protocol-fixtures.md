# Session 001 - P0 Protocol Fixtures

Date: 2026-05-29

## Scope

Implemented the first two P0 plan items:

- Created `.llm/research/protocol-fixtures.md` with pinned upstream commits,
  source paths, fixture policy, and open verification items.
- Vendored complete protocol fixture files under `tests/fixtures/` covering
  all 11 client messages, all 24 server messages, and malformed decoder inputs.

## Upstream Pins

- `signal-fish-server`: `4f766b7856bead1e1cc07d4e7a1057831a045749`
- `signal-fish-client-rust`: `da4c0bdf0657370ec340321363f3b5850e06b0b0`
- `signal-fish-cloud`: `ffdd5105d9e844aefd54ec4a3cd832231dd428cd`

## Plan Maintenance

Updated `PLAN.md` to mark completed P0 fixture items and removed stale binary
payload assumptions. Current upstream source uses WebSocket binary frames for
negotiated MessagePack/Rkyv game data, with JSON fallback as `GameData`; the
plan no longer describes `GameDataBinary` as only base64 inside text frames.

## Validation

Completed validation:

- JSONL fixture parse counts: 11 client fixture lines, 24 server fixture
  lines, and 8 malformed fixture lines.
- `pwsh -NoProfile -File scripts/agent-check.ps1` passed.

## Follow-Ups

- Implement P0 protocol codec files and fixture readers that skip `#` comments.
- Keep `GameDataBinary.payload` decoding tolerant of both byte arrays and
  base64 strings until upstream documentation drift is resolved with a captured
  live frame or Rust-generated fixture.
- Decide the Godot canonical form for unset `JoinRoom` optional fields. Rust
  serde emits `null`; docs omit the fields; the current fixture avoids that
  dispute by populating every optional field.
- Decide the Godot default for omitted `supports_authority`. Current server
  source defaults it to `true`; docs imply omitted or false disables authority.
- Decide whether cloud-only `DATABASE_ERROR` should be a named error-code alias
  or map to `UNKNOWN`.
- Auto-reconnect remains blocked on pinning where reconnect tokens are issued
  and surfaced to clients.
