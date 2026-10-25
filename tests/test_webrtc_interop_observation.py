"""Keep live-drill driver timeouts distinct from engine failures."""

import importlib.util
import subprocess
import unittest
from functools import partial
from pathlib import Path
from typing import cast
from unittest.mock import Mock, patch

from playwright.sync_api import Page, Request

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
            "BROWSER_CRASH",
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

    def test_last_progress_survives_missing_terminal_and_truncated_line(self) -> None:
        output = "\n".join(
            [
                'WEBRTC_INTEROP_PROGRESS {"burst_received":32}',
                'WEBRTC_INTEROP_PROGRESS {"burst_received":64,"send_inflight_ms":250}',
                'WEBRTC_INTEROP_PROGRESS {"burst_received":',
            ]
        )
        result = drill.seat_evidence(output, 1)
        self.assertFalse(result["passed"])
        self.assertIsNone(result["diagnostic"])
        self.assertEqual(result["last_progress"], {"burst_received": 64, "send_inflight_ms": 250})

    def test_rpc_recovery_history_survives_later_failure(self) -> None:
        phase = {"phase": 1, "partial_received": 4, "retired_received": 0, "disconnected": 1}
        output = "\n".join(
            [
                'WEBRTC_RPC_RECOVERY_PHASE {"phase":1,"partial_received":4,"retired_received":0,"disconnected":1}',
                'WEBRTC_INTEROP_PROGRESS {"phase":2,"rpc_polling":false,"rpc_polls":142}',
                'WEBRTC_RPC_RECOVERY_PHASE {"phase":',
                'WEBRTC_INTEROP_FAIL {"stage":"recovery RPC disconnect notification"}',
            ]
        )
        evidence = drill.seat_evidence(output, 0)
        self.assertFalse(evidence["passed"])
        self.assertEqual(evidence["rpc_recovery_phases"], [phase])
        self.assertEqual(evidence["last_progress"]["rpc_polls"], 142)
        self.assertEqual(evidence["diagnostic"]["stage"], "recovery RPC disconnect notification")

    def test_engine_banner_records_actual_export_version(self) -> None:
        result = drill.seat_evidence(
            "Loading page\nGodot Engine v4.4.1.stable.official.49a5bc7b6\nWEBRTC_INTEROP_PASS seat=1",
            1,
        )
        self.assertEqual(result["engine_banner"], "Godot Engine v4.4.1.stable.official.49a5bc7b6")

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


class BrowserObservationTests(unittest.TestCase):
    def test_browser_request_timings_survive_missing_engine_terminal(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        request = Mock(spec=Request, url="http://drill.test/signal/1", method="GET")
        post = Mock(spec=Request, url="http://drill.test/signal/0", method="POST")
        with patch.object(drill.time, "monotonic", return_value=1):
            observation.started(request)
            observation.started(post)
            observation.console('WEBRTC_INTEROP_PROGRESS {"burst_sent":64}')
        with patch.object(drill.time, "monotonic", return_value=1.25):
            observation.finished(request)
        with patch.object(drill.time, "monotonic", return_value=3):
            result = observation.snapshot()
        self.assertEqual(result["completed_requests"], 1)
        self.assertEqual(result["failed_requests"], 0)
        self.assertEqual(result["last_progress_age_ms"], 2000)
        self.assertEqual(
            result["inflight_requests"], [{"method": "POST", "seat": "0", "age_ms": 2000}]
        )
        self.assertEqual(result["recent_requests"][0]["elapsed_ms"], 250)

    def test_request_history_is_bounded_and_scoped_to_signaling(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        unrelated = Mock(spec=Request, url="http://drill.test/index.wasm", method="GET")
        observation.started(unrelated)
        observation.finished(unrelated)
        for _ in range(40):
            request = Mock(spec=Request, url="http://drill.test/signal/1", method="GET")
            observation.started(request)
            observation.finished(request, failed=True)
        result = observation.snapshot()
        self.assertEqual(result["failed_requests"], 40)
        self.assertEqual(result["completed_requests"], 0)
        self.assertEqual(len(result["recent_requests"]), 16)
        self.assertEqual(result["inflight_requests"], [])
        self.assertIsNone(result["last_progress_age_ms"])

    def test_stats_history_survives_missing_engine_progress(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        with patch.object(drill.time, "monotonic", return_value=1):
            observation.console('WEBRTC_INTEROP_PROGRESS {"burst_received":32}')
        for count in range(20):
            with patch.object(drill.time, "monotonic", return_value=2 + count):
                observation.console(f'WEBRTC_BROWSER_STATS {{"created":{count}}}')
        for invalid in ("incomplete", "null", "[]", "42"):
            observation.console("WEBRTC_BROWSER_STATS " + invalid)
        with patch.object(drill.time, "monotonic", return_value=22):
            result = observation.snapshot()
        self.assertEqual(result["last_progress_age_ms"], 21000)
        self.assertEqual(result["last_stats_age_ms"], 1000)
        self.assertEqual(len(result["webrtc_stats"]), 16)
        self.assertEqual(result["webrtc_stats"][0], {"age_ms": 16000, "sample": {"created": 4}})
        self.assertEqual(result["webrtc_stats"][-1], {"age_ms": 1000, "sample": {"created": 19}})

    def test_engine_error_detection_keeps_normal_console_text(self) -> None:
        for output, failed in (
            ("ERROR: invalid packet", True),
            ("USER ERROR: invalid spawn", True),
            ("SCRIPT ERROR: bad call", True),
            ('interop stage: {"error":"ERROR: sample"}', False),
            ("Godot Engine ready", False),
        ):
            with self.subTest(output=output):
                self.assertEqual(drill.engine_failed(output), failed)

    def test_engine_error_or_crash_cannot_pass_despite_success_marker(self) -> None:
        for failure in ("BROWSER_CRASH", "ERROR: Invalid packet", "USER ERROR: Invalid spawn"):
            with self.subTest(failure=failure):
                result = drill.seat_evidence("WEBRTC_INTEROP_PASS seat=1\n" + failure, 1)
                self.assertFalse(result["passed"])


if __name__ == "__main__":
    unittest.main()
