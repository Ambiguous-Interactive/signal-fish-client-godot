"""Keep live-drill driver timeouts distinct from engine failures."""

import importlib.util
import subprocess
import unittest
from functools import partial
from pathlib import Path
from typing import cast
from unittest.mock import Mock, patch

from playwright.sync_api import Page

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-webrtc-interop.py"
SPEC = importlib.util.spec_from_file_location("webrtc_interop", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
drill = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drill)


class ObservationTests(unittest.TestCase):
    def test_browser_terminals(self) -> None:
        for terminal in (
            "WEBRTC_INTEROP_PASS seat=1",
            'WEBRTC_INTEROP_FAIL {"stage":"peer channels open"}',
            "PAGE_ERROR WebAssembly trap",
        ):
            with self.subTest(terminal=terminal):
                page = Mock()
                process = Mock()
                messages: list[str] = []
                page.wait_for_timeout.side_effect = partial(
                    lambda output, marker, _: output.append(marker), messages, terminal
                )
                self.assertEqual(drill.observe_browser(cast(Page, page), process, messages), "")
                process.poll.assert_not_called()

    def test_deadline_keeps_nonterminal_console_and_native_success(self) -> None:
        page = Mock()
        process = Mock()
        process.poll.return_value = 0
        messages = ["loading WEBRTC_INTEROP_scene", "WEBRTC_INTEROP_PASS seat=0"]
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 59, 60]):
            reason = drill.observe_browser(cast(Page, page), process, messages)
        self.assertEqual(reason, "browser observation timed out after 60 seconds")
        self.assertEqual(page.wait_for_timeout.call_count, 2)
        self.assertEqual(messages[-1], "WEBRTC_INTEROP_PASS seat=0")

    def test_native_failure_reports_driver_stop(self) -> None:
        process = Mock()
        process.poll.return_value = 1
        reason = drill.observe_browser(cast(Page, Mock()), process, [])
        self.assertEqual(reason, "native seat exited before browser completion")

    def test_missing_native_exit_is_still_observed(self) -> None:
        process = Mock(spec=subprocess.Popen)
        process.poll.return_value = None
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 60]):
            reason = drill.observe_browser(cast(Page, Mock()), process, [])
        self.assertIn("timed out", reason)
        process.poll.assert_called_once()

    def test_failure_snapshot_preserves_counts_and_invalid_output(self) -> None:
        for body, expected in (
            (
                '{"stream_waiting_ack":"stream-6-192","burst_received":92}',
                {"stream_waiting_ack": "stream-6-192", "burst_received": 92},
            ),
            ("incomplete json", None),
        ):
            with self.subTest(body=body):
                output = "WEBRTC_INTEROP_FAIL " + body
                result = drill.seat_evidence(output, 0)
                self.assertFalse(result["passed"])
                self.assertEqual(result["failure"], output)
                self.assertEqual(result["diagnostic"], expected)

    def test_evidence_keeps_last_completed_stage(self) -> None:
        output = "\n".join(
            [
                "interop ready: seat=1 phase=2 stage=remote ready marker elapsed_ms=12",
                "interop stage: seat=1 phase=2 stage=peer channels open",
            ]
        )
        result = drill.seat_evidence(output, 1)
        self.assertFalse(result["passed"])
        self.assertIn("peer channels open", result["last_stage"])
        self.assertIn("remote ready marker", result["last_ready"])


if __name__ == "__main__":
    unittest.main()
