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

## Validation

- `pwsh -NoProfile -File scripts/test-llm-harness.ps1` (core + both
  behavioral shards) all green.
- `pwsh -NoProfile -File scripts/agent-check.ps1` green.
- Real-client verification of the generated Codex TOML via `codex mcp
  list` (5 stdio + 2 HTTP servers, bearer auth detected) and `claude mcp
  list` (hybrid schema parsed, servers listed pending approval).
- Shim rename/read-only/failure paths verified against a stub binary.
- Canary secrets asserted absent from every output stream and written
  file across all seeder cases.
