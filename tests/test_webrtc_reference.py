"""Reference assessments distinguish unsupported gameplay from incomplete evidence."""

import importlib.util
import unittest
from pathlib import Path
from typing import cast
from unittest.mock import Mock, patch

from playwright.sync_api import Page

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-webrtc-reference.py"
SPEC = importlib.util.spec_from_file_location("webrtc_reference", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class ReferenceEvidenceTests(unittest.TestCase):
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
