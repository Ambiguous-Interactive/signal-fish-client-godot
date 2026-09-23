---
description: "Runbook for publishing the addon to the Godot Asset Library: one-time first submission, secrets setup, and every release after that."
---

# Release Operations (Godot Asset Library)

This runbook takes the addon from "not on the store" to "every tag auto-submits
a store update". The Asset Library is moderated by humans, so one step is
manual. Everything after that is automated by CI.

## What you need

- A [Godot Asset Library](https://godotengine.org/asset-library) account
  (your forum login works).
- Admin access to this repository (to add secrets and run workflows).
- A merged `vMAJOR.MINOR.PATCH` section in [`CHANGELOG.md`](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/main/CHANGELOG.md).

## One-time: first submission (manual)

The first store entry must be submitted by hand. Moderators review it before
it goes live. Later updates are submitted automatically, but each one also
waits in the moderation queue (see *After release* below).

1. Log in at the
   [Asset Library](https://godotengine.org/asset-library/asset) and open
   **Submit a resource**.
2. Fill in the form with these values (they mirror the automated template):

   | Field | Value |
   |---|---|
   | Title | `Signal Fish Client` |
   | Category | Scripts |
   | Godot version | `4.3` |
   | Version | the release tag without the leading `v` (e.g. `0.1.0`) |
   | License | MIT |
   | Download provider | GitHub |
   | Repository URL | `https://github.com/Ambiguous-Interactive/signal-fish-client-godot` |
   | Issues URL | repository URL + `/issues` |
   | Icon URL | `https://raw.githubusercontent.com/Ambiguous-Interactive/signal-fish-client-godot/main/docs/assets/icon-256.png` |
   | Download commit | the release tag (e.g. `v0.1.0`) |

3. Submit, then wait for moderation.
4. When the entry is live, note its numeric **asset ID** from the entry URL.

## One-time: configure repository secrets

In **Settings → Secrets and variables → Actions**, add:

- Secret `GODOT_ASSET_LIBRARY_USERNAME` — your Asset Library username.
- Secret `GODOT_ASSET_LIBRARY_PASSWORD` — your Asset Library password.
  Use a password without quotes, backslashes, or control characters.
- Variable `GODOT_ASSET_LIBRARY_ASSET_ID` — the numeric asset ID from above.

## Every release (automated)

1. Make sure `CHANGELOG.md` has a section for the new version and
   `addons/signal_fish/plugin.cfg` `version` matches it (without the `v`).
2. On GitHub, run the **Release** workflow
   ([Actions → Release → Run workflow](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/workflows/release.yml))
   with the version, e.g. `v0.1.0`.
3. The workflow:
   - validates the tag format,
   - cuts release notes from the matching `CHANGELOG.md` section,
   - packages the addon zip and publishes the GitHub Release,
   - submits a store edit with the new version and tag.

No secrets configured? The store step skips with a log line and the GitHub
Release still publishes.

## After release: moderation

Every store submission creates a **pending** edit that a moderator must
accept. A green workflow run means "submitted", not "live". Check your entry
at the [Asset Library](https://godotengine.org/asset-library/asset) after each
release.

## Troubleshooting

- **Store step skipped.** A secret or the asset ID variable is missing. Check
  the names above — they must match exactly.
- **Submission failed.** The action logs its render env, so a leaked password
  is possible with exotic characters; see the password rule above.
- **Manual fallback.** Submit the edit by hand with the form values from the
  first-submission table, or use the curl flow documented in
  `.llm/skills/asset-library-release.md`.
