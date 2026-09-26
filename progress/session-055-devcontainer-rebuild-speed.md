# Session 055: Devcontainer rebuild speed + carried-forward WSL harness work

Session branch: `session-055-devcontainer-rebuild-speed` (from `origin/main`
@ `ef2887a`). One aggregate PR.

## Scope

- No open PRs; main CI green; one open issue (#145) whose remaining option
  (dedicated runner jobs) both prior sessions deliberately deferred - left
  open, not a drive-by.
- Carried forward the uncommitted devcontainer optimization work from the
  previous session and finished it.

## Changes

### Devcontainer rebuild speed/reliability

- `Dockerfile`: single apt transaction (python toolchain merged into the
  system layer); BuildKit cache mounts for apt indexes/archives, the Godot
  editor zip, and pipx/pip wheels - warm rebuilds stop re-downloading the
  heavy inputs, and `--no-cache` rebuilds keep them too; `SHELL` pinned to
  bash with pipefail; curl downloads get `--retry-all-errors` (plain
  `--retry` does not retry HTTP-level failures).
- Python now comes from Ubuntu apt (3.12; docs CI pins 3.12, runtime CI
  tracks 3.x) instead of the python devcontainer feature (~2.5 min saved
  per no-cache rebuild); the flaky git Launchpad-PPA feature is gone (base
  git 2.43 suffices); PEP 668 pre-unlocked via `/etc/pip.conf` so the
  local gate installs like CI.
- `devcontainer.json`: `initializeCommand` guard creates `.env.local` from
  `.env.example` on fresh clones (docker `--env-file` fails the create
  otherwise). `upgradePackages: false` (nondeterministic full apt upgrade
  per feature install).
- `ensure-env-file.ps1` (new): the guard; never overwrites an existing
  file, fails loudly when `.env.example` is missing.
- `post-start.sh`: a broken `.venv-ci` is rebuilt from scratch instead of
  upgraded in place - `venv` dies with Errno 2 when the venv's interpreter
  symlink points at a moved Python.
- `install-godot.sh`: optional cache dir; a cached zip is trusted only
  after the same size + integrity checks a fresh download gets.

### Bugs found and fixed in the carried-forward work

- **Blocker: the sandbox `node` shim infinitely re-exec'd itself on
  Linux** (see round 1 below).
- **Hygiene: the `# Godot runtime` comment sat inside the apt package
  list.** A shell-level simulation suggested this broke the install, but
  Docker strips full-line comments inside a continued `RUN` before the
  shell runs - `main` was never broken (verified empirically: this
  container, built from that Dockerfile, has the Godot libs as manual apt
  packages). Removed anyway: inside the quoted `PKGS` value the comment
  could never document anything, and the shell-level view is misleading
  to readers. The Dockerfile now notes that grouping notes belong in the
  block comment above the list.
- **`initializeCommand` needed host pwsh**, which the README quick start
  does not require - a pwsh-less host would trade the old create failure
  for a new one. The command now falls back to plain `cp` on any POSIX
  host, passes the workspace folder as an argument (paths with quotes
  cannot break the script), and the README documents the host-shell
  prerequisite.
- The carried README text claimed `Rebuild Without Cache` re-downloads
  because BuildKit "ignores cache mounts" - wrong: `--no-cache` skips
  layer cache only; cache mounts still apply. Reworded to match BuildKit
  semantics.

### Harness: WSL-bash compatibility for the behavioral suites (carried)

`scripts/test-llm-harness.ps1` behavioral suites can now run under WSL's
`bash.exe` (previously Windows-only sandboxes broke): WSL detection, path
translation, argument inlining (WSL bash drops positional args after
`-c`), `WSLENV` passthrough for sandbox env vars, a WSL-only `node` shim
that forwards to `node.exe`, and pwsh-native file ops replacing bash
one-liners where the bash flavor added no coverage. Coverage unchanged:
same cases and assertions everywhere.

### Bugs found in the carried harness work (adversarial round 1)

- **Blocker: the sandbox `node` shim infinitely re-exec'd itself on
  Linux.** Both behavioral sandboxes put their `bin` first on `PATH`; the
  shim's `exec node` fallback resolved back to the shim (no `node.exe` on
  Linux), hanging the suites until the CI timeout. The work had only ever
  run on Windows, where the `node.exe` branch fires first. Fix: the shim
  is now written only under WSL (other platforms resolve the real `node`
  exactly as before the diff), and its fallback fails loudly instead of
  re-executing.

