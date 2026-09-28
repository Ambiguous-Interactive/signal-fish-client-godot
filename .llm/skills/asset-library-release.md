---
description: Use when releasing to the Godot Asset Library, configuring its secrets, or changing the store submission automation or template.
triggers: asset library, asset store, publish, release, store submission, moderation, godot-asset-lib-action, asset-template, plugin.cfg, icon
category: Release
---

# Asset Library Release

How a `vMAJOR.MINOR.PATCH` tag updates the existing Godot Asset Library entry.

## Flow

1. Push a `vMAJOR.MINOR.PATCH` tag on `main`, or run the `Release` workflow
   (`workflow_dispatch`, input `version`).
2. `release` job: validate the tag, cut notes from `CHANGELOG.md`, check
   `addons/signal_fish/plugin.cfg` `version` matches (tag minus the `v`),
   package the addon zip, and publish the GitHub Release. Manual runs create
   the tag; pushed tags must point to a commit on `main`.
3. `publish-asset-store` job (needs `release`): submit an Asset Library edit
   via `deep-entertainment/godot-asset-lib-action` (pinned to commit SHA).

The submit step skips with a log line when credentials or the asset ID are not
configured.

## Existing entry and first release update

The live [entry #5489](https://godotengine.org/asset-library/asset/5489)
already points to this repository. It lists version `0.0.0`. The
[`v0.1.0` GitHub Release](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/releases/tag/v0.1.0)
points to `b4441936057628a71b730c3338f0183b4cdc03e2`. Update entry #5489;
do not create another entry.

1. Add repo secrets + var (Settings -> Secrets and variables -> Actions):
   - secret `GODOT_ASSET_LIBRARY_USERNAME`
   - secret `GODOT_ASSET_LIBRARY_PASSWORD`
   - var `GODOT_ASSET_LIBRARY_ASSET_ID` = `5489`
2. Rerun only the **Submit Asset Library edit** job in the
   [`v0.1.0` release workflow run](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/runs/36364292644).
3. Wait for moderation. Verify the live entry lists version `0.1.0`,
   category Scripts, Godot 4.3, and download commit
   `b4441936057628a71b730c3338f0183b4cdc03e2`.

Use an Asset Library password without quotes, backslashes, or control
characters: the action logs its render env, and GitHub's secret masking only
covers the plain value.

Later release runs submit store edits automatically.

## Template contract (`.asset-template.json.hb`)

Handlebars over the workflow webhook context plus process env:

| Field                                    | Value                   | Source                                  |
| ---------------------------------------- | ----------------------- | --------------------------------------- |
| `version_string`                         | `0.1.0` style           | `env.RELEASE_VERSION` (tag minus `v`)   |
| `download_commit`                        | full release commit SHA | `env.GITHUB_SHA`                        |
| `browse_url` / `issues_url` / `icon_url` | repo URLs               | `context.repository`                    |
| `category_id`                            | `6` (Scripts)           | pinned from `GET /configure?type=addon` |
| `godot_version`                          | `4.3`                   | minimum supported engine                |

The release workflow uses the tag's commit as `GITHUB_SHA`, which is the store's
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
