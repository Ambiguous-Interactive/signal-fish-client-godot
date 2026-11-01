"""Deterministic storage policy regressions: python3 scripts/test_storage.py."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import storage


class ScratchPolicy(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name) / "scratch"

    def run_tree(self, size: int = 16384, clock: float = 100) -> Path:
        with storage.managed_output(None, root=self.root, now=lambda: clock) as path:
            (path / "project").mkdir()
            (path / "project" / "payload").write_bytes(b"x" * size)
            (path / "summary.json").write_text('{"passed": true}')
        return path

    def test_age_expiry_keeps_compact_evidence(self) -> None:
        path = self.run_tree()
        report = storage.clean(self.root, apply=True, now=100 + 8 * 86400)
        self.assertFalse((path / "project").exists())
        self.assertTrue((path / "evidence" / "summary.json").is_file())
        self.assertGreater(report["reclaimed_bytes"], 0)

    def test_budget_evicts_oldest_and_dry_run_does_not_write(self) -> None:
        first = self.run_tree(clock=100)
        second = self.run_tree(clock=200)
        report = storage.clean(self.root, budget=60000, now=201)
        self.assertIn(str(first), report["candidates"])
        self.assertTrue((first / "project").exists())
        storage.clean(self.root, apply=True, budget=60000, now=201)
        self.assertFalse((first / "project").exists())
        self.assertTrue((second / "project").exists())

    def test_active_and_pinned_are_protected(self) -> None:
        pinned = self.run_tree()
        storage.set_pin(self.root, pinned.name, True)
        with storage.managed_output(None, root=self.root) as active:
            (active / "payload").write_bytes(b"x" * 16000)
            report = storage.clean(self.root, apply=True, budget=0)
            self.assertTrue(active.is_dir())
            self.assertTrue(pinned.is_dir())
            self.assertTrue(report["over_budget"])

    def test_failed_run_is_completed_and_retained(self) -> None:
        with (
            self.assertRaisesRegex(RuntimeError, "fixture"),
            storage.managed_output(None, root=self.root) as path,
        ):
            raise RuntimeError("fixture")
        self.assertEqual(json.loads((path / ".run.json").read_text())["state"], "failed")
        self.assertIn(str(path), storage.clean(self.root, budget=0)["candidates"])

    def test_explicit_output_is_unmanaged(self) -> None:
        explicit = Path(self.folder.name) / "explicit"
        with storage.managed_output(explicit, root=self.root) as path:
            self.assertEqual(path, explicit)
        self.assertFalse((explicit / ".run.json").exists())
        self.assertFalse(self.root.exists())

    def test_unknown_and_symlink_entries_survive(self) -> None:
        self.run_tree()
        external = Path(self.folder.name) / "external"
        external.mkdir()
        (external / "precious").write_text("keep")
        (self.root / "link").symlink_to(external, target_is_directory=True)
        (self.root / "unknown").mkdir()
        storage.clean(self.root, apply=True, budget=0)
        self.assertTrue((external / "precious").is_file())
        self.assertTrue((self.root / "unknown").is_dir())

    def test_symlink_root_refused(self) -> None:
        real = Path(self.folder.name) / "real"
        real.mkdir()
        self.root.symlink_to(real, target_is_directory=True)
        with self.assertRaises(ValueError):
            storage.clean(self.root, apply=True)

    def test_missing_root_report_does_not_create(self) -> None:
        self.assertEqual(storage.clean(self.root)["total_bytes"], 0)
        self.assertFalse(self.root.exists())

    def test_interrupted_process_releases_lock(self) -> None:
        code = "import os, storage; c=storage.managed_output(None,root=storage.Path(os.environ['TEST_ROOT'])); p=c.__enter__(); os._exit(9)"
        env = {**os.environ, "TEST_ROOT": str(self.root)}
        result = subprocess.run(  # noqa: S603
            [sys.executable, "-c", code], cwd=Path(storage.__file__).parent, env=env, check=False
        )
        self.assertEqual(result.returncode, 9)
        report = storage.clean(self.root, apply=True, budget=0)
        self.assertFalse(report["over_budget"])

    def test_twenty_experiments_return_to_budget(self) -> None:
        for index in range(20):
            self.run_tree(clock=100 + index)
            report = storage.clean(self.root, apply=True, budget=60000, now=200)
            self.assertLessEqual(report["remaining_bytes"], 60000)

    def test_pin_rejects_traversal(self) -> None:
        self.run_tree()
        with self.assertRaises(ValueError):
            storage.set_pin(self.root, "../external", True)

    def test_report_marks_missing_paths(self) -> None:
        report = storage.report_paths([self.root])
        self.assertIn("error", report["paths"][0])

    def test_active_run_is_protected_across_processes(self) -> None:
        with storage.managed_output(None, root=self.root) as active:
            code = "import json,os,storage; print(json.dumps(storage.clean(storage.Path(os.environ['TEST_ROOT']),apply=True,budget=0)))"
            result = subprocess.run(  # noqa: S603
                [sys.executable, "-c", code],
                cwd=Path(storage.__file__).parent,
                env={**os.environ, "TEST_ROOT": str(self.root)},
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            self.assertIn(str(active), json.loads(result.stdout)["protected"])
            self.assertTrue(active.is_dir())

    def test_dry_run_does_not_change_registered_files(self) -> None:
        self.run_tree()
        before = {
            str(p): (p.stat().st_mtime_ns, p.read_bytes())
            for p in self.root.rglob("*")
            if p.is_file()
        }
        storage.clean(self.root, budget=0)
        after = {
            str(p): (p.stat().st_mtime_ns, p.read_bytes())
            for p in self.root.rglob("*")
            if p.is_file()
        }
        self.assertEqual(before, after)

    def test_interrupted_compaction_is_retryable(self) -> None:
        path = self.run_tree()
        with patch("shutil.rmtree", side_effect=OSError("interrupted")):
            report = storage.clean(self.root, apply=True, now=100 + 8 * 86400)
        self.assertTrue(report["errors"])
        report = storage.clean(self.root, apply=True, now=100 + 8 * 86400)
        self.assertFalse(report["errors"])
        self.assertFalse((path / "project").exists())
        self.assertTrue((path / "evidence" / "summary.json").is_file())

    def test_pin_symlink_refused(self) -> None:
        path = self.run_tree()
        external = Path(self.folder.name) / "external"
        external.write_text("precious")
        (path / ".keep").symlink_to(external)
        with self.assertRaises(ValueError):
            storage.set_pin(self.root, path.name, True)
        self.assertEqual(external.read_text(), "precious")

    def test_corrupted_metadata_is_protected(self) -> None:
        path = self.run_tree()
        (path / ".run.json").write_text("corrupt")
        report = storage.clean(self.root, apply=True, budget=0)
        self.assertTrue(report["errors"])
        self.assertTrue((path / "project").is_dir())

    def test_other_process_active_lock_is_protected(self) -> None:
        code = "import storage,time,os; c=storage.managed_output(None,root=storage.Path(os.environ['TEST_ROOT'])); p=c.__enter__(); print(p,flush=True); time.sleep(60)"
        env = {**os.environ, "TEST_ROOT": str(self.root)}
        child = subprocess.Popen(  # noqa: S603
            [sys.executable, "-c", code],
            cwd=Path(storage.__file__).parent,
            env=env,
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            if child.stdout is None:
                self.fail("Child output unavailable")
            path = Path(child.stdout.readline().strip())
            result = storage.clean(self.root, apply=True, budget=0)
            self.assertIn(str(path), result["protected"])
            self.assertTrue(path.is_dir())
        finally:
            child.terminate()
            child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
        result = storage.clean(self.root, apply=True, budget=0)
        self.assertFalse(result["over_budget"])

    def test_dry_run_preserves_files(self) -> None:
        self.run_tree()
        before = {str(p): p.stat().st_mtime_ns for p in self.root.rglob("*")}
        storage.clean(self.root, budget=0)
        after = {str(p): p.stat().st_mtime_ns for p in self.root.rglob("*")}
        self.assertEqual(before, after)

    def test_sparse_files_are_measured_by_allocation(self) -> None:
        sparse = Path(self.folder.name) / "sparse"
        with sparse.open("wb") as stream:
            stream.truncate(100 * storage.GIB)
        self.assertLess(storage.allocated(sparse), 1024 * 1024)

    def test_server_inventory_retains_local_reference_and_two_newest(self) -> None:
        servers = Path(self.folder.name) / "bin"
        architecture = servers / "linux-arm64"
        architecture.mkdir(parents=True)
        references = Path(self.folder.name) / "references"
        references.mkdir()
        for index in range(4):
            server = architecture / f"server-{index}"
            server.mkdir()
            os.utime(server, (index + 1, index + 1))
        (references / "active").symlink_to(architecture / "server-0", target_is_directory=True)
        report = json.loads(json.dumps(storage.server_cache(servers, references)))
        policy = {Path(p["path"]).name: p["retain_under_local_policy"] for p in report["versions"]}
        self.assertEqual(
            policy, {"server-0": True, "server-1": False, "server-2": True, "server-3": True}
        )
        self.assertFalse(report["other_container_references_verified"])
        self.assertEqual(len(list(architecture.iterdir())), 4)

    def test_shared_cache_cleanup_is_explicit_and_bounded(self) -> None:
        cache = Path(self.folder.name) / "extensionsCache"
        cache.mkdir()
        for index in range(3):
            item = cache / f"extension-{index}"
            item.write_bytes(b"x" * 8192)
            os.utime(item, (index + 1, index + 1))
        report = storage.extension_cache(cache, budget=8192)
        self.assertEqual(len(report["candidates"]), 2)
        self.assertEqual(len(list(cache.iterdir())), 3)
        storage.extension_cache(cache, budget=8192, apply=True)
        self.assertEqual([p.name for p in cache.iterdir()], ["extension-2"])


if __name__ == "__main__":
    unittest.main()
