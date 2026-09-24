# Session 012 - v0.9.1 Protocol Surface, Changelog, Release Automation, uv CI

**Date:** 2026-09-20
**Branch:** `issue-debt-sweep-2` -> PR to `main`
**Goal:** Address the 4 remaining open issues (#26, #29, #28, #27); CI time flat-or-down; no
coverage loss.

## What landed

### Issue #26 - v0.9.1 protocol surface (correctness)

- **Error codes 41 -> 63 named tokens** (`sf_error_codes.gd`): the full upstream
  server v0.9.1 table @ `24a5d10b` (62 codes) plus the cloud-only
  `DATABASE_ERROR` alias. Upstream's 6 `NON_EMITTED` decode-compat tokens are
  annotated (`NON_EMITTED_CODES`).
- **Drift-proofed by construction:** the string<->enum tables are now *derived
  from the enum itself* (a named GDScript enum is a Dictionary; wire tokens are
  the keys). Adding a code is one enum line. `category()` moved from
  contiguous-range checks (which the issue flagged as append-hostile) to a
  per-code map following the upstream `docs/reference/error-codes.md` tables.
  A data-driven test sweeps every enum token: round-trip + explicit category
  (all 63 pinned), so an append without a category fails loudly.
- **Builders:** `SFMessages.start_game()` (unit message, present in the
  upstream v2 wire sample), `password` on `join_room`/`join_as_spectator`
  (upstream `JoinRoomPayload`/`JoinAsSpectatorPayload.password`, sealed rooms
  fail with `PASSWORD_REQUIRED`; a password to an open room is refused, so
  empty = omitted from the wire).
- **Client API:** `start_game()` (guarded like `set_ready`), `JoinRoomParams.password`,
  optional `password` on `join_as_spectator`. Join passwords join the redaction
  list like tokens.
- **Fixture:** `v2_client_messages.jsonl` now carries 12 lines (StartGame +
  password placeholders, `-not-secret` convention).

### Issue #29 - CHANGELOG + copy rule

- `CHANGELOG.md` (Keep a Changelog, SemVer policy): one `Unreleased` section,
  user-relevant entries only (no CI/test churn).
- Copy rule added to `.llm/context.md`: user-facing copy stays extremely
  short, simple, STE-style; changelogs list user-relevant changes only.

### Issue #28 - manual release automation

- `.github/workflows/release.yml` (`workflow_dispatch`, `version` input):
  validate `vMAJOR.MINOR.PATCH` (before any env write), cut release notes from
  the matching `CHANGELOG.md` section (prefix-matched header; missing section
  fails loudly), enforce the P6 packaging contract (`plugin.cfg` exists and its
  version equals the tag), refuse pre-existing tags, zip `addons/` at zip root,
  `gh release create` tags + publishes. `contents: write` on the release job
  only; `concurrency: release` serialized. Zero fast-gate impact
  (dispatch-only). Asset-store auto-publish stays gated on the one-time Asset
  Library bootstrap (PLAN section 10).

### Issue #27 - uv for python tooling

- Measured locally: uv path (venv + install) ~ 1.6s vs pip venv path ~ 7.4s.
- Adopted in `ci.yml` only (the LLM harness workflow is untouchable by locked
  decision): `pip install uv` + `uv venv .venv-ci` + `uv pip install` into it;
  `run-runtime-checks.sh` unchanged (same `.venv-ci` activation). Same pinned
  gdtoolkit, zero coverage change, net CI-time decrease. Devcontainer python
  tooling is pipx/pre-commit (no pip deps to convert).

## Verification

- `bash scripts/run-runtime-checks.sh all` - green (private-helpers, format,
  lint, all 5 Godot suites) with a uv-built `.venv-ci`, mirroring CI exactly.
- `pwsh scripts/agent-check.ps1` - green (`.llm` edits followed by index regen).
- `python3 scripts/validate-github-config.py --repo-root .` + `--self-test` - green.
- `python3 scripts/check-protocol-sync.py --self-test` - green (pin sites intact).
- release.yml building blocks exercised locally: version regex (accept/reject
  matrix incl. multiline), CHANGELOG section cut (dated header + missing case).

## Adversarial review

Red-team sub-agent returned 0 P1 / 3 P2 / 8 P3. Fixed: all 3 P2s
(release.yml injection vector via multiline input - validate before
`GITHUB_ENV`; un-submittable releases - plugin.cfg contract enforced with
version==tag; stale README error-code count) and the meaningful P3s (stale
PLAN count, awk header form vs Keep a Changelog date suffix, concurrency +
stale-tag guard, unknown-int `to_wire_string`/`from_string` pins, full 63-code
category table instead of spot pins, join-password redaction).

Deliberately not adopted: `astral-sh/setup-uv` action (third-party action +
SHA pin for one bootstrap line; `pip install uv` is cache-covered and
self-healing) and uv version pinning (requirements-ci.txt stays
runtime-tooling-only; a uv pin there would re-install uv into the venv it
bootstraps).

## Issue outcomes

- #26: fixed (error codes + StartGame/password) -> close via PR.
- #29: CHANGELOG + SemVer + copy rule shipped -> close via PR.
- #28: manual release workflow shipped (asset-store auto-publish remains gated
  on P6 bootstrap; documented in PLAN section 9/section 10) -> close via PR.
- #27: researched + adopted where python tooling lives in the fast gate ->
  close via PR with measurements.

## Follow-ups

- P5 remains: Godot 4.4.x matrix row + web-export-smoke job (both flat
  wall-clock by design).
- P6 remains: plugin.cfg + icon + release-triggered asset-lib publish job.
