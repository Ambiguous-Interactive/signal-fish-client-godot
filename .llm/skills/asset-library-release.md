---
description: Use when releasing to the Godot Asset Library, configuring its secrets, or changing the store submission automation or template.
triggers: asset library, asset store, publish, release, store submission, moderation, godot-asset-lib-action, asset-template, plugin.cfg, icon
category: Release
---

# Asset Library Release

How a `vMAJOR.MINOR.PATCH` tag reaches the Godot Asset Library, and the one-time
manual bootstrap before that flow works.

## Flow

1. Run the `Release` workflow (`workflow_dispatch`, input `version`).
2. `release` job: validate the tag, cut notes from `CHANGELOG.md`, check
   `addons/signal_fish/plugin.cfg` `version` matches (tag minus the `v`),
   package the addon zip, create the tag + GitHub Release.
3. `publish-asset-store` job (needs `release`): submit an Asset Library edit
   via `deep-entertainment/godot-asset-lib-action` (pinned to commit SHA).

The submit step skips with a log line when credentials or the asset ID are not
configured, so releases stay usable before the one-time bootstrap.

## One-time manual bootstrap (cannot be automated)

1. Publish the first GitHub Release with the `Release` workflow. It creates
   the tag. Check the package layout in
   `addons/signal_fish/plugin.cfg`, `icon.png`, `README.md`, and `LICENSE`.
2. Log in at <https://godotengine.org/asset-library/asset/submit> (or
   `POST /asset`) and submit the first entry with the same field values as
   `.asset-template.json.hb` (category: **Scripts**, `godot_version` 4.3,
   `download_provider` GitHub, `download_commit` = the full SHA behind the
   release tag). The live form requires 40 or 64 hexadecimal digits.
3. Wait for moderation. Record the numeric asset ID.
4. Add repo secrets + var (Settings -> Secrets and variables -> Actions):
   - secret `GODOT_ASSET_LIBRARY_USERNAME`
   - secret `GODOT_ASSET_LIBRARY_PASSWORD`
   - var `GODOT_ASSET_LIBRARY_ASSET_ID`

Use an Asset Library password without quotes, backslashes, or control
characters: the action logs its render env, and GitHub's secret masking only
covers the plain value.

After this, every release run submits a store edit automatically.

## Template contract (`.asset-template.json.hb`)

Handlebars over the workflow-dispatch webhook context plus process env:

| Field | Value | Source |
|---|---|---|
| `version_string` | `0.1.0` style | `env.RELEASE_VERSION` (tag minus `v`) |
| `download_commit` | full release commit SHA | `env.GITHUB_SHA` |
| `browse_url` / `issues_url` / `icon_url` | repo URLs | `context.repository` |
| `category_id` | `6` (Scripts) | pinned from `GET /configure?type=addon` |
| `godot_version` | `4.3` | minimum supported engine |

The release workflow tags `GITHUB_SHA`, which is the store's
`download_commit`: the Asset Library generates the archive from that commit.
`.gitattributes` keeps only `addons/` in that download;
the addon-local README and LICENSE travel with the plugin. The GitHub Release
ZIP also contains only `addons/`. `scripts/check-asset-archive.py` checks every
shipped file against a reviewed manifest. Update it when changing addon files.

## Pending-edit semantics

Every automated submission creates a **pending** edit a moderator must accept.
A green submit step means "submitted", never "live". Check
<https://godotengine.org/asset-library/asset> after each release.

## Action pin

`deep-entertainment/godot-asset-lib-action@056fa4060f062a8b209a5a6744a2726ad48d6bb0`
(v0.6.0). Upgrade deliberately; third-party actions stay SHA-pinned in this
repo. Inputs: `action` (default `addEdit`), `username`, `password`, `assetId`,
`assetTemplate`, optional `approveDirectly` (do not use; we are not moderators).

## Curl fallback

```bash
BASE=https://godotengine.org/asset-library/api
TOKEN=$(curl -sf -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$GODOT_AL_USER\",\"password\":\"$GODOT_AL_PASS\"}" | jq -r .token)
SHA=$(git rev-list -n 1 "$TAG")
curl -sf -X POST "$BASE/asset/$ASSET_ID" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"version_string\":\"${TAG#v}\",\"godot_version\":\"4.3\",\"download_commit\":\"$SHA\"}"
curl -sf -X POST "$BASE/logout" -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}"
```

## Local verification

- `python3 scripts/check-asset-archive.py --worktree` - check current files
  with an isolated index before commit; CI and release check the committed ref.
- `python scripts/validate-github-config.py --repo-root .` - workflow shape,
  pinned refs, permissions.
- The submit job itself only runs with real credentials; rehearse changes with
  the curl fallback against a scratch asset before touching the workflow.