## Adversarial review round 1 (sub-agent) - findings and fixes

Findings (the Dockerfile-token item below was later corrected by round 2):

- **BLOCKER, fixed:** the sandbox `node` shim re-exec'd itself forever on
  Linux (sandbox `bin` first on `PATH`, no `node.exe`; `exec node`
  resolved back to the shim), wedging the behavioral shards until the CI
  timeout. The carried work had only ever run on Windows. Fix: shim is
  written only under WSL (all other platforms keep the pre-diff behavior:
  bare `node` resolves the real node), and its fallback now fails loudly
  with a labeled error instead of re-executing.
- **MAJOR, fixed:** `initializeCommand` interpolated
  `${localWorkspaceFolder}` inside a single-quoted sh script - an
  apostrophe in the workspace path broke the create (and a crafted path
  could inject commands). The folder now rides in as the script's `$0`.
- **MAJOR, corrected by round 2:** the guard hard-depends on host `sh`
  (it spawns `sh` unconditionally, and a spawn failure halts the create).
  Round 1 documented a "sh or pwsh" prerequisite; round 2 made it
  accurate: `sh` is required, `pwsh` only upgrades the guard, and
  pre-creating `.env.local` does not bypass the guard.
- **MINOR, fixed:** `Add-EnvToWslPassthrough`'s comment asserted an
  unverified absolute WSL env model that contradicted the `wslpath`
  fallback's assumption. Comment now states the conservative rationale;
  the fallback registers `SF_WSLPATH_INPUT` for passthrough so it works
  under either model.
- **MINOR, fixed:** "Python 3.12 - matching CI" overstated (runtime CI
  tracks 3.x; only docs CI pins 3.12). README, Dockerfile comment,
  devcontainer.json comment, and this log now state the real
  relationship.
- **MINOR, fixed:** `.llm/skills/devcontainer-tooling.md` was stale
  against the diff: Python-feature dependency removed from the placement
  rules (apt-provided Python noted), `.venv-ci` rebuild-from-scratch +
  PEP 668 documented, cache mounts and the env guard added to Current
  Guarantees.
- **NITs, fixed:** two README contrast constructions the style checker
  cannot catch were reworded; the templates cache mount gained
  `sharing=locked` (consistency with the four new mounts); an unwritable
  Godot download cache dir now fails with a labeled diagnostic.
- **Accepted residuals:** warm apt lists mean installed versions resolve
  against first-build indexes until a hard failure refreshes them
  (documented trade-off); the cached zip is integrity-tested twice on the
  cached path (harmless; shared verify block).

## Adversarial review round 2 (sub-agent) - final verification

Behavioral shard re-run independently on Linux (`-OnlyBehavioralTests`,
37/37 green). Verdict before fixes: NOT-MERGE-READY on two text-only
MAJORs; everything else (harness Linux coverage, Dockerfile mechanics,
guard mechanics, cross-file consistency, conventions) zero issues. Both
MAJORs and the follow-ups are now fixed:

- **MAJOR, fixed:** round 1's "blocker on main" for the apt-list comment
  was a phantom - Docker strips full-line comments inside a continued
  `RUN` before the shell runs, so `main` was never broken (proven by this
  container itself: built from that Dockerfile, Godot libs installed as
  manual apt packages). The log and the Dockerfile guard comment now
  state the true (hygiene) rationale.
- **MAJOR, fixed:** the guard docs misstated the host-shell requirement
  (`sh` is mandatory - the create halts on spawn failure even when
  `.env.local` exists; `pwsh` merely upgrades the guard; a default
  Windows Git install does not put `sh.exe` on PATH). Quick start,
  troubleshooting, and the skill file now say exactly that, and the
  impossible "`pwsh: not found`" failure was dropped.
- **MINOR, fixed:** the fourth "matching CI" site (devcontainer.json
  comment) reworded like the other three.
