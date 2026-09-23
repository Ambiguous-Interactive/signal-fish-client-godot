# Session 039 — PLAN.md audit + lean-plan policy

Date: 2026-09-23. Scope: one focused surface — PLAN.md bloat. Data first:
`git log --follow` shows PLAN.md grew 689 → 1019 lines over 30 commits with
zero shrinking commits; the 67-line status block duplicated
`progress/session-03*.md` (issues #82–#99 all already recorded there); §10
duplicated `.llm/skills/asset-library-release.md` nearly verbatim; §4/§6/§7
were stale shadows of `runtime-architecture.md`,
`adversarial-verification.md`, and `agent-harness.md`/`testing-automation.md`.
GOAL.md already said "remove completed items after each session" and was
ignored every session — a one-line rule is insufficient; the fix is a
structural routing policy. External practice (context-rot / planning-with-files
writeups) agrees: plan = going-forward only, durable knowledge = reference
files, history = append-only log; merging the three causes rot.

## Change: destinations first, then delete (no knowledge loss)

Mapping applied (PLAN section → home):

- §2 locked decisions → `.llm/context.md` "Locked Decisions".
- §3 confirmed facts (incl. resolved §13 items 3/9 upstream pins) →
  `.llm/skills/signal-fish-protocol.md` "Confirmed Wire Facts".
- §4.3 data rulings, §4.6 duplicate-key guard, §4.7 heartbeat/cleanup →
  `.llm/skills/runtime-architecture.md` (new "Data representation" +
  "Reliability extras"; auto-reconnect stays in `reconnection-replay.md`).
- §6 consensus exit bar + anti-thrash → `.llm/skills/adversarial-verification.md`
  "Phase Exit Bar".
- §9 weekly-workflow pattern (export smoke, protocol-sync off the fast gate;
  SHA pinning) → `.llm/skills/testing-automation.md`.
- §12 repo security checklist → `.llm/skills/security-privacy.md`
  "Repo Checklist".
- §5 P0–P6 completed checklists, status block, §8 matrix, §11 risk register →
  already in `progress/` + the skills above; deleted (residual live risks are
  covered by security/web-export/release skills).
- Remaining work kept in PLAN: P6 bootstrap, 7 open upstream verifications,
  P7 items, v1 DoD. PLAN.md: 1019 → 58 lines.

## Policy (prevents recurrence)

- `.llm/context.md` Working Rules: PLAN.md is going-forward only; shipped
  items move to `progress/session-NNN-*.md` and leave PLAN the same session;
  durable rules go to `.llm/skills`; never append session summaries.
- `.llm/skills/architectural-planning.md` new "Plan File Hygiene" section:
  the three-file routing, the "would deleting this change anyone's next
  action?" test, and a ~100-line budget as the growth tripwire.
- GOAL.md progress-tracking line now points at the hygiene section instead
  of the unenforceable one-liner.

## Reference fixes

All `PLAN §N` cross-references updated: `reconnection-replay.md` (4),
`gdscript-client-shape.md` (1), `docs/releasing.md` (1 — curl fallback now
points at the asset-library skill). Repo-wide grep for `PLAN §` is clean.

## Verification

`agent-check.ps1` green after `.llm` edits; `generate-llm-index.ps1` clean;
markdownlint-cli2 green on all changed files; every `.llm` file ≤ 300 lines
(context.md 279, the rest ≤ 214); PLAN.md 58 lines. Red-team mapping review:
every removed PLAN section traced to a durable home (table above); the 7 open
upstream items match the pre-cleanup §13 open set minus the 3 resolved items
whose pins moved into `signal-fish-protocol.md`.
