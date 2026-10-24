#!/usr/bin/env python3
"""Run release workflow checks and publication steps."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class ReleaseWorkflowError(Exception):
    pass


def required(environment: dict[str, str], name: str) -> str:
    value = environment.get(name)
    if not value:
        raise ReleaseWorkflowError(f"{name} is required")
    return value


def check_main(environment: dict[str, str]) -> None:
    sha = required(environment, "GITHUB_SHA")
    result = subprocess.run(  # noqa: S603
        ["git", "merge-base", "--is-ancestor", sha, "origin/main"],  # noqa: S607
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseWorkflowError("release tags must point to a commit on main")


def check_new_tag(environment: dict[str, str]) -> None:
    version = required(environment, "VERSION")
    result = subprocess.run(  # noqa: S603
        ["git", "ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/{version}"],  # noqa: S607
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        raise ReleaseWorkflowError(f"tag {version} already exists; pick the next version")
    if result.returncode != 2:
        raise ReleaseWorkflowError(f"could not query tags (git ls-remote exit {result.returncode})")


def publish(environment: dict[str, str]) -> None:
    version = required(environment, "VERSION")
    repo = required(environment, "GITHUB_REPOSITORY")
    sha = required(environment, "GITHUB_SHA")
    event = required(environment, "GITHUB_EVENT_NAME")
    if event not in ("push", "workflow_dispatch"):
        raise ReleaseWorkflowError(f"unsupported release event: {event}")
    releases = subprocess.run(  # noqa: S603
        ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    )
    matching = [
        release
        for page in json.loads(releases.stdout)
        for release in page
        if release["tag_name"] == version
    ]
    if matching:
        if len(matching) != 1 or not matching[0]["draft"]:
            raise ReleaseWorkflowError(f"release {version} already exists and is published")
        subprocess.run(  # noqa: S603
            [  # noqa: S607
                "gh",
                "release",
                "upload",
                version,
                "--repo",
                repo,
                f"signal-fish-godot-{version}.zip",
                "--clobber",
            ],
            check=True,
        )
        subprocess.run(  # noqa: S603
            [  # noqa: S607
                "gh",
                "release",
                "edit",
                version,
                "--repo",
                repo,
                "--target",
                sha,
                "--title",
                version,
                "--notes-file",
                "release-notes.md",
                "--draft=false",
                "--latest",
            ],
            check=True,
        )
        return
    target = ["--verify-tag"] if event == "push" else ["--target", sha]
    result = subprocess.run(  # noqa: S603
        [  # noqa: S607
            "gh",
            "release",
            "create",
            version,
            "--repo",
            repo,
            *target,
            "--title",
            version,
            "--notes-file",
            "release-notes.md",
            f"signal-fish-godot-{version}.zip",
        ],
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseWorkflowError(f"gh release create failed (exit {result.returncode})")


def asset_gate(environment: dict[str, str]) -> None:
    output = Path(required(environment, "GITHUB_OUTPUT"))
    if not all(environment.get(name) for name in ("ASSET_USERNAME", "ASSET_PASSWORD", "ASSET_ID")):
        print(
            "Asset Library credentials not configured; skipping the store submission "
            "(see .llm/skills/asset-library-release.md)."
        )
        with output.open("a", encoding="utf-8") as stream:
            stream.write("available=false\n")
        return
    version = required(environment, "VERSION")
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise ReleaseWorkflowError(
            "version must be a single vMAJOR.MINOR.PATCH token (e.g. v0.1.0)"
        )
    with output.open("a", encoding="utf-8") as stream:
        stream.write("available=true\n")
    with Path(required(environment, "GITHUB_ENV")).open("a", encoding="utf-8") as stream:
        stream.write(f"RELEASE_VERSION={version[1:]}\n")


class ReleaseWorkflowTests(unittest.TestCase):
    def test_main_check(self) -> None:
        for status in (0, 1, 128):
            with self.subTest(status=status), patch("subprocess.run") as run:
                run.return_value.returncode = status
                if status:
                    with self.assertRaisesRegex(ReleaseWorkflowError, "commit on main"):
                        check_main({"GITHUB_SHA": "abc"})
                else:
                    check_main({"GITHUB_SHA": "abc"})
                self.assertEqual(
                    run.call_args.args[0],
                    ["git", "merge-base", "--is-ancestor", "abc", "origin/main"],
                )

    def test_tag_query(self) -> None:
        for status, message in ((0, "already exists"), (2, None), (128, "could not query")):
            with self.subTest(status=status), patch("subprocess.run") as run:
                run.return_value.returncode = status
                if message:
                    with self.assertRaisesRegex(ReleaseWorkflowError, message):
                        check_new_tag({"VERSION": "v1.2.3"})
                else:
                    check_new_tag({"VERSION": "v1.2.3"})
                self.assertEqual(run.call_args.args[0][-1], "refs/tags/v1.2.3")

    def test_publish_flags_and_errors(self) -> None:
        base = {
            "VERSION": "v1.2.3",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "abc",
        }
        for event, expected in (
            ("push", ["--verify-tag"]),
            ("workflow_dispatch", ["--target", "abc"]),
        ):
            with self.subTest(event=event), patch("subprocess.run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = "[[]]"
                publish({**base, "GITHUB_EVENT_NAME": event})
                self.assertEqual(
                    run.call_args_list[0].args[0],
                    [
                        "gh",
                        "api",
                        "--paginate",
                        "--slurp",
                        "repos/owner/repo/releases?per_page=100",
                    ],
                )
                self.assertTrue(run.call_args_list[0].kwargs["check"])
                args = run.call_args.args[0]
                self.assertEqual(
                    args[:6], ["gh", "release", "create", "v1.2.3", "--repo", "owner/repo"]
                )
                self.assertEqual(args[6 : 6 + len(expected)], expected)
                self.assertEqual(args[-1], "signal-fish-godot-v1.2.3.zip")
                run.return_value.returncode = 1
                with self.assertRaisesRegex(ReleaseWorkflowError, "gh release create failed"):
                    publish({**base, "GITHUB_EVENT_NAME": event})

    def test_publish_matching_draft_after_upload(self) -> None:
        environment = {
            "VERSION": "v1.2.3",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "abc",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
        }
        with patch("subprocess.run") as run:
            run.return_value.stdout = json.dumps(
                [
                    [{"tag_name": "v1.2.4", "draft": True}],
                    [{"tag_name": "v1.2.3", "draft": True}],
                ]
            )
            publish(environment)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(len(commands), 3)
            self.assertEqual(commands[1][:4], ["gh", "release", "upload", "v1.2.3"])
            self.assertEqual(commands[2][:4], ["gh", "release", "edit", "v1.2.3"])
            self.assertIn("--draft=false", commands[2])
            self.assertIn("--notes-file", commands[2])
            self.assertEqual(commands[2][commands[2].index("--target") + 1], "abc")

    def test_publish_preserves_draft_on_upload_failure(self) -> None:
        environment = {
            "VERSION": "v1.2.3",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "abc",
            "GITHUB_EVENT_NAME": "push",
        }
        for published in (False, True):
            with self.subTest(published=published), patch("subprocess.run") as run:
                response = subprocess.CompletedProcess(
                    [], 0, stdout=json.dumps([[{"tag_name": "v1.2.3", "draft": not published}]])
                )
                run.side_effect = [response, subprocess.CalledProcessError(1, "upload")]
                expected = ReleaseWorkflowError if published else subprocess.CalledProcessError
                with self.assertRaises(expected):
                    publish(environment)
                self.assertEqual(run.call_count, 1 if published else 2)

    def test_publish_stops_when_release_lookup_fails(self) -> None:
        environment = {
            "VERSION": "v1.2.3",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "abc",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
        }
        with patch("subprocess.run") as run:
            run.side_effect = subprocess.CalledProcessError(1, "gh api")
            with self.assertRaises(subprocess.CalledProcessError):
                publish(environment)
            run.assert_called_once()

    def test_asset_gate(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "output"
            github_env = Path(folder) / "env"
            base = {
                "VERSION": "v1.2.3",
                "GITHUB_OUTPUT": str(output),
                "GITHUB_ENV": str(github_env),
                "ASSET_USERNAME": "user",
                "ASSET_PASSWORD": "secret",
                "ASSET_ID": "123",
            }
            for absent in ("ASSET_USERNAME", "ASSET_PASSWORD", "ASSET_ID"):
                with self.subTest(absent=absent):
                    asset_gate({**base, absent: ""})
                    self.assertEqual(output.read_text(), "available=false\n")
                    output.unlink()
            with self.assertRaisesRegex(ReleaseWorkflowError, "version must"):
                asset_gate({**base, "VERSION": "v1.2.3\nBAD=1"})
            self.assertFalse(output.exists())
            asset_gate(base)
            self.assertEqual(output.read_text(), "available=true\n")
            self.assertEqual(github_env.read_text(), "RELEASE_VERSION=1.2.3\n")
            self.assertNotIn("secret", output.read_text() + github_env.read_text())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("check-main", "check-new-tag", "publish", "asset-gate", "self-test")
    )
    command = parser.parse_args().command
    if command == "self-test":
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseWorkflowTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    actions = {
        "check-main": check_main,
        "check-new-tag": check_new_tag,
        "publish": publish,
        "asset-gate": asset_gate,
    }
    try:
        actions[command](dict(os.environ))
    except (OSError, subprocess.CalledProcessError, ValueError, ReleaseWorkflowError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
