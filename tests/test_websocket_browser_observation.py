"""Keep observed Web callbacks distinct from proven engine rejections and reads."""

import copy
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import cast
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-websocket-web-receive.py"
SPEC = importlib.util.spec_from_file_location("websocket_receive", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
drill = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drill)


class ReceiveEvidenceTests(unittest.TestCase):
    def fixture(self) -> tuple[dict[str, object], dict[str, object], list[dict[str, object]]]:
        callbacks = [
            {"connection": 1, "ordinal": n + 1, "bytes": 4096, "prefix": f"{n:08d}"}
            for n in range(65)
        ]
        trace: dict[str, object] = {
            "sockets": [{"connection": 1, "received": 65, "omitted": 0, "callbacks": callbacks}],
            "rejections": [],
            "omitted": 0,
        }
        return (
            trace,
            {"received": list(range(65))},
            [{"start": 0, "count": 64}, {"start": 64, "count": 1}],
        )

    def test_exact_finite_delivery_requires_complete_trace_and_server_offer(self) -> None:
        trace, result, commands = self.fixture()
        evidence = drill.receive_evidence(trace, result, commands)
        self.assertTrue(evidence["trace_complete"])
        self.assertTrue(evidence["reliable_delivery"])
        self.assertEqual(evidence["rejected_sequences"], [])
        self.assertFalse(drill.receive_evidence(trace, result, commands[:1])["reliable_delivery"])
        for received in (list(range(64)), [0] * 65, list(reversed(range(65)))):
            with self.subTest(received=received):
                self.assertFalse(
                    drill.receive_evidence(trace, {"received": received}, commands)[
                        "reliable_delivery"
                    ]
                )

    def test_scoped_rejection_is_separate_from_unread_callbacks(self) -> None:
        trace, result, commands = self.fixture()
        socket = cast(list[dict[str, object]], trace["sockets"])[0]
        callbacks = cast(list[dict[str, object]], socket["callbacks"])
        trace["rejections"] = [{"callback_scope": "engine_onmessage", "callback": callbacks[15]}]
        result["received"] = [n for n in range(65) if n not in (15, 16)]
        evidence = drill.receive_evidence(trace, result, commands)
        self.assertTrue(evidence["trace_complete"])
        self.assertFalse(evidence["reliable_delivery"])
        self.assertEqual(evidence["rejected_sequences"], [15])
        self.assertEqual(evidence["callback_not_read_sequences"], [15, 16])
        self.assertEqual(evidence["unresolved_callback_sequences"], [16])

    def test_incomplete_or_ambiguous_observations_cannot_qualify(self) -> None:
        for fault in (
            "omitted",
            "socket_omitted",
            "missing_socket",
            "missing_callback",
            "wrong_bytes",
            "wrong_ordinal",
            "wrong_connection",
            "unscoped",
            "unmatched",
            "duplicate",
            "read_rejection",
        ):
            with self.subTest(fault=fault):
                trace, result, commands = self.fixture()
                socket = cast(list[dict[str, object]], trace["sockets"])[0]
                callbacks = cast(list[dict[str, object]], socket["callbacks"])
                drop = {"callback_scope": "engine_onmessage", "callback": callbacks[15]}
                if fault == "omitted":
                    trace["omitted"] = 1
                elif fault == "socket_omitted":
                    socket["omitted"] = 1
                elif fault == "missing_socket":
                    trace["sockets"] = []
                elif fault == "missing_callback":
                    callbacks.pop()
                elif fault.startswith("wrong_"):
                    callbacks[0][fault.removeprefix("wrong_")] = 9000
                elif fault == "unscoped":
                    trace["rejections"] = [{"callback_scope": None, "callback": None}]
                elif fault == "unmatched":
                    changed = copy.deepcopy(callbacks[15])
                    changed["prefix"] = "99999999"
                    trace["rejections"] = [
                        {"callback_scope": "engine_onmessage", "callback": changed}
                    ]
                elif fault == "duplicate":
                    trace["rejections"] = [drop, copy.deepcopy(drop)]
                else:
                    trace["rejections"] = [drop]
                evidence = drill.receive_evidence(trace, result, commands)
                self.assertFalse(evidence["trace_complete"])
                self.assertFalse(evidence["reliable_delivery"])


