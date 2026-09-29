"""Check documentation output validation and repeated builds."""

import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hooks"))
import llms_txt


@dataclass
class Inclusion:
    included: bool = True

    def is_included(self) -> bool:
        return self.included


@dataclass
class BuildFile:
    abs_dest_path: str
    inclusion: Inclusion
    documentation: bool = True

    def is_documentation_page(self) -> bool:
        return self.documentation


@dataclass
class BuildConfig:
    config_file_path: str
    site_dir: str


class DocsBuildTests(unittest.TestCase):
    def test_missing_pages_fail_and_other_files_are_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            site = root / "site"
            site.mkdir()
            (root / "llms.txt").write_text("canonical docs", encoding="utf-8")
            config = BuildConfig(str(root / "mkdocs.yml"), str(site))
            outputs = [site / "index.html", site / "nested/index.html"]
            llms_txt.on_files(
                [BuildFile(str(path), Inclusion()) for path in outputs]
                + [
                    BuildFile(str(site / "draft.html"), Inclusion(False)),
                    BuildFile(str(site / "asset.css"), Inclusion(), False),
                ]
            )
            with self.assertRaises(RuntimeError) as error:
                llms_txt.on_post_build(config)
            for path in outputs:
                self.assertIn(str(path), str(error.exception))
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("rendered page", encoding="utf-8")
            llms_txt.on_post_build(config)
            self.assertEqual((site / "llms.txt").read_text(encoding="utf-8"), "canonical docs")

    def test_next_build_replaces_previous_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "llms.txt").write_text("canonical docs", encoding="utf-8")
            site = root / "site"
            site.mkdir()
            llms_txt.on_files([BuildFile(str(root / "old/index.html"), Inclusion())])
            llms_txt.on_files([])
            llms_txt.on_post_build(BuildConfig(str(root / "mkdocs.yml"), str(site)))


if __name__ == "__main__":
    unittest.main()
