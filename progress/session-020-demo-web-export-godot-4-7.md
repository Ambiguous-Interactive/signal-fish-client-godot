# Session 020 — Demo Project, Web Export Smoke, Godot 4.7 Matrix

**Date:** 2026-09-21
**Branch:** `feat/demo-web-export-godot-47` → PR to `main`
**Goal:** Advance PLAN P4/P5 (demo project + web-export smoke), close issue
#51 (Godot 4.7 support), and keep fast-gate CI wall clock flat or lower
without touching test coverage.

## Drift check

Main green (Runtime CI 31s + LLM Harness 53s), no open PRs, tree clean,
branch cut from `origin/main` at `d2ee586`. No draft or in-progress PRs;
all local branches were pre-squash leftovers from merged PRs.

## What landed

### Issue #51 — Godot 4.7 support

Godot 4.7.2-stable exists upstream. The full suite (all five runners, plus
static checks and a headless demo boot) was verified locally against the
real 4.7.2 binary before touching CI. `ci.yml` gained a `4.7.2-stable`
matrix leg; legs run concurrently, so wall clock stays at max(legs), not
sum. The 4.3 pin-drift guard (`validate-github-config.py --self-test` +
repo validation) still passes.

### P4 — demo project (connect → join → game data → leave)

`demo/main.tscn` + `demo/demo_client.gd`: minimal Control UI (endpoint,
app id, game, player, room code, send text) wired to the shipped client
API, with an event log. Follows repo idioms: preload consts instead of
cross-`class_name` globals (cold-cache safe), fully typed handlers
(warnings-as-errors), `_on_*` naming (private-helper guard treats them as
roots). Set as the project main scene; `demo/` added to the gdformat /
gdlint / private-helper guard scopes.

### P5 — web export preset + export smoke off the fast gate

`export_presets.cfg`: "Web" preset exporting the demo scene (dependency
closure only, binary-token scripts, nothreads). The export was verified
end-to-end locally against real 4.3-stable templates: `index.html` +
`index.wasm` + a 96 KB `index.pck`.

`.github/workflows/web-export-smoke.yml`: weekly cron + dispatch, never on
push/PR — template-download minutes stay out of every fast-gate run
(same pattern as `protocol-sync.yml`). Catches export breakage without
slowing PRs. Verified details: the exporter refuses a missing target
folder on a fresh checkout, so the job pre-creates `build/web`; third
party action pinned to commit SHA.

### CI wall-clock decrease (coverage unchanged)

Sampled `/proc/<pid>/maps` across full headless suite runs: Godot loads
only `libfontconfig`, `libfreetype`, and `libudev`; the X11/GL/audio/dbus
stack is never loaded. The `test` job's apt list dropped 11 packages
(the apt step measured 10-15s on recent runs; fewer packages should cut
it to the apt-get update floor). `ca-certificates`, `curl`, `unzip` stay
(install-script requirements; no-ops on runners). Static-check scope grew
to include `demo/`, and the `godot` target now boots the demo scene
(`--quit-after 3`) on every matrix leg, so demo regressions cannot hide
on a version the fast gate covers.

## Verification

- `run-runtime-checks.sh all` green on 4.3-stable and 4.7.2-stable.
- `validate-github-config.py --self-test` + repo validation green.
- Headless demo boot (import + 3 frames) clean on both binaries.
- Local web export with real templates produces the expected artifacts.

## Leftovers / follow-ups

- Headless `WebSocketPeer` smoke test (network-gated/opt-in) — PLAN P4.
- Browser-export manual checklist — PLAN P4 (human-in-the-loop).
- Demo P2P scene — PLAN P3/P4 leftover.
- `plugin.cfg`/`icon.png` for the addon — PLAN P6.
