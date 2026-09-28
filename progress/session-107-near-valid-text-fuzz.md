# Session 107: test near-valid text events

Branch: `codex/session-107-near-valid-text-fuzz` from `origin/main` at
`7b04b2a`.

- Expanded issue #221's seeded corpus from pinned server fixtures for
  `RoomJoined`, `GameData`, and `Reconnected`.
- Covered every truncated prefix, seeded JSON syntax mutations, escaped
  duplicate keys, invalid fields, nested replay, and replay cap boundaries.
- Sent malformed frames through a fake transport. Checked protocol errors,
  live connection, room identity, session state, and the retained reconnect
  token. A valid `Pong` still arrives afterward.
- Ran the full runtime gate locally. No production bug was reproduced.

Issue #161 remains open for the broader decode audit. #168 remains open for
future automation work.
PR #222 is the session deliverable.
