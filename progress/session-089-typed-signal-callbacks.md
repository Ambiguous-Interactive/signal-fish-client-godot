# Session 089: type client signal callbacks

Branch: `codex/session-089-typed-signal-callbacks` from `origin/main` at
`dd1c59a`.

- Typed the fixed roster, spectator, and replay arrays in client test callbacks.
- Kept raw wire arrays and mixed event tuples dynamic for invalid-input tests.
- The full runtime gate passes across all seven local Godot suites.

#165 stays open for the remaining type-boundary audit.
PR #203 is the session deliverable.
