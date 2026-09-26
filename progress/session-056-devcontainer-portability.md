# Dev container portability

## Cause

The supplied September 26 log stops at `17:11:24.942Z` with host `sh`
missing from PATH. `initializeCommand` runs on the host before image build.
The Windows ARM64 Docker engine was healthy. Creating `.env.local` manually
could not bypass the unconditional shell launch.

Agent installs also ran after image build. Every start could run npm and pip
installs. The five-second npm probe timeout did not bound package installs.
Warn-only error handling still waited for each installer to finish.

## Changes

- Run env bootstrap through Docker's Linux shell, with no host shell needed.
- Preserve existing env files and handle paths as command arguments.
- Install Node LTS, agents, npm MCP servers, and Chromium in the image.
- Revalidate remote npm release metadata so cached builds see agent releases.
- Verify agents offline at create time. Make restart maintenance opt-in.
- Keep npm packages under HOME for Linux UID remapping.
- Remove 23 optional theme and icon extensions from automatic setup.
- Add native ARM64 and x86-64 container CI.

Godot and MCP servers retain their tested project versions. The agent CLIs
track latest. Rebuilds require network access; ordinary restarts do not.

## Evidence

- Three regression checks failed before the change and passed after it.
- Four checks passed with Docker enabled on Windows ARM64, including fresh
  env setup, missing-template failure, existing-file preservation, quote and
  space paths, and offline restart.
- Offline restart took 3.02 seconds including Docker launch.
- All 119 repository harness tests passed.
- The initial ARM64 image build succeeded. Codex 0.157.1, OpenCode 2.0.18,
  Nanocoder 1.30.0, and Claude Code 2.1.283 matched registry latest values.
- All four agents passed strict verification with container networking off.
- Removing Codex from a disposable container made offline verification fail.
- Full Dev Containers create and lifecycle commands passed on Windows ARM64.
- A warm Dev Containers build took 21.29 seconds. The agent install layer
  was cached. Cache-backed agent installation took 36.5 seconds when rebuilt,
  compared with 145.1 seconds in the initial build.
- [Native CI](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/runs/36259125326)
  passed on Linux ARM64 and x86-64, including image build, create, tool checks,
  and restart. Complete jobs took 3m57s and 4m01s. Offline startup checks took
  0.12s and 0.13s including Docker launch. These checks exclude VS Code UI
  and extension installation time.
- Local x86 execution failed with `exec format error`; this Docker host has
  no x86 emulation. Native CI passed on that architecture. macOS hosts were
  not tested directly.

## References

- [Lifecycle command placement](https://containers.dev/implementors/json_reference/)
- [Docker cache invalidation](https://docs.docker.com/build/cache/invalidation/)
- [Native GitHub runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
