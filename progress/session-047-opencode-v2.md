# Session 047 - OpenCode v2 Devcontainer

Date: 2026-09-24

## Scope

- Replace package-managed OpenCode v1 with the latest OpenCode v2 on every
  successful devcontainer start.
- Keep the `opencode` command and existing configuration compatible.
- Preserve strict first-install and warn-only refresh behavior.

## Work log

- RED: changed the devcontainer self-tests first to require `@opencode/cli`,
  v1 removal, major-version 2, and per-package registry decisions. The full
  harness failed on the v1 installer as expected.
- GREEN: migrated the default package to `@opencode/cli@latest`, retained the
  `opencode` binary, and kept the bounded parallel version probe.
- Hardened the one-time migration: stage and verify v2 in an isolated prefix,
  uninstall v1, activate v2, and restore the exact v1 version on failure.
- Added npm 11 lifecycle approval for the trusted v1 rollback, symlink
  ownership checks, `opencode2` dangling-link cleanup, and per-package probe
  state so an unrelated registry failure does not block OpenCode.
- Added one data-driven fake-npm state-machine suite covering online migration,
  unrelated probe failure, offline retention, candidate/install/activation/
  rollback failures, ownership, idempotence, and version parsing.
- Corrected `postStartCommand` semantics: it runs after each successful
  container start, not after each attach.

## Verification matrix

| Scenario | Result |
| --- | --- |
| RED full harness | Failed on missing v2 package and lifecycle contract |
| Offline `--update` with v1 | Exit 0; retained v1 for later migration |
| Online v1 to v2 migration | v1 removed; `@opencode/cli` matched npm latest |
| Online `--update` rerun | Exit 0; all agent CLIs current |
| Offline `--update` with v2 | Exit 0; retained v2 |
| Hermetic migration matrix | 13 state transitions passed |
| Full LLM harness | 115 tests passed |
| Runtime changed checks | All suites passed on Godot 4.3 |
| Docs style, Markdownlint, links, MkDocs | Passed |

Live npm reported `@opencode/cli` 2.0.15 at initial research and 2.0.16 during
validation. A real v1 1.18.32 restore followed by `post-start.sh` migrated to
v2.0.16; `npm list` then contained only `@opencode/cli@2.0.16`.

## Review

- Independent review found the destructive v1-before-v2 window and missing
  behavioral coverage.
- Adversarial review found npm EEXIST, aggregate probe coupling, v2 ownership,
  npm 11 rollback policy, dangling-link cleanup, and WSL path issues.
- Separate implementation passes fixed each finding. The final adversarial
  review returned APPROVED with zero issues.

## PR

- PR #135 passed all Runtime CI, Docs Validation, and LLM Harness jobs with no
  review threads or bot comments at the recorded head.
