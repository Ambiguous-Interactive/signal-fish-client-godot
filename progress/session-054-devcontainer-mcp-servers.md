# Session 054: Devcontainer MCP servers seeded from .env files

Branch: direct work session on the devcontainer MCP plan (research-backed).
One aggregate PR.

## Goal

Wire seven MCP servers into every agent CLI in the devcontainer (claude,
opencode v2, nanocoder, codex, VS Code agent host) without ever writing
secret values to disk, and complete the Godot install (web export
templates) so the repo's only export preset works locally.

## Research findings that drove the design

- Repo-root `.mcp.json` is read natively by Claude Code (project scope),
  Nanocoder (project scope), and the VS Code agent host - one committed
  file serves three clients. Verified against the installed claude CLI
  that it tolerates the extra `transport` key Nanocoder needs on remote
  entries (hybrid `type` + `transport` schema).
- OpenCode v2 changed its config schema: `mcp.servers.<name>`,
  `environment`, `disabled`, `{env:VAR}` interpolation - not the v1
  `mcp.<name>` shape that most published examples still show.
- Codex config.toml has no env-expanding format; `env_vars` only forwards
  same-named variables. Combined with the repo's `GITHUB_MCP_PAT`
  convention, a name-mapping launcher shim solves renaming for every
  client uniformly without persisting values.
- Official GitHub MCP server ships a Docker image (needs Docker-in-Docker
  inside a devcontainer - rejected) and native release binaries with a
  `checksums.txt` for verification.
- @playwright/mcp bundles its own playwright (1.64.0-alpha) whose Chromium
  revision is independent of the repo's pinned `playwright` 1.61.1 used by
  the web-export smoke test, so the browser must be installed through the
  MCP package's bundled CLI, not the repo pin.
- `godot --version` prints `4.3.stable.official.<hash>`; deriving the
  export-templates directory name from the installed editor itself removes
  the tag-munging failure mode entirely.

## Deliverables

- `.env.example` (committed; `.env*` was already ignored with this exact
  exception whitelisted) documenting every variable; `runArgs
  --env-file .env.local` loads values into the container environment at
  create time.
- `.mcp.json` + `opencode.json` (committed): all seven servers
  (`godot`, `github`, `context7`, `deepwiki`, `git`, `fetch`,
  `playwright`), secrets referenced by name only.
- `.devcontainer/seed-mcp-config.sh`: marker-delimited managed block in
  `~/.codex/config.toml` (idempotent, byte-exact skip, preserves content
  outside markers, refuses unmanaged duplicate tables and corrupted
  blocks) plus a doctor that prints variable names and set/unset state
  only.
- `.devcontainer/mcp-shims/sf-github-mcp.sh`: renames `GITHUB_MCP_PAT`
  onto `GITHUB_PERSONAL_ACCESS_TOKEN` at launch, defaults
  `GITHUB_READ_ONLY=1`, fails loudly with no token.
- `.devcontainer/install-mcp-servers.sh`: pinned npm specs (strict at
  post-create, warn-only `--update` at post-start), offline
  "already current" skip from npm's own state, npm >= 11 allow-scripts,
  best-effort Chromium via the MCP package's bundled playwright CLI
  (install mode only, `SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1` escape hatch).
- Dockerfile: checksum-verified github-mcp-server binary, pipx
  `mcp-server-git`/`mcp-server-fetch`, and
  `install-godot-templates.sh` (BuildKit cache mount for the ~900 MB
  archive, web-only extraction, editor-derived templates directory).
- post-create/post-start wiring; harness static + behavioral suites for
  the new tooling; `.devcontainer/README.md` and
  `.llm/skills/devcontainer-tooling.md` documentation; regenerated LLM
  index.

## Bugs found and fixed during red-green

- `seed-mcp-config.sh`: `rc` was initialized to 1 before the awk
  upsert, so a *successful* replacement took the append path - a drifted
  managed block would have been replaced AND re-appended (duplicate TOML
  tables). Caught by adding the drift case to the behavioral suite.
- `seed-mcp-config.sh`: the append path originally re-appended awk's
  output (the original content), which would duplicate the whole user
  config; fixed to append the managed block itself.
- `install-mcp-servers.sh`: the `package_is_installed` node snippet read
  `process.argv[1]` as an object, but `node -e script a b` passes plain
  strings at argv[1]/argv[2] - readiness checks could never pass.
- Test-side (fixture, not production): the fake npm's spec parse picked
  the `install` subcommand as the spec; specs must contain `@`.

## Adversarial review round 1 (sub-agent) -- findings and fixes

- **BLOCKER, fixed + regression-tested:** `seed_codex_config`'s
  byte-compare short-circuit fired on the append path (awk echoing an
  unchanged file compares equal), so an existing `~/.codex/config.toml`
  without the managed block was silently "current; skipped" with exit 0 --
  the append branch was reachable only via a missing trailing newline.
  Fixed by gating the compare on the awk "block found" result; added the
  missing behavioral cases (existing config without block, empty file)
  that would have caught it red.
