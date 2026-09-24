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

1. Push the addon and a tag with the right layout (done: see
   `addons/signal_fish/plugin.cfg`, `icon.png`, `README.md`, `LICENSE`).
2. Log in at <https://godotengine.org/asset-library/asset/new> (or
   `POST /asset`) and submit the first entry with the same field values as
   `.asset-template.json.hb` (category: **Scripts**, `godot_version` 4.3,
   `download_provider` GitHub, `download_commit` = the release tag).
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
| `download_commit` | `v0.1.0` style tag | `env.RELEASE_TAG` |
| `browse_url` / `issues_url` / `icon_url` | repo URLs | `context.repository` |
| `category_id` | `6` (Scripts) | pinned from `GET /configure?type=addon` |
| `godot_version` | `4.3` | minimum supported engine |

The tag is the store's `download_commit`: the Asset Library generates the
archive from that ref, so `.gitattributes` `export-ignore` keeps dev-only paths
out of what users download.

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
curl -sf -X POST "$BASE/asset/$ASSET_ID" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"version_string\":\"${TAG#v}\",\"godot_version\":\"4.3\",\"download_commit\":\"$TAG\"}"
curl -sf -X POST "$BASE/logout" -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}"
```

## Local verification

- `python scripts/validate-github-config.py --repo-root .` - workflow shape,
  pinned refs, permissions.
- The submit job itself only runs with real credentials; rehearse changes with
  the curl fallback against a scratch asset before touching the workflow.
