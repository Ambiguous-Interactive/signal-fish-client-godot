# Session 147: Asset Library entry verified, #194 closed

Branch: `session-147-asset-entry-verified` from `origin/main` at `f241b0b`.
Closes #194. Repo settings landed in earlier sessions; this session verified
the live chain end to end and recorded the evidence.

- Release evidence ([run 36364292644](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/runs/36364292644),
  tag `v0.1.0`): the Asset Library gate resolved credentials and submitted
  edit `24434` to entry `5489` with `download_commit b4441936` (the full SHA
  behind the tag). The run stayed green. This proves the credential secrets
  and the `GODOT_ASSET_LIBRARY_ASSET_ID = 5489` variable resolve in the
  workflow (org-level secrets; the repo secret list is empty by design).
- Live entry: <https://godotengine.org/asset-library/asset/5489> serves
  version `0.1.0`, Godot `4.3`, and the tag commit SHA. The page shows the
  submitted fields, so moderation applied the edit.
- Download check: the archive at `b4441936` holds only `addons/signal_fish/`
  (25 files); the export-ignore allow list works as pinned.
- Godot 4.3 headless against that downloaded copy: editor boots with the
  plugin enabled, all 20 addon scripts load, and `SignalFishClient`
  instantiates and reports 44 signals.
- Local checks: `python3 scripts/check-docs-style.py` green. Main CI green at
  session start (`f241b0b`). No open PRs; no unmerged session work.

Issue status at session end: #194 closed with evidence; #234 still waits for
the next live Dependabot merge (weekly schedule, Monday 03:00
America/Los_Angeles); #161 campaign tracked in
`.llm/research/hot-path-audit.md`.
