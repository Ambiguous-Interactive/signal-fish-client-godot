"""Reference assessments distinguish unsupported gameplay from incomplete evidence."""

import importlib.util
import json
import subprocess
import threading
import unittest
from pathlib import Path
from typing import ClassVar, cast
from unittest.mock import Mock, patch

from playwright.sync_api import Page

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-webrtc-reference.py"
SPEC = importlib.util.spec_from_file_location("webrtc_reference", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class ReferenceEvidenceTests(unittest.TestCase):
    def test_snapshot_verdict_requires_complete_stream_and_partial_transfer(self) -> None:
        phase = {
            "mixed_traffic": False,
            "credit_transport": "http",
            "snapshot_acknowledged": 128,
            "positions_sent": 0,
            "positions_received": 0,
            "peak_outstanding": 32,
            "sent": True,
            "remote_closed": True,
            "received": ["unreliable", "reliable"],
            "snapshot_sent": 128,
            "snapshot_received": 128,
            "partial_sent": 4,
            "partial_received": 4,
        }
        self.assertTrue(reference.gameplay_phase_passed(phase))
        self.assertFalse(reference.gameplay_phase_passed(phase, slow_receiver=True))
        for field, total in (
            ("snapshot_sent", 128),
            ("snapshot_received", 128),
            ("partial_sent", 4),
            ("partial_received", 4),
        ):
            for value in (0, total - 1, total + 1):
                with self.subTest(field=field, value=value):
                    self.assertFalse(reference.gameplay_phase_passed({**phase, field: value}))
        for transport in ("http", "webrtc"):
            mixed = {
                **phase,
                "mixed_traffic": True,
                "credit_transport": transport,
                "positions_sent": 32,
                "positions_received": 32,
            }
            self.assertTrue(
                reference.gameplay_phase_passed(
                    mixed, mixed_traffic=True, credit_transport=transport
                )
            )
            for field, mixed_value in (
                ("positions_sent", 31),
                ("positions_received", 31),
                ("snapshot_acknowledged", 120),
                ("peak_outstanding", 33),
                ("peak_outstanding", 0),
                ("credit_transport", "other"),
                ("mixed_traffic", False),
            ):
                with self.subTest(transport=transport, field=field):
                    self.assertFalse(
                        reference.gameplay_phase_passed(
                            {**mixed, field: mixed_value},
                            mixed_traffic=True,
                            credit_transport=transport,
                        )
                    )
        self.assertFalse(reference.gameplay_phase_passed({**phase, "remote_closed": False}))
        self.assertFalse(reference.gameplay_phase_passed({}))
        self.assertFalse(reference.gameplay_phase_passed({**phase, "received": ["reliable"]}))

    def test_slow_reader_requires_a_real_pause_and_queued_mixed_packets(self) -> None:
        proof = {
            "resumed": True,
            "elapsed_ms": 1500,
            "received": 8,
            "received_at_resume": 8,
            "queued_reliable": 32,
            "queued_unreliable": 8,
        }
        self.assertTrue(reference.slow_receiver_passed(proof, True))
        for field, value in (
            ("resumed", False),
            ("elapsed_ms", 1499),
            ("elapsed_ms", None),
            ("received", 0),
            ("received", 128),
            ("received_at_resume", 9),
            ("queued_reliable", 23),
            ("queued_unreliable", 0),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(reference.slow_receiver_passed({**proof, field: value}, True))
        for missing in (None, {}, {"resumed": True}):
            self.assertFalse(reference.slow_receiver_passed(missing, True))
        self.assertTrue(reference.slow_receiver_passed({**proof, "queued_unreliable": 0}, False))

    def test_credit_arriving_between_queue_locks_cannot_bypass_the_hold(self) -> None:
        credit = {"marker": "snapshot-ack-1-32"}
        mutex = threading.Lock()

        class ArrivingCredit:
            injected = False

            def __enter__(self) -> None:
                mutex.acquire()

            def __exit__(self, *_args: object) -> None:
                if not self.injected:
                    self.injected = True
                    Handler.queues[0].append(credit)
                    Handler.observation.enqueue(0, credit)
                mutex.release()

        class Handler(reference.CreditDelayRelay):  # type: ignore[name-defined,misc]
            credit_delay_ms = 4000
            credit_seat = 0
            credit_delayed = threading.Event()
            lock = ArrivingCredit()
            queues: ClassVar[list[list[object]]] = [[], []]
            observation = reference.interop.RelayObservation()

        handler = object.__new__(Handler)
        handler.path = "/signal/0"
        handler.command = "GET"
        replies: list[object] = []
        holds: list[float] = []

        def sleep(seconds: float) -> None:
            self.assertTrue(mutex.acquire(blocking=False))
            mutex.release()
            self.assertTrue(Handler.credit_hold_active.is_set())
            holds.append(seconds)

        def reply(_handler: object, body: bytes) -> None:
            messages = json.loads(body)
            if credit in messages:
                self.assertEqual(holds, [4])
                self.assertTrue(Handler.credit_delayed.is_set())
            replies.extend(messages)

        with (
            patch.object(reference.time, "sleep", side_effect=sleep),
            patch.object(reference.interop.RelayHandler, "reply", autospec=True, side_effect=reply),
        ):
            handler.do_GET()
            handler.do_GET()
            Handler.queues[0].append(credit)
            handler.do_GET()
        self.assertEqual(replies, [credit, credit])
        self.assertEqual(holds, [4])
        self.assertFalse(Handler.credit_hold_active.is_set())

    def test_held_signaling_requires_new_gameplay_round_trip(self) -> None:
        before = {
            "phase": 1,
            "signaling_pending": True,
            "heartbeat_sent": 4,
            "heartbeat_received": 4,
            "snapshot_acknowledged": 24,
        }
        during = {**before, "heartbeat_sent": 14, "heartbeat_received": 13}
        proof = {"before": before, "during": during, "elapsed_ms": 1000}
        self.assertTrue(reference.signaling_hold_passed(proof))
        for field, value in (
            ("heartbeat_sent", 4),
            ("heartbeat_received", 4),
            ("heartbeat_received", 15),
            ("heartbeat_received", None),
            ("signaling_pending", False),
            ("phase", 2),
            ("snapshot_acknowledged", 32),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(
                    reference.signaling_hold_passed({**proof, "during": {**during, field: value}})
                )
        for invalid in ({}, {"before": before}, {**proof, "elapsed_ms": 999}):
            self.assertFalse(reference.signaling_hold_passed(invalid))

    def test_heartbeat_verdict_requires_exact_echo_totals_on_both_seats(self) -> None:
        for mixed, count in ((False, 0), (True, 12)):
            godot = {"heartbeat_received": count}
            ref = {"heartbeat_sent": count, "heartbeat_received": count}
            self.assertTrue(reference.heartbeat_phase_passed(godot, ref, mixed))
            for changed in (None, count + 1, count - 1, True):
                self.assertFalse(
                    reference.heartbeat_phase_passed({"heartbeat_received": changed}, ref, mixed)
                )
                self.assertFalse(
                    reference.heartbeat_phase_passed(
                        godot, {**ref, "heartbeat_received": changed}, mixed
                    )
                )
        for invalid_count in (0, 129, None, True):
            self.assertFalse(
                reference.heartbeat_phase_passed(
                    {"heartbeat_received": invalid_count},
                    {"heartbeat_sent": invalid_count, "heartbeat_received": invalid_count},
                    True,
                )
            )

    def test_phase_timeout_keeps_its_reason_and_genuine_signaling_errors(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const failure = process.argv[1];
let clock = 0;
const context = {
  window: {}, AbortController, DOMException,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: (resolve) => setImmediate(() => { clock = 14000; resolve(); }),
  Engine: class {
    channel() { return null; }
    diagnosticSnapshot() { return {}; }
    removePeer() {}
  },
  fetch: (_url, { signal }) => new Promise((_resolve, reject) => {
    if (failure === "relay") reject(new Error("relay GET 503"));
    else if (failure === "external-abort") reject(new DOMException("external cancellation", "AbortError"));
    else signal.addEventListener("abort", () => reject(new DOMException("cleanup cancellation", "AbortError")));
  }),
};
runInNewContext(source, context);
await context.window.runReference(1, false, false, "http");
console.log(JSON.stringify(context.window.referenceError));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text()
        for case, expected in (
            ("timeout", "Error: phase 1 missing Godot teardown"),
            ("relay", "Error: relay GET 503"),
            ("external-abort", "AbortError: external cancellation"),
        ):
            with self.subTest(case=case):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, case],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                self.assertEqual(json.loads(result.stdout), expected)

    def test_page_listeners_keep_errors_and_crashes(self) -> None:
        page = Mock()
        messages: list[str] = []
        reference.watch_page(cast(Page, page), messages)
        listeners = {call.args[0]: call.args[1] for call in page.on.call_args_list}
        listeners["console"](Mock(type="log", text="ready"))
        listeners["console"](Mock(type="error", text="ICE failed"))
        listeners["pageerror"]("WebAssembly trap")
        listeners["crash"](page)
        self.assertEqual(
            messages,
            ["ready", "CONSOLE_ERROR ICE failed", "PAGE_ERROR WebAssembly trap", "BROWSER_CRASH"],
        )

    def test_observer_installed_before_navigation_keeps_requests_and_stats(self) -> None:
        page = Mock()
        observer = reference.observe_page(cast(Page, page), "http://drill.test")
        listeners = {call.args[0]: call.args[1] for call in page.on.call_args_list}
        request = Mock(url="http://drill.test/signal/1", method="GET")
        listeners["request"](request)
        listeners["requestfailed"](request)
        listeners["console"](Mock(text='WEBRTC_BROWSER_STATS {"peers":[]}'))
        listeners["console"](Mock(text='WEBRTC_INTEROP_PROGRESS {"phase":1}'))
        snapshot = observer.snapshot()
        self.assertEqual(snapshot["failed_requests"], 1)
        self.assertEqual(snapshot["inflight_requests"], [])
        self.assertIsNotNone(snapshot["last_stats_age_ms"])
        self.assertIsNotNone(snapshot["last_progress_age_ms"])
        page.add_init_script.assert_called_once_with(
            path=reference.ROOT / "scripts/webrtc-browser-observation.js"
        )

    def test_delayed_web_completion_waits_for_actual_terminal(self) -> None:
        page = Mock()
        messages: list[str] = []

        def advance(_milliseconds: int) -> None:
            messages.append(
                "WEBRTC_INTEROP_PASS seat=1" if len(messages) == 7 else "engine still running"
            )

        page.wait_for_timeout.side_effect = advance
        self.assertEqual(reference.wait_for_godot(cast(Page, page), messages), "")
        self.assertEqual(page.wait_for_timeout.call_count, 8)

    def test_missing_web_terminal_is_a_driver_timeout(self) -> None:
        with patch.object(reference.time, "monotonic", side_effect=[0, 0, 15]):
            reason = reference.wait_for_godot(cast(Page, Mock()), ["loading"])
        self.assertIn("observation timed out", reason)

    def test_reference_errors_cannot_be_called_unsupported_gameplay(self) -> None:
        for message in (
            "CONSOLE_ERROR browser rejected buffered ICE candidate",
            "PAGE_ERROR module import failed",
            "BROWSER_CRASH",
        ):
            with self.subTest(message=message):
                self.assertTrue(reference.page_failed([message]))
                page = Mock()
                self.assertEqual(reference.wait_for_godot(cast(Page, page), [message]), "")
                page.wait_for_timeout.assert_not_called()
        self.assertFalse(reference.page_failed(["channel closed", "WEBRTC_INTEROP_PASS seat=1"]))

    def test_partial_phase_evidence_survives_truncated_output(self) -> None:
        self.assertEqual(
            reference.phase_evidence(
                'WEBRTC_REFERENCE_PHASE {"phase":1,"received":[]}\n'
                'WEBRTC_REFERENCE_PHASE {"phase":2'
            ),
            [{"phase": 1, "received": []}],
        )


if __name__ == "__main__":
    unittest.main()
