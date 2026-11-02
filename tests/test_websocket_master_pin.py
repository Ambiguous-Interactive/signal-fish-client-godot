"""Keep the pinned master WebSocket repair aligned with upstream master."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-websocket-master-pin.py"
SPEC = importlib.util.spec_from_file_location("websocket_master_pin", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watch)

REPO_ROOT = Path(__file__).resolve().parents[1]
PINNED = "95c0fa5fe8a019adc29d074c16b64469b04571f7"
MOVED = "0f2d1c39485a6b7c8d9e0f2d1c39485a6b7c8d9e"

SYNTHETIC_PATCH = (
    "diff --git a/one.txt b/one.txt\n"
    "index 0000001..0000002 100644\n"
    "--- a/one.txt\n"
    "+++ b/one.txt\n"
    "@@ -1 +1 @@\n"
    "-original\n"
    "+repaired\n"
)


def refuse_fetch(revision: str, path: str) -> str:
    raise AssertionError(f"master {revision} must not fetch {path}")


class PinSelectionTests(unittest.TestCase):
    def test_local_pin_selects_the_bundled_master_patch(self) -> None:
        revision, patch = watch.local_pin(REPO_ROOT)
        self.assertEqual(revision, PINNED)
        self.assertEqual(patch.name, "godot-master-websocket-assembly.patch")
        self.assertTrue(patch.is_file())

    def test_local_pin_rejects_a_missing_patch_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / "scripts" / "repair-websocket-stable.py"
            script.parent.mkdir(parents=True)
            script.write_text(
                f'"{PINNED}": "godot-master-websocket-assembly.patch",\n', encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "missing"):
                watch.local_pin(root)


class PatchPathTests(unittest.TestCase):
    def test_bundled_patch_paths_come_from_its_headers(self) -> None:
        text = watch.read_text(watch.local_pin(REPO_ROOT)[1])
        self.assertEqual(
            watch.patch_paths(text),
            [
                "modules/websocket/wsl_peer.cpp",
                "modules/websocket/wsl_peer.h",
                "thirdparty/wslay/wslay_event.c",
            ],
        )

    def test_unsafe_paths_are_rejected(self) -> None:
        for unsafe in ("/etc/passwd", "../escape", "ok/../../up"):
            with self.subTest(unsafe=unsafe):
                text = SYNTHETIC_PATCH.replace("one.txt", unsafe)
                with self.assertRaisesRegex(RuntimeError, "unsafe path"):
                    watch.patch_paths(text)


class EvaluateTests(unittest.TestCase):
    def evaluate(self, master: str, content: str) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as tmp:
            patch = Path(tmp) / "synthetic.patch"
            patch.write_text(SYNTHETIC_PATCH, encoding="utf-8")
            result: dict[str, object] = watch.evaluate(
                PINNED, patch, master, fetch_file_fn=lambda revision, path: content
            )
            return result

    def test_current_master_never_fetches_files(self) -> None:
        self.assertEqual(
            watch.evaluate(PINNED, Path("unused.patch"), PINNED, refuse_fetch),
            {"status": "current"},
        )

    def test_moved_master_classification(self) -> None:
        cases = {
            "original\n": "applies",
            "frame_is_data landed here\n": "adopted",
            "unrelated drift\n": "drifted",
        }
        for content, expected in cases.items():
            with self.subTest(expected=expected):
                result = self.evaluate(MOVED, content)
                self.assertEqual(result["status"], expected)
                self.assertEqual(result["master"], MOVED)


class PrStateTests(unittest.TestCase):
    def test_parse_pr_keeps_the_review_tracking_fields(self) -> None:
        payload = {
            "state": "open",
            "draft": False,
            "mergeable_state": "unstable",
            "review_comments": 2,
            "updated_at": "2026-11-02T04:00:01Z",
            "number": 999,
            "unrelated": True,
        }
        self.assertEqual(
            watch.parse_pr(payload),
            {
                "number": watch.PR_NUMBER,
                "state": "open",
                "draft": False,
                "mergeable_state": "unstable",
                "review_comments": 2,
                "updated_at": "2026-11-02T04:00:01Z",
            },
        )

    def test_parse_pr_tolerates_missing_and_invalid_payloads(self) -> None:
        self.assertEqual(watch.parse_pr({})["number"], watch.PR_NUMBER)
        self.assertTrue(watch.parse_pr(["not", "an", "object"]).get("error"))


class SelfTestTests(unittest.TestCase):
    def test_offline_self_test_passes(self) -> None:
        self.assertEqual(watch.self_test(), 0)


if __name__ == "__main__":
    unittest.main()
