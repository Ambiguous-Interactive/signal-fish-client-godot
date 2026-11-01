# Storage policy

Keep the current tools. Bound generated data and reusable caches.

## Container scratch

The WebRTC interop and reference runners use `/tmp/signal-fish-scratch` when
`--output` is omitted. Set `SF_SCRATCH_ROOT` to change the runner root.
Completed runs expire after seven days. The managed budget is 10 GiB.
Oldest completed runs lose copied projects first. Up to 1 MiB of summaries
and log tails per run stays in `evidence/` for seven more days. Evidence also
counts toward the budget and is removed if the budget still exceeds 10 GiB.
Active runs and `.keep` pins are protected and can exceed the budget.
Failed runs follow the same retention rules. Interrupted runs become eligible
when their process releases its lock. Explicit `--output` paths stay unmanaged.

```bash
python3 scripts/storage.py --json clean --dry-run
python3 scripts/storage.py clean --apply
python3 scripts/storage.py pin run-NAME
python3 scripts/storage.py unpin run-NAME
python3 scripts/check-webrtc-interop.py --keep-artifacts
```

Pass `--root PATH` to maintenance commands for a custom root. Start and finish
agent experiments through `storage.managed_output` so they share this policy.
At task completion, keep reproduction commands and compact results in the
local progress note. Avoid new unmanaged `/tmp/session*` trees.
Cleanup runs before and after managed experiments and at container startup.
Startup allows three seconds and warns on failure. It does not install tools
or clean shared caches. Run `clean --apply` manually if startup defers cleanup.

## Baseline and legacy recovery

The November 1, 2026 planning snapshot measured 113.5 GiB in `/tmp`, including
109.6 GiB of session trees. Of that session data, 91.1 GiB was modified within
seven days. The shared VS Code volume held 38.5 GiB: 24.3 GiB of extension
archives and 14.2 GiB of server binaries. Docker storage had 1.4 GiB available.
These are observations from one host. They are not image size budgets.

```bash
python3 scripts/storage.py --json report /tmp /home/vscode /vscode
python3 scripts/storage.py --json legacy > /tmp/storage-legacy.json
python3 scripts/storage.py --json server-cache
git worktree list --porcelain
```

The legacy inventory is report-only. Review exact paths, active processes,
worktree registrations, and evidence before selecting any deletion. Use
`git worktree remove PATH` for a reviewed obsolete worktree. Never delete
session directories by a broad wildcard. No legacy data is automatically
adopted or deleted by the new policy.

Report values are allocated file bytes. Shared image layers, mount totals,
and nested paths overlap. Do not sum them. A scan error is an attribution
gap; do not interpret it as zero usage.

## Explicit host maintenance

Run from a host PowerShell 7 terminal with Docker available:

```powershell
./.devcontainer/storage-host.ps1 -AsJson > storage-host-before.json
./.devcontainer/storage-host.ps1 -Action PruneBuildCache -WhatIf
./.devcontainer/storage-host.ps1 -Action PruneBuildCache
```

Use `-Builder NAME` to select a builder. Pruning requires buildx support for
`--max-used-space` and uses a 10 GB target. In-use/shared records can prevent
reaching the target. The report includes versions, context, builder, writable
container sizes, object usage, volume consumers, host free space, and Windows
VHDX file length and allocated bytes. Supply `-VhdPath PATH` when Docker stores
its disk outside the default directory. Missing tools remain explicit gaps.

After closing all VS Code sessions sharing the volume and stopping other
containers, the following command keeps up to 2 GiB of newest extension
downloads. Keep one target container running to execute the helper. Start it
from the host if needed. Supply its exact ID and the helper path in that
container. All maintenance actions support `-WhatIf`.

```powershell
./.devcontainer/storage-host.ps1 -Action CleanExtensions `
  -ContainerId CONTAINER_ID -SessionsClosed -WhatIf
```

Remove `-WhatIf` to apply. Server binaries remain report-only. `server-cache` lists sizes and local
references; `storage-host.ps1 -ContainerId ID` includes this inventory. Retain the
newest two versions per architecture plus all versions referenced by any
container. This helper cannot prove references in stopped containers, so it
does not delete server versions. Remove an obsolete project container or
image only by its reviewed ID with `-Action RemoveContainer` or
`-Action RemoveImage -ResourceId ID`. Removal never uses force or deletes
volumes. History, credentials, and agent sessions remain outside cleanup.

CI records image, container, and host measurements for both architectures.
The initial final-image guard is 8 GiB uncompressed. It excludes writable
container data, volumes, and build cache; review this budget against the
first successful CI measurements.

## Persistent builder policy and host reclamation

For the `docker` builder driver, merge `BUILD-GC.json` into the existing
Docker Desktop **Settings > Docker Engine** JSON and apply. Preserve other
settings. For a `docker-container` builder, merge `buildkit-storage.toml`
into its BuildKit configuration and recreate that named builder with
`docker buildx create --buildkitd-config PATH`. Record its existing settings
first and preserve them. Verify the actual policy with `docker buildx inspect`.
These are explicit host configuration steps; container startup cannot change
the host daemon. GC runs periodically and manages build cache only.

Docker Desktop uses a managed VHDX on newer installations. Supported versions
can reclaim host allocation when Desktop quits. Inspect the installed version
and WSL layout before choosing a reclamation procedure. For older layouts,
close Docker and WSL consumers before following Microsoft's offline VHDX
compaction instructions. Do not zero-fill a nearly full disk or change the
storage backend as a cleanup step.

Capture another host report after deletion and after reclamation. Linux free
space and Windows allocated bytes are separate success measures. During the
next seven days, capture one daily report and compare scratch usage, protected
bytes, builder cache, and host allocation. Fresh/warm image rebuilds require
host Docker and should retain tool and browser readiness on both architectures.

References:

- [BuildKit GC](https://docs.docker.com/build/cache/garbage-collection/)
- [Builder cache pruning](https://docs.docker.com/reference/cli/docker/buildx/prune/)
- [Docker Desktop reclamation](https://www.docker.com/blog/docker-desktop-4-34/)
- [Microsoft VHDX compaction](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/compact-vdisk)