- **MINOR, fixed:** a glued Markdown list item in this log.
- **NIT, fixed:** post-start comment now says the rebuild branch is
  entered when the venv is missing OR broken (only the broken case comes
  from `venv_ok`).

## Bugbot review (round 3, on the pushed PR) - findings and fixes

Cursor Bugbot left two Medium findings on commit `e5c1baa`; both confirmed
real, both fixed, plus one adjacent gap found by sweeping the same classes:

- **Apt archives mount was defeated by `docker-clean`** (confirmed live:
  the hook file exists in this container and wipes
  `/var/cache/apt/archives/*.deb` after every apt operation, so the
  `/var/cache/apt` mount could never retain payloads - only the lists
  mount worked). Fix: the apt RUN removes `docker-clean` first;
  trade-off (later apt users keep their .deb/pkgcache payloads)
  documented in the Dockerfile and the devcontainer skill. Sweep: the
  other five cache mounts (curl/pip/pipx targets) have no in-image
  cleanup - class closed.
- **WSL PATH ordering broke sandbox hermeticity**: WSL bash appends the
  translated Windows PATH after the Linux PATH, so the suites'
  Windows-side `$env:PATH = sandbox-first` loses inside bash and a host
  npm/node/gh would beat the fakes (real npm against a host prefix, or a
  vacuous pass). Fix: new `Set-WslBashSandboxPath` helper pins the
  sandbox bins via `BASH_ENV` (bash sources it in non-interactive
  script runs), wired into all three suites that resolve tools by bare
  name inside bash (fake-gh auto-merge, agent-tools migration with
  per-case retargeting, mcp installer); suites resolving nothing by
  bare name were verified clean by class sweep. Follow-up hardening
  from the verification round: single-quote guard on bin paths (a
  broken pin made bash run un-pinned and fail misleadingly),
  `[ValidateCount(1,...)]` against an empty pin, WSLENV snapshot in the
  auto-merge suite, and `FAKE_GH_LOG` now carries the bash flavor with
  a separate Windows path for pwsh assertions (the fake gh could never
  write the raw Windows path under WSL).
- Empirical verification of the mechanism (sub-agent, Linux container):
  `bash -c` / script args source BASH_ENV (and `bash -n` does not
  execute it, so the parse checks stay immune), child bashes re-source
  it idempotently, PATH head with a space survives quoting, snapshot
  and restore audited at all three call sites, and every other `& bash`
  site classified as not needing a pin.

## Bugbot review (round 4, on the fix commit) - finding and fix

- **Auto-merge suite registered only `FAKE_GH_LOG` for WSL passthrough**
  while setting six more custom variables (`FAKE_GH_SCENARIO`, `GH_TOKEN`,
  `GITHUB_REPOSITORY`, `HEAD_SHA`, `HEAD_BRANCH`, `REQUIRED_WORKFLOWS`)
  that the fake gh and `dependabot-auto-merge.sh` read inside bash (the
  script hard-requires two of them). Under the WSLENV-filtered boundary
  the defensive registration exists for, they would arrive empty and the
  suite would fail with metadata missing - or pass vacuously. Fix: all
  seven registered; the registration-completeness sweep confirms this
  was the last unregistered bash-consumed variable in the harness (the
  migration, seed, and mcp suites already register everything they set).
  Skill guidance now states the rule explicitly: register EVERY custom
  variable a suite reads inside bash, not only path-like ones.

## Validation

- `pwsh -NoProfile -File scripts/test-llm-harness.ps1` (core + behavioral,
  119 tests) green after the node-shim fix; pre-fix runs hung in the
  migration suite exactly where round 1 predicted. Behavioral shard
  re-confirmed green (37/37) after all round-2 fixes. Re-run green again
  after the Bugbot fixes (119/119).
- `pwsh -NoProfile -File scripts/agent-check.ps1` green.
- Dockerfile `RUN` word list verified clean by extraction + token check
  (with the caveat, per round 2, that Docker's parser strips full-line
  comments before the shell - the check validates the shell view).
- `bash -n` green on all changed shell scripts; docs style and JSONC parse
  green; `git diff --check` clean. Round-4 fix re-validated: harness suite
  green (119/119), agent-check + docs style green.