class ApplicationCreditTests(unittest.TestCase):
    def test_credit_counts_complete_messages_and_requires_actual_receipts(self) -> None:
        credit = drill.ApplicationCredit(8 * 4096 + 4095)
        self.assertEqual(list(credit.receive("start")), list(range(8)))
        self.assertEqual(list(credit.receive("ack:3")), list(range(8, 11)))
        self.assertEqual(credit.sent - credit.acknowledged, 8)
        self.assertEqual(list(credit.receive("ack:11")), list(range(11, 19)))

    def test_sentinel_waits_for_complete_prefix_even_with_spare_credit(self) -> None:
        credit = drill.ApplicationCredit(128 * 4096)
        self.assertEqual(list(credit.receive("start")), list(range(64)))
        self.assertEqual(list(credit.receive("ack:63")), [])
        self.assertEqual(list(credit.receive("ack:64")), [64])

    def test_stale_future_and_malformed_receipts_never_release_credit(self) -> None:
        for command in ("ack:0", "ack:9", "ack:-1", "ack:1.0", "ack: 1", "ack:\u0661", "start"):
            with self.subTest(command=command):
                credit = drill.ApplicationCredit(8 * 4096)
                credit.receive("start")
                with self.assertRaises(ValueError):
                    credit.receive(command)
                self.assertEqual((credit.sent, credit.acknowledged), (8, 0))
        credit = drill.ApplicationCredit(8 * 4096)
        with self.assertRaises(ValueError):
            credit.receive("ack:1")
        credit.receive("start")
        credit.receive("ack:1")
        with self.assertRaises(ValueError):
            credit.receive("ack:1")


