# Session 005 - PR #6 Review Fixes + Decode Depth Hardening

Date: 2026-09-19

## Scope

- Merge latest `origin/main` into the open transport-seam PR (#6) and drive it
  toward green: address bot review findings, fix the highest-impact open issue
  (#11), and reserve the P1 credential API slot (#14).
- Carry forward the previous session's uncommitted devcontainer hardening
  (dangling npm bin links, root-owned `~/.cache`) into this PR.

## Review findings addressed (PR #6)

- `SFWebSocketTransport.close()` during `CONNECTING` now surfaces the caller's
  close code/reason in both the `failed` message and the `peer.close()` call,
  matching `SFFakeTransport` ("closing while connecting is a failed open").
- `SFFakeTransport.connect_to_url()` now clears `sent_text`/`sent_binary` so
  each session's outbound history is deterministic.
- Rejected with rationale:
  - Copilot's "type `_peer` with the `class_name`": global `class_name`
    references are cold-cache-fragile (parse fails under `--script` cold
    runs; `check-gdscript-private-helpers.py` guards this class of issue).
    The preloaded-script typing is deliberate; comment added in source.
  - "Poll through close in reset/fail paths": those sessions are deliberately
    discarded (terminal); the peer is closed before release per
    `.llm/skills/godot-transport.md`, and nothing observable is lost.
  - "Model STATE_CLOSING in the fake": the fake's synchronous `inject_*` API
    is the documented determinism contract (PLAN section 4.5); lifecycle
    *semantics* (terminal guards, failed-open classification) are aligned.

## Issue #11 (fixed): bounded `missed_events` decode

- `SFEvents.MAX_MESSAGE_DEPTH = 16` caps envelope recursion;
  `Reconnected` entries inside `missed_events` are rejected as non-replayable
  (mirrors the Rust client), so a hostile server can no longer drive GDScript
  recursion to a script-stack abort.
- Tests: nested-Reconnected rejection + depth-cap enforcement in
  `protocol_hardening_tests.gd`; `missed_events` non-array line in
  `malformed.jsonl`.
- Noted while testing: `DecodedEvent.raw` deep-duplicates its envelope; the
  engine's C++ duplicate is itself recursion-capped, so hostile depth stays
  bounded even before the type rejection was added.

## Devcontainer carry-forward

- Per-package npm installs + dangling bin-link sweep (a failed postinstall no
  longer rolls back the whole CLI toolchain or poisons PATH).
- `post-create.sh` repairs a root-owned `~/.cache` (volume-mount parents are
  created as root; this crashed opencode's postinstall and VS Code's agent
  host with EACCES).
- Restored `CHATGPT.md`/`CODEX.md`/`GEMINI.md`: the harness linter
  hard-requires these pointer files (deleting them reds the lint).

## Follow-up round: Bugbot "failing CLIs marked ready" (new bot review)

- Bugbot correctly flagged that the new verifier treated any non-empty
  merged `--version` output as a version - a CLI dying on startup printed an
  error line and was marked ready (the exact failure mode the diagnostics
  were added for).
- Sweep for the class across `.devcontainer/*.sh` + `scripts/*.sh`: all other
  merged-stream uses are exit-code-gated (`if ! cmd`) or display-only; this
  was the one instance.
- Fix: verdict on exit status with stdout/stderr redirected to separate
  files - nonzero exit = broken (first error line reported as diagnostic),
  exit 0 with no output = missing, exit 0 with output = ready (stderr
  consulted when stdout is empty, since some CLIs print versions there).
  Verified all four paths with stub binaries; harness self-tests extended to
  reject the merged-stream pattern (red first), 113/113 green.
- Guidance: `.llm/skills/devcontainer-tooling.md` documents the exit-status
  verification contract; `.llm/skills/review-debugging.md` gains a
  "Health-Check Hygiene" section (non-empty output is not a success signal;
  sweep every `$(cmd 2>&1)` whose content gates success).

## Verification

- `bash scripts/run-runtime-checks.sh all`: green (private-helpers, format,
  lint, cold-copy protocol + transport Godot tests).
- `pwsh -NoProfile -File scripts/agent-check.ps1`: green.
