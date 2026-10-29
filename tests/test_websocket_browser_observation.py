"""Keep observed Web callbacks distinct from proven engine rejections and reads."""

import copy
import importlib.util
import unittest
from pathlib import Path
from typing import cast

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


if __name__ == "__main__":
    unittest.main()
