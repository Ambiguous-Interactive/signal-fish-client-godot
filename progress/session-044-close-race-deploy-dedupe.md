# Session 044 — Handshake-race close, deploy dedupe, warm local loop

Date: 2026-09-24 · Branch: `session-044-close-race-deploy-dedupe` · Base:
`origin/main` @ `a0f7dba`

## Drift check

Local `main` mirrored `origin/main`; no open PRs; all CI green. Two open
issues (#119, #123 remainder). PLAN.md's remaining items are human-gated
(Asset Library submission) or gated behind separate decisions (Godot 3.6,
Rkyv), so the session targeted issue debt plus iteration speed.

An adversarial sweep over the addon (sub-agent, then hand-verification) filed
four issues; two were fixed this session (#126, #129), two are filed with fix
directions (#127 mesh relay retry, #128 heartbeat vs backpressure — both need
an upstream-behavior check against the Rust client first).

## #119 — close() during the unobserved-open window

A consumer close after the engine handshake completed but before a poll
observed `STATE_OPEN` used to emit `opened` and terminalize as `closed` —
so `connection_failed`+FAILED vs `disconnected`+CLOSED raced engine timing
the caller cannot see. The transport now treats every close before `opened`
was observed as the documented failed open: session failure, close frame
queued, `opened` suppressed. Red-greened with a `STATE_OPEN`-but-unpolled
fake peer; client tests already pinned the fixed contract via the fake
transport's pre-open close semantics.

## #123 — Docs deploy consumes the validated build

Docs-validation's accessibility job (which already builds the site) uploads
`site/` as a 1-day `docs-site` artifact on main pushes and absorbs the
`llms.txt` check. Docs-deploy now triggers on `workflow_run` (validation
success + `head_branch == main`) and publishes that artifact; the push-to-main
critical path loses the third pip-install + mkdocs build (~20-25 s). A
`workflow_dispatch` recovery path builds from source as before. Deploy now
only publishes a validation-green build. Known one-run race (a pre-merge
validation completing without an artifact fails the download loudly, then
self-heals) is commented in the workflow.

## #126 — CLOSING window bounded

A close handshake on a silently dead link never completes: polling surfaces
nothing, the heartbeat disarms on non-CONNECTED, and every recovery entry
refuses ERR_BUSY while CLOSING — the same strand class as #121. While
CLOSING, silence past `pong_timeout_sec` now resolves through the failure
path (`heartbeat close timeout` -> `connection_failed`); auto-reconnect
stays suppressed by the user-close flag. `close()` resets the heartbeat
clock so the deadline starts clean. Red-greened via a `hold_close` fake
transport knob; a completing close still ends `disconnected`+CLOSED.

## #129 — Truncated replay keeps the newest events

`replay: truncated` means `missed_events` is the most-recent suffix, but the
>256-entry decode cap kept the OLDEST 256 and dropped the tail closest to
now. The decode keeps the last `MAX_MISSED_EVENTS` entries; the sentinel's
dropped count is unchanged; per-entry diagnostics now report wire indices.
New data-driven case (260 entries -> gen-4..gen-259 survive, sentinel says
"dropped 4"); red-greened.

## Local iteration speed

`run-runtime-checks.sh` godot workers now extract a tree archive built once
per invocation (one workspace traversal instead of seven) and clone a warm
`.godot` import-cache snapshot, so each boot skips the cold reimport
(~1.3 s -> ~0.3-0.5 s per suite on a normal filesystem). Measured on the
12-core devcontainer (workspace on a Windows bind mount, which caps the
snapshot read): production-edit `changed` 3.2-4.1 s -> 2.8 s; test-edit
`changed` ~3.4 s -> 2.0 s; suite boot floor 1.3 s -> 0.5 s; `all` ~5 s ->
~4.7 s (static checks dominate). `SF_COLD=1` still forces CI-identical cold
imports; CI checkouts have no `.godot`, so CI is unchanged. Prep failures
discard partial artifacts and fall back to per-worker copies (sabotage-
verified: truncated archive discarded, suites still pass). The redundant
user-site python probe is skipped on the venv path.

## Checks

- `run-runtime-checks.sh all` green (exit 0); opt-in `smoke` green.
- Red-green: #119 (3 failures), #126 (3 failures), #129 (2 failures).
- Sabotage test: failed archive prep falls back cleanly (exit 0, warning).
- `validate-github-config.py` self-test + repo check green; markdownlint
  repo-wide green; `agent-check.ps1` green after .llm edits.

## Deferred

- #127 (mesh relay retry) and #128 (heartbeat vs backpressure): filed with
  fix directions; both want the Rust client's behavior verified first.
- Static-check wall (~4.6 s) now dominates `all`; adaptive sharding measured
  as a regression on this box (interpreter startup on the bind mount) and
  was rejected — recorded here so it is not re-tried blind.
