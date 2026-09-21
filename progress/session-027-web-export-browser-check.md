# Session 027 — Web-export browser checklist automation

Date: 2026-09-21. Scope: one focused surface — the last automatable P4 item
(the browser-export manual checklist) — plus issue-debt cleanup. Drift check
first: main was green on `b1bbde8`, local main matched origin/main, no open
PRs, no in-progress work to carry forward.

## Issue debt

- Closed #67 and #65: both were delivered by the already-merged #68
  (`scripts/check-docs-accessibility.cjs` + `accessibility` job;
  `docs/releasing.md`) but the issues were never closed. Open issues: 0.

## Delivered

1. **Browser-export checklist automated** (PLAN P4, last manual item):
   - `demo/demo_client.gd`: web-only smoke hook. `?sf_smoke_endpoint=...`
     (+ optional `sf_smoke_app_id`) prefills the fields, dials, and mirrors
     demo log lines to `window.__sfSmokeLog` via `JavaScriptBridge` (only
     while a smoke run is active). Inert without the query params and in
     native/editor builds.
   - `scripts/web_smoke_server.mjs`: local HTTPS static server + minimal
     RFC 6455 wss server, both loopback-bound. Asserts the browser-set
     `Origin`, replies `Authenticated` (valid `rate_limits`) and `Pong`.
     Frame decoder keeps partial frames across TCP reads, requires masked
     client frames, and rejects unexpected opcodes.
   - `scripts/check-web-export-browser.cjs`: Playwright driver. Phase 1:
     engine boot over HTTPS + real `wss://` dial, server asserts
     `Origin: https://127.0.0.1:8443`, demo round-trips
     Authenticate/Ping/Pong. Phase 2: `ws://` from the secure page is
     refused by the client predial check with the exact mixed-content
     message and never reaches the server. Fails on missing log lines,
     unexpected connects, or page errors. A planned browser-native
     `ws://` probe was dropped after an empirical check: Chromium treats
     loopback as potentially trustworthy, so `ws://` to loopback from an
     HTTPS page is allowed by design — the browser-level block only
     applies to production (non-loopback) hosts, and the enforced
     guarantee here is the client predial check.
   - `web-export-smoke.yml` (weekly + dispatch only; fast gates untouched):
     cert generation, cached Playwright 1.61.1 + Chromium, browser check.
2. **Export pack bug found and fixed** (caught by the new check):
   `export_filter="scenes"` does not chase `preload()` chains in scripts, so
   the weekly export produced a page that booted the engine and then failed
   with missing `res://addons/signal_fish/**` scripts (verified by parsing
   the pck directory: 10 files, 2 scripts). The preset now uses
   `all_resources` with dev trees excluded (56 files, 22 scripts), and the
   page boots and dials end-to-end.
3. **Fast-gate CI time trimmed**: docs `accessibility` job (the slowest
   fast-gate job, ~55 s) now caches `node_modules` alongside Chromium and
   splits `playwright install` (skipped on cache hit) from
   `playwright install-deps` (apt, always needed on fresh runners). The
   npm install + browser no-op work no longer re-runs every job.

## Validation

- Browser check green locally end-to-end (real 4.3-stable export +
  headless Chromium).
- `run-runtime-checks.sh godot` green (all suites + demo boots; smoke hook
  is web-gated and inert headlessly).
- `run-runtime-checks.sh format` / `lint` green.
- `validate-github-config.py --repo-root .` green.
- `agent-check.ps1` green.

## Leftovers / follow-ups

- None new. Remaining PLAN items are human-gated (Asset Library bootstrap)
  or deferred by decision (Godot 3.6, Rkyv revisit).
