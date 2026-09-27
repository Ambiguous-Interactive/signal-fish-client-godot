# Session 084: type protocol test events

Branch: `codex/session-084-typed-protocol-test-events` from `origin/main` at
`6ad60c4`.

- Typed decoded event collections and fixed-shape event payload arrays across
  protocol fixtures and replay tests. Assertions now read typed peer and
  roster entries.
- Kept malformed wire inputs generic so tests still cover invalid values.
- The changed-files gate passes the protocol and reconnect suites, format,
  lint, and static checks. Main CI was green at `6ad60c4` before the branch.

#165 remains open for the wider wire, event, and test boundary audit.