- **MAJOR, fixed by redesign:** `.mcp.json` used a remote context7 entry
  with `Authorization: Bearer ${CONTEXT7_API_KEY:-}` -- but the VS Code
  agent host does not substitute variables in remote headers, so the
  "one file, three clients" claim was only structurally true, and the
  default empty bearer produced a Claude Code whitespace warning.
  Empirically verified with the installed clients that Claude Code and
  Nanocoder do NOT inherit arbitrary parent env for stdio servers (the
  github health check failed until an explicit env map was added;
  Nanocoder's transport source keys full `{...process.env}` inheritance
  off the map's presence). context7 therefore became the local
  `context7-mcp` stdio server (pinned npm, key from env, anonymous
  startup verified) and `.mcp.json` now REQUIRES explicit env maps for
  secret-driven entries -- asserted in the static suite.
- **MINOR, fixed:** non-concrete npm spec overrides are rejected at
  startup (a dist-tag would have reinstalled on every post-start and
  failed verification after a successful install); the codex
  conflict/doctor detection is now anchored, subtable-aware
  (`[mcp_servers.godot.env]` counts), CR-tolerant, and ignores
  commented-out lines; the doctor gates the exit status in install mode
  (MISSING is a failure, not a note) -- the safety net that would have
  surfaced the BLOCKER immediately.
- **NITs, fixed:** Dockerfile checksum verification used a download
  filename that could not match `sha256sum -c`'s listed name (found live:
  every image build would have failed) -- the archive now keeps its
  canonical asset name, and the checksums curl gained the retry flags;
  readiness requires the bin to exist AND be executable; the bundled
  playwright path is passed to node via the environment; the templates
  installer no longer clobbers `TMPDIR`; extra argv is rejected in both
  new scripts; canary sweeps now cover the whole sandbox tree; the
  committed-secret guard also rejects the `ghp_` token shape.
- **Found by the fixes themselves:** this awk's
  `sub(/a|b/, "", x)` alternation misbehaved in the new conflict-table
  extraction (left a stray `]`, so conflicts went undetected) -- replaced
  with two sequential subs and covered by the conflict case (which now
  fails red against the broken form).

## Adversarial review round 2 (sub-agent) -- findings and fixes

- **MAJOR, fixed:** `.mcp.json` used `${VAR:-default}` env-map values, but
  VS Code's workspace MCP config only converts BARE `${VAR}` references
  (`${VAR:-default}` and remote headers pass through literally) - so
  github/context7 would have failed on the VS Code agent host even when
  fully configured. Switched to bare `${VAR}` (verified Claude expands it;
  Nanocoder keys inheritance off map presence so the value text is
  irrelevant there; unset-variable cases fail loudly via the shim guard).
- **MINOR, fixed:** two complete managed blocks in `~/.codex/config.toml`
  were "repaired" into duplicate TOML tables with exit 0 (the exact damage
  the round-1 blocker caused). The replace awk now refuses on a second
  begin marker; behavioral case added.
- **MINOR, fixed:** `GITHUB_READ_ONLY=0` never reached the server on
  Claude Code/Codex. The codex allow-list now includes
  `GITHUB_READ_ONLY`/`GITHUB_TOOLSETS`; the Claude Code limitation (mapped
  variables only) is documented in `.env.example` and the README instead
  of pretending the opt-out works everywhere.
- **MINOR, fixed:** stale docs claiming `{env:VAR}` in `opencode.json`
  (it relies on parent-env inheritance; no maps needed) and
  `bearer_token_env_var` in the codex block (superseded by `env_vars`);
  progress log validation section updated to the final server shapes.
- **NIT, fixed:** README override list now includes `CONTEXT7_MCP_NPM_SPEC`.
- **Accepted residual:** quoted TOML table keys (`[mcp_servers."godot"`)
  are not recognized by the conflict guard - rare authoring form, and the
  doctor would still show the server as configured.

## Validation

- `pwsh -NoProfile -File scripts/test-llm-harness.ps1` (core + both
  behavioral shards) all green.
- `pwsh -NoProfile -File scripts/agent-check.ps1` green.
- Real-client verification: `claude mcp list` health-checks all seven
  servers green (github through the shim with the real PAT against
  GitHub's API, read-only default; context7 via local context7-mcp), and
  `codex mcp list` parses the generated managed block (6 stdio + the
  deepwiki remote, `env_vars` passthrough shown masked).
- Shim rename / read-only-default / no-token / unexpanded-literal paths
  verified against a stub binary and the real installed binary.
- Canary secrets asserted absent from every output stream, the whole
  sandbox tree, and the npm process environment across all seeder and
  installer cases.
