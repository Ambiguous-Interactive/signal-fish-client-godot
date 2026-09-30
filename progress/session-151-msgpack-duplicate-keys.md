# Session 151: Refuse duplicate MessagePack map keys (issue #273)

Branch: `session-151-msgpack-duplicate-keys` from `origin/main` at
`c23a8ad`. Delivered as PR #278.

## Why

- #273 was filed by session 149 as a round-6 follow-up: the opt-in
  `SFMsgpack` map decode silently last-wins duplicate keys while the
  text path (issue #92) and the binary envelope decoder refuse them - a
  fail-closed parity gap. A hostile frame could quietly swap a decoded
  payload value.

## Changes

- `sf_msgpack.gd`: `_read_counted_map` refuses a repeated key with
  "MessagePack map contains duplicate key ..." naming the key, capped
  at 32 chars (`_MAX_REPORTED_KEY_CHARS`, mirroring
  `SFJsonGuard._MAX_REPORTED_KEY_BYTES`) so a hostile key cannot flood
  the log. The refusal is per map: the same key in nested or sibling
  maps still decodes. Class doc records the contract.
- `tests/protocol/binary_frame_tests.gd` hostile matrix: duplicate keys
  at one level, in a nested map, and under a map16 header (so the check
  cannot regress to the fixmap call site alone), plus the capped
  40-char-key diagnostic and legal-nesting pins (same key in nested and
  sibling maps).
- Docs: `docs/client.md` behavior bullet and `docs/game-data.md`
  MessagePack-decode refusal bullet.
- `.llm/research/hot-path-audit.md`: round 7 verdict (refuse, fail
  closed, linear cost, per-map scoping); the round 6 follow-up note is
  marked closed.

## Verification

- Red-green: reverting only the codec fix turns every duplicate-key
  vector red (old codec decodes last-wins, 11 failed assertions across
  the four refusal vectors); restoring it passes the full protocol
  suite.
- Full local gate green: `python3 -E scripts/run-runtime-checks.py all`
  plus the LLM harness check.

## Session state

- #273 is implemented; the issue can close with PR #278.
- #234 stays the planned milestone after the 2026-10-05 Dependabot
  pass; #275 (Prettier in the local gate) remains open.
