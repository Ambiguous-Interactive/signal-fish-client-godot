"""Publish the repository's canonical llms.txt at the documentation root."""

import shutil
from collections.abc import Iterable
from pathlib import Path
from typing import Protocol


class BuildConfig(Protocol):
    config_file_path: str
    site_dir: str


class Inclusion(Protocol):
    def is_included(self) -> bool: ...


class BuildFile(Protocol):
    abs_dest_path: str

    @property
    def inclusion(self) -> Inclusion: ...

    def is_documentation_page(self) -> bool: ...


_rendered_pages: list[Path] = []


def on_files(files: Iterable[BuildFile], **kwargs: object) -> None:
    _rendered_pages.clear()
    _rendered_pages.extend(
        Path(file.abs_dest_path)
        for file in files
        if file.is_documentation_page() and file.inclusion.is_included()
    )


def on_post_build(config: BuildConfig, **kwargs: object) -> None:
    """Copy the canonical source after MkDocs has prepared the site directory."""
    missing = [str(path) for path in _rendered_pages if not path.is_file()]
    if missing:
        raise RuntimeError(f"Missing rendered documentation: {', '.join(missing)}")
    source = Path(config.config_file_path).resolve().parent / "llms.txt"
    destination = Path(config.site_dir) / "llms.txt"
    shutil.copyfile(source, destination)
