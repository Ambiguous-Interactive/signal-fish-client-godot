# Session 046 - ASCII docs policy, docs CI wall, local docs loop

Date: 2026-09-24 - Branch: `session-046-docs-ascii-speed` - Base: `origin/main`
@ `b08eed0`

## Drift check

Local `main` mirrored `origin/main`; no open PRs; no draft PRs; all CI green.
Open issue count: 0 (all 130+ issues closed), so there was no issue debt to
drive; the session delivered the pending policy/speed surfaces instead and
filed one follow-up (#132). PLAN's remaining items stay human-gated or
decision-gated, so nothing on PLAN could move.

## ASCII docs policy ("no LLM-isms")

The docs surface is all tracked Markdown plus `llms.txt` (90 files at the
sweep; 91 counting this record). A mechanical sweep removed ~640 non-ASCII
characters: em/en dashes, arrows, middle dots, section signs, ellipses,
math signs, and the site footer sign. It also removed the two contrast
hits found (both of the "not-just" filler family). The one
intentional non-ASCII string (the changelog's multi-byte UTF-8 example)
carries an inline `<!-- sf-allow:non-ascii -->` marker, which suppresses
every check on its own line.

`scripts/check-docs-style.py` (stdlib-only, ~0.4 s over the tracked docs,
with a `--self-test`) enforces the policy: any non-ASCII character outside
a marked line, plus four contrast/filler patterns. Wired into:

- `docs-validation.yml` markdownlint job (one fast step, off the job
  critical path).
- `run-runtime-checks.sh changed`: doc edits now get a real local
  check instead of "no runtime checks" (docs-only trees, and the dirty-doc
  files of mixed edits). Red-green verified: a dirty Markdown
  tree with a violation exits 1 with GitHub `::error file=,line=,col=`
  annotations; clean exits 0.

The durable rule lives in `.llm/context.md` (working rules).

## Docs CI wall (no coverage change)

- MkDocs venv cached like `ci.yml`/`llm-harness.yml` (#111 pattern): the
  9 s pip install becomes a ~1 s restore on warm runs.
- Chromium system-deps stamp inside the cached browser directory, keyed to
  runner image + Playwright version: warm runs skip the ~9 s `npx
  install-deps --dry-run` boot and the apt update/install cycle that
  reliably fired for the same small font set (verified in the run logs).
  Expected accessibility job: ~60 s to ~35 s; main-push docs-live chain
  ~95 s to ~62 s. First run on the new key pays the cold path once.

## Local iteration speed (data)

- `changed` on a docs-only dirty tree: previously a no-op print; now the
  style check, ~0.5 s, failing red in under a second.
- `changed` clean tree 0.3 s; `all` 5.0 s; single warm suite ~2 s;
  `agent-check` 2.0 s. Confirmed session 045's finding: the runtime loop is
  already sub-6 s, so the remaining lever was the docs loop, which had no
  local check at all.
- `test-llm-harness.ps1` now prints per-test wall time; the profile shows a
  serial pwsh-boot long tail (top test 6.1 s, top 20 ~55 s of ~75 s local),
  recorded with options in #132.

## Issue debt

- 0 open issues at session start (checked via `gh issue list --state all`);
  nothing to fix. #132 filed with data for the harness wall (next session's
  cheap win: behavioral/non-behavioral sharding).
- Dependabot alerts open: 0. No open dependency PRs.

## Adversarial rounds

- Round 1 (sub-agent) caught the record tripping its own gate, a deleted-doc
  false red, the llms.txt fast-path gap, fenced-code false positives, a
  collapsed nested list in session 007's record, annotation format, the
  ImageVersion=unknown stamp staleness, and wrong stats. All fixed.
- Round 2 (sub-agent) verified every fix and caught two prose-accuracy
  regressions in this record plus a stale PR body. Fixed.
- Bugbot flagged one real local gap this record's text above now covers
  (untracked new docs escaping the local check) and a genuine subdirectory
  enumeration bug in the checker (git ls-files paths are relative to the
  invocation directory). Both fixed with execution-verified red-green runs.

## Checks

- `run-runtime-checks.sh all` green (5.0 s); `changed` red-green for the
  docs path; checker `--self-test` green.
- `run-llm-hooks.ps1 -Mode Full` green locally (114 self-tests, preflight,
  regenerate + lint, generated diff).
- `validate-github-config.py` self-test + repo check green (also run by the
  pre-commit hook on each commit).
- Red-green for the style checker itself is pinned by its `--self-test`
  (21 assertions: banned chars, patterns, code-fence skipping, marker
  scope, clean pass).
