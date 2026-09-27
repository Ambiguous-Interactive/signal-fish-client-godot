# Session 090: type mesh relay retry state

Branch: `codex/session-090-typed-mesh-relay` from `origin/main` at
`0eaf328`.

- Replaced the mesh retry's optional `Variant` payload with a typed
  `Dictionary` and an explicit presence flag.
- Verified that a rate-limit error before any relay sends nothing.
- Recorded why the browser's dynamic JavaScript property read remains a
  `Variant` boundary on Godot 4.3.
- The full runtime gate and LLM harness pass locally.

#165 stays open for the remaining type-boundary audit.
PR #204 is the session deliverable.
