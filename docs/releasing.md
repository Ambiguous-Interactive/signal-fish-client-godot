---
description: "Runbook for updating the existing Godot Asset Library entry and publishing later releases."
---

# Release Operations (Godot Asset Library)

The addon already has [Asset Library entry #5489](https://godotengine.org/asset-library/asset/5489).
Configure the repository settings once to submit edits from release tags.
Each store edit waits for moderation.

## What you need

- A [Godot Asset Library](https://godotengine.org/asset-library) account
  (your forum login works).
- Admin access to this repository (to add secrets and run workflows).
- A merged `vMAJOR.MINOR.PATCH` section in [`CHANGELOG.md`](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/main/CHANGELOG.md).

## `v0.1.1` listing

Entry #5489 points to this repository. Edit #24491 was submitted on
October 1, 2026, and the `v0.1.1` listing went live on October 2.
Use this entry for later releases.

The [`v0.1.1` GitHub Release](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/releases/tag/v0.1.1)
is published. Its tag points to
`5a0b00d3e78edac16e41f2bff978b500eeb2c4d6`.

The live entry has these values:

| Field             | Value                                                                                                            |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| Title             | `Signal Fish Client`                                                                                             |
| Category          | Scripts                                                                                                          |
| Godot version     | `4.3`                                                                                                            |
| Version           | `0.1.1`                                                                                                          |
| License           | MIT                                                                                                              |
| Download provider | GitHub                                                                                                           |
| Repository URL    | `https://github.com/Ambiguous-Interactive/signal-fish-client-godot`                                              |
| Issues URL        | repository URL + `/issues`                                                                                       |
| Icon URL          | `https://raw.githubusercontent.com/Ambiguous-Interactive/signal-fish-client-godot/main/docs/assets/icon-256.png` |
| Download commit   | `5a0b00d3e78edac16e41f2bff978b500eeb2c4d6`                                                                       |

The live download contains only `addons/` and loads in Godot 4.3. The
[release workflow run](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/runs/36928406066)
contains the submission job and its logs.

## Repository settings

In **Settings -> Secrets and variables -> Actions**, set:

- Secret `GODOT_ASSET_LIBRARY_USERNAME` - your Asset Library username.
- Secret `GODOT_ASSET_LIBRARY_PASSWORD` - your Asset Library password.
  Use a password without quotes, backslashes, or control characters.
- Variable `GODOT_ASSET_LIBRARY_ASSET_ID` - `5489`.

## Every release (automated)

1. Make sure `CHANGELOG.md` has a section for the new version and
   `addons/signal_fish/plugin.cfg` `version` matches it (without the `v`).
2. Push a `vMAJOR.MINOR.PATCH` tag on a commit in `main`, or run the **Release**
   workflow
   ([Actions -> Release -> Run workflow](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/workflows/release.yml))
   with the version, e.g. `v0.1.0`.
3. The workflow:
   - validates the tag format,
   - cuts release notes from the matching `CHANGELOG.md` section,
   - packages the addon zip and publishes the GitHub Release,
   - submits a store edit with the new version and tag.

Both downloads contain only `addons/`. Demo scenes and the full docs remain in
the source repository.

No secrets configured? The store step skips with a log line and the GitHub
Release still publishes.

## After release: moderation

Every store submission creates a **pending** edit that a moderator must
accept. A green workflow run means "submitted", not "live". Check your entry
at the [Asset Library](https://godotengine.org/asset-library/asset) after each
release.

## Troubleshooting

- **Store step skipped.** A secret or the asset ID variable is missing. Check
  the names above - they must match exactly.
- **Submission failed.** The action logs its render env, so a leaked password
  is possible with exotic characters; see the password rule above.
- **Manual fallback.** Edit entry #5489 by hand with the field values above,
  or use the curl flow documented in
  `.llm/skills/asset-library-release.md`.