class BrowserFailureTests(unittest.TestCase):
    def test_snapshot_failure_preserves_run_failure_and_always_closes_browser(self) -> None:
        for primary in ("navigation", "timeout", "crash", "snapshot_only"):
            with self.subTest(primary=primary), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "attempt"
                page = Mock()
                page.evaluate.side_effect = RuntimeError("snapshot context lost")
                browser = Mock(version="test browser")
                browser.new_page.return_value = page
                playwright = Mock()
                playwright.chromium.launch.return_value = browser
                context = Mock()
                context.__enter__ = Mock(return_value=playwright)
                context.__exit__ = Mock(return_value=False)
                expected_error = None
                if primary == "navigation":
                    page.goto.side_effect = RuntimeError("navigation context lost")
                    expected_error = "RuntimeError: navigation context lost"
                elif primary == "timeout":
                    expected_error = "RuntimeError: Web finite burst did not finish"
                elif primary == "crash":
                    page.wait_for_timeout.side_effect = RuntimeError("page crashed")
                    expected_error = "RuntimeError: page crashed"
                else:

                    def complete(_url: str, observed_page: Mock = page) -> None:
                        for call in observed_page.on.call_args_list:
                            if call.args[0] == "console":
                                call.args[1](
                                    Mock(
                                        type="log",
                                        text='WEBSOCKET_WEB_RESULT {"passed":true,"received":[]}',
                                    )
                                )

                    page.goto.side_effect = complete
                clock = iter((0.0, 1000.0)) if primary == "timeout" else None
                with (
                    patch.object(
                        sys,
                        "argv",
                        [str(SCRIPT), "--godot", sys.executable, "--output", str(output)],
                    ),
                    patch.object(
                        drill, "ThreadingHTTPServer", return_value=Mock(server_port=12345)
                    ) as server,
                    patch.object(drill.threading, "Thread") as thread,
                    patch.object(drill.subprocess, "run"),
                    patch.object(drill.time, "monotonic", side_effect=clock, return_value=0.0),
                    patch("playwright.sync_api.sync_playwright", return_value=context),
                    redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(drill.main(), 1)
                report = json.loads((output / "assessment.json").read_text())
                self.assertIs(report["passed"], False)
                self.assertEqual(report.get("error"), expected_error)
                self.assertEqual(
                    report["receive_trace_error"], "RuntimeError: snapshot context lost"
                )
                self.assertEqual(report["receive_trace"], {})
                browser.close.assert_called_once_with()
                server.return_value.shutdown.assert_called_once_with()
                server.return_value.server_close.assert_called_once_with()
                thread.return_value.join.assert_called_once_with(timeout=5)
                if primary == "snapshot_only":
                    self.assertNotIn("error", report)
                    self.assertIs(report["results"][0]["passed"], True)
                    self.assertIs(report["receive_evidence"]["trace_complete"], False)


class BackportApplicatorTests(unittest.TestCase):
    @unittest.skipUnless(
        os.environ.get("SF_WEBSOCKET_GODOT_44_SOURCE")
        and os.environ.get("SF_WEBSOCKET_GODOT_47_SOURCE"),
        "requires local pinned Godot 4.4.1 and 4.7.2 source checkouts",
    )
    def test_bundled_patches_apply_to_pinned_sources(self) -> None:
        modules = []
        for name in ("repair-websocket-stable", "backport-websocket-43"):
            spec = importlib.util.spec_from_file_location(name, SCRIPT.parent / (name + ".py"))
            if spec is None or spec.loader is None:
                raise RuntimeError(f"Could not load {name}")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            modules.append(module)
        stable, backport = modules
        with tempfile.TemporaryDirectory() as directory:
            for version, base in (
                ("44", "49a5bc7b616bd04689a2c89e89bda41f50241464"),
                ("47", "ed1daf0bf001b61586d9930840f2f1394092c079"),
            ):
                with self.subTest(version=version):
                    source = Path(os.environ["SF_WEBSOCKET_GODOT_" + version + "_SOURCE"]).resolve()
                    fixture = Path(directory) / version
                    commands = [
                        (
                            source,
                            (
                                "clone",
                                "--quiet",
                                "--shared",
                                "--no-checkout",
                                str(source),
                                str(fixture),
                            ),
                        ),
                        (fixture, ("reset", "--quiet")),
                        (
                            fixture,
                            (
                                "checkout",
                                "--",
                                "modules/websocket/wsl_peer.cpp",
                                "modules/websocket/wsl_peer.h",
                            ),
                        ),
                    ]
                    for repository, arguments in commands:
                        result = backport.git(repository, *arguments)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    checked = stable.apply(fixture, True)
                    self.assertEqual(checked["base"], base)
                    self.assertEqual(checked["status"], "applicable")
                    self.assertEqual(stable.apply(fixture, False)["status"], "applied")
                    self.assertEqual(stable.apply(fixture, False)["status"], "already_applied")

    def test_stable_repair_selects_the_exact_revision_patch(self) -> None:
        script = SCRIPT.parent / "repair-websocket-stable.py"
        spec = importlib.util.spec_from_file_location("websocket_stable", script)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Could not load {script}")
        stable = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stable)
        source_blobs = {
            "49a5bc7b616bd04689a2c89e89bda41f50241464": "1a1f52a8a06b5867fc1c14e416f78f2a14fa908f",
            "ed1daf0bf001b61586d9930840f2f1394092c079": "ae3e34fc42aa1c6458c80673216727bb36a70f92",
        }
        for revision, blob in source_blobs.items():
            with self.subTest(source_revision=revision):
                bundled = script.parent / "patches" / stable.PATCHES[revision]
                self.assertIn("index " + blob + "..", bundled.read_text())
        backport_spec = importlib.util.spec_from_file_location(
            "websocket_stable_git", SCRIPT.parent / "backport-websocket-43.py"
        )
        if backport_spec is None or backport_spec.loader is None:
            raise RuntimeError("Could not load backport applicator")
        backport = importlib.util.module_from_spec(backport_spec)
        backport_spec.loader.exec_module(backport)
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            fixtures = []
            patches = {}

            def git(source: Path, *args: str) -> str:
                result = backport.git(source, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                return cast(str, result.stdout)

            for version in ("4.4.1", "4.7.2"):
                source = parent / version
                source.mkdir()
                git(source, "init", "--quiet")
                original = version + "\nbefore\n"
                path = source / "peer.cpp"
                path.write_text(original)

                git(source, "add", "peer.cpp")
                git(
                    source,
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.com",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    version,
                )
                revision = git(source, "rev-parse", "HEAD").strip()
                changed = original.replace("before", "after")
                path.write_text(changed)
                patch_file = parent / (version + ".patch")
                patch_file.write_text(git(source, "diff", "--full-index"))
                git(source, "checkout", "--", "peer.cpp")
                patches[revision] = str(patch_file)
                fixtures.append((source, path, original, changed, revision))
            with patch.object(stable, "PATCHES", patches):
                for source, path, original, changed, revision in fixtures:
                    with self.subTest(revision=revision):
                        self.assertEqual(stable.apply(source, True)["status"], "applicable")
                        self.assertEqual(path.read_text(), original)
                        result = stable.apply(source, False)
                        self.assertEqual(result["status"], "applied")
                        self.assertEqual(result["base"], revision)
                        self.assertEqual(result["issues"], [491, 492])
                        self.assertEqual(path.read_text(), changed)
                        self.assertEqual(stable.apply(source, False)["status"], "already_applied")
            with (
                patch.object(stable, "PATCHES", {}),
                self.assertRaisesRegex(ValueError, "pinned Godot"),
            ):
                stable.apply(fixtures[0][0], False)

    def test_explicit_source_wins_over_an_outer_repository_environment(self) -> None:
        script = SCRIPT.parent / "backport-websocket-43.py"
        spec = importlib.util.spec_from_file_location("websocket_backport_env", script)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Could not load {script}")
        backport = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(backport)
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            source = parent / "source"
            outer = parent / "outer"
            source.mkdir()
            backport.git(source, "init", "--quiet")
            original = "before\n" + "unchanged\n" * 12
            (source / "peer.cpp").write_text(original)
            backport.git(source, "add", "peer.cpp")
            committed = backport.git(
                source,
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            )
            self.assertEqual(committed.returncode, 0, committed.stderr)
            revision = backport.git(source, "rev-parse", "HEAD").stdout.strip()
            cloned = backport.git(parent, "clone", "--quiet", str(source), str(outer))
            self.assertEqual(cloned.returncode, 0, cloned.stderr)
            changed = original.replace("before", "after")
            (source / "peer.cpp").write_text(changed)
            patch_file = parent / "receive.patch"
            patch_file.write_text(backport.git(source, "diff", "--full-index").stdout)
            backport.git(source, "checkout", "--", "peer.cpp")
            locations = {
                "GIT_DIR": str(outer / ".git"),
                "GIT_WORK_TREE": str(outer),
                "GIT_COMMON_DIR": str(outer / ".git"),
                "GIT_INDEX_FILE": str(outer / ".git/index"),
            }
            extended = {
                **locations,
                "GIT_OBJECT_DIRECTORY": str(outer / ".git/objects"),
                "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(parent / "missing-objects"),
                "GIT_IMPLICIT_WORK_TREE": "0",
                "GIT_NAMESPACE": "outer-session",
                "GIT_PREFIX": "outer-prefix/",
                "GIT_SHALLOW_FILE": str(parent / "missing-shallow"),
                "GIT_GRAFT_FILE": str(parent / "missing-grafts"),
                "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_REPLACE_REF_BASE": "refs/outer-replace/",
                "GIT_CONFIG": str(outer / ".git/config"),
                "GIT_CONFIG_PARAMETERS": "'core.worktree=" + str(outer) + "'",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "core.worktree",
                "GIT_CONFIG_VALUE_0": str(outer),
            }
            for environment in (locations, extended):
                with self.subTest(variables=sorted(environment)):
                    for repository in (source, outer):
                        backport.git(repository, "reset", "--hard", "HEAD")
                    outer_index = (outer / ".git/index").read_bytes()
                    polluted = {
                        **environment,
                        "SF_BACKPORT_TEST_SENTINEL": "preserved",
                        "GIT_TERMINAL_PROMPT": "0",
                        "GIT_SSH_COMMAND": "preserved-command",
                    }
                    with (
                        patch.object(backport, "BASE", revision),
                        patch.object(backport, "PATCH", patch_file),
                        patch.dict(os.environ, polluted),
                    ):
                        before_environment = dict(os.environ)
                        marker = backport.git(
                            source,
                            "-c",
                            'alias.sf-env=!test "$SF_BACKPORT_TEST_SENTINEL" = preserved && test "$GIT_TERMINAL_PROMPT" = 0 && test "$GIT_SSH_COMMAND" = preserved-command',
                            "sf-env",
                        )
                        self.assertEqual(marker.returncode, 0, marker.stderr)
                        self.assertEqual(backport.apply(source, False)["status"], "applied")
                        staged = backport.git(source, "add", "peer.cpp")
                        self.assertEqual(staged.returncode, 0, staged.stderr)
                        self.assertEqual(dict(os.environ), before_environment)
                        top = backport.git(source, "rev-parse", "--show-toplevel")
                        self.assertEqual(top.stdout.strip(), str(source))
                    self.assertEqual((outer / ".git/index").read_bytes(), outer_index)
                    self.assertEqual((source / "peer.cpp").read_text(), changed)
                    self.assertEqual((outer / "peer.cpp").read_text(), original)
                    self.assertEqual(backport.git(source, "show", ":peer.cpp").stdout, changed)

    def test_real_git_apply_preserves_pin_and_exact_source_contract(self) -> None:
        script = SCRIPT.parent / "backport-websocket-43.py"
        spec = importlib.util.spec_from_file_location("websocket_backport", script)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Could not load {script}")
        backport = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(backport)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            backport.git(source, "init", "--quiet")
            path = source / "peer.cpp"
            original = "before\n" + "unchanged\n" * 12
            path.write_text(original)
            backport.git(source, "add", "peer.cpp")
            commit = backport.git(
                source,
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            )
            self.assertEqual(commit.returncode, 0, commit.stderr)
            revision = backport.git(source, "rev-parse", "HEAD").stdout.strip()
            path.write_text(original.replace("before", "after"))
            patch_file = source / "backport.patch"
            patch_file.write_text(
                backport.git(
                    source,
                    "diff",
                    "--full-index",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-color",
                    "--src-prefix=a/",
                    "--dst-prefix=b/",
                    "--diff-algorithm=myers",
                    "--no-indent-heuristic",
                    "--unified=3",
                    "--",
                    "peer.cpp",
                ).stdout
            )
            backport.git(source, "checkout", "--", "peer.cpp")
            with (
                patch.object(backport, "BASE", revision),
                patch.object(backport, "PATCH", patch_file),
            ):
                self.assertEqual(backport.apply(source, True)["status"], "applicable")
                self.assertEqual(path.read_text(), original)
                self.assertEqual(backport.apply(source, False)["status"], "applied")
                self.assertEqual(backport.apply(source, False)["status"], "already_applied")
                patched = path.read_text()
                path.write_text(patched + "extra local edit\n")
                with self.assertRaisesRegex(ValueError, "additional local changes"):
                    backport.apply(source, False)
                self.assertEqual(path.read_text(), patched + "extra local edit\n")
                path.write_text(patched)
                backport.git(source, "add", "peer.cpp")
                with self.assertRaisesRegex(ValueError, "staged changes"):
                    backport.apply(source, False)
                backport.git(source, "reset", "HEAD", "--", "peer.cpp")
                path.write_text(original + "extra baseline edit\n")
                with self.assertRaisesRegex(ValueError, "local changes"):
                    backport.apply(source, False)
            with (
                patch.object(backport, "BASE", "unsupported"),
                self.assertRaisesRegex(ValueError, "HEAD must be"),
            ):
                backport.apply(source, False)


if __name__ == "__main__":
    unittest.main()
