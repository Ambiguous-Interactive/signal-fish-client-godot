#!/usr/bin/env python3
"""Compare nested incremental builds with the pinned native extension's CMake tool."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from itertools import pairwise
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "62135fc034cbdc5aee177136e526e3ead3cc563a"
PATCH = ROOT / "tests/smoke/webrtc_native_incremental_build.patch"
SCONSTRUCT = """
import os
env = Environment(ENV=os.environ.copy())
env.CacheDir("scons-cache")
env.__class__.msvc = False
env["platform"] = "linux"
env["arch"] = ARGUMENTS["arch"]
env["debug_symbols"] = False
env["cmake"] = ARGUMENTS["cmake"]
env["emcmake"] = "emcmake"
env["cmake_generator"] = ""
env.Tool("cmake", toolpath=["tools"])
targets = env.CMakeBuild(
    env.Dir("build"), env.Dir("library"),
    cmake_outputs=["libnested.a"], cmake_targets=["nested"], cmake_options={})
env.Append(LIBS=[targets[1]])
Default(env.SharedLibrary("extension", ["entry.cpp"]))
"""
CMAKE = """
cmake_minimum_required(VERSION 3.16)
project(incremental_control LANGUAGES CXX)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
add_compile_definitions(ROOT_VALUE=0)
add_subdirectory(nested)
"""
NESTED_CMAKE = """
add_library(nested STATIC nested.cpp)
set_target_properties(nested PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
target_compile_definitions(nested PRIVATE CONFIG_VALUE=100)
"""
CPP = (
    '#include "value.hpp"\nint nested() { return 1 + HEADER_VALUE + CONFIG_VALUE + ROOT_VALUE; }\n'
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], cwd: Path, log: Path, *, expect_failure: bool = False) -> str:
    environment = os.environ.copy()
    if command[0] == "git":
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"):
            environment.pop(name, None)
    with log.open("a") as stream:
        stream.write(shlex.join(command) + "\n")
        stream.flush()
        try:
            result = subprocess.run(  # noqa: S603
                command,
                cwd=cwd,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=120,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            captured = exc.stdout or ""
            stream.write(
                captured.decode(errors="replace") if isinstance(captured, bytes) else captured
            )
            stream.write("\nCommand timed out after 120 seconds\n")
            raise RuntimeError(f"Command timed out; see {log}") from exc
        stream.write(result.stdout + f"\nExit code: {result.returncode}\n")
    if (result.returncode != 0) != expect_failure:
        raise RuntimeError(f"Command exited {result.returncode}; see {log}")
    return result.stdout


def snapshot(work: Path, arch: str, log: Path) -> dict[str, object]:
    archive = work / "build" / "linux" / arch / "libnested.a"
    extension = work / "libextension.so"
    observed = run(
        [
            sys.executable,
            "-c",
            "import ctypes,sys; print(ctypes.CDLL(sys.argv[1]).observed())",
            str(extension),
        ],
        work,
        log,
    )
    return {
        "observed": int(observed.strip()),
        "source_sha256": {
            str(path.relative_to(work)): digest(path)
            for path in (
                work / "library/nested/nested.cpp",
                work / "library/nested/value.hpp",
                work / "library/nested/CMakeLists.txt",
                work / "library/CMakeLists.txt",
            )
        },
        "archive_sha256": digest(archive),
        "extension_sha256": digest(extension),
        "archive_mtime_ns": archive.stat().st_mtime_ns,
        "extension_mtime_ns": extension.stat().st_mtime_ns,
    }


def compare(source: str, output: Path, scons: str, cmake: str, arch: str) -> dict[str, object]:
    results: dict[str, object] = {}
    for variant in ("baseline", "repaired"):
        work = output / variant
        nested = work / "library/nested"
        nested.mkdir(parents=True)
        (work / "tools").mkdir()
        (work / "tools/cmake.py").write_text(source)
        (work / "SConstruct").write_text(SCONSTRUCT)
        (work / "library/CMakeLists.txt").write_text(CMAKE)
        (nested / "CMakeLists.txt").write_text(NESTED_CMAKE)
        (nested / "nested.cpp").write_text(CPP)
        (nested / "value.hpp").write_text("#define HEADER_VALUE 10\n")
        (work / "entry.cpp").write_text(
            'int nested(); extern "C" int observed() { return nested(); }\n'
        )
        log = work / "commands.log"
        if variant == "repaired":
            run(["git", "apply", "--unsafe-paths", "--directory", str(work), str(PATCH)], ROOT, log)
        command = [scons, "-Q", "-j2", f"arch={arch}", f"cmake={cmake}"]
        rows: list[dict[str, object]] = []
        steps = (
            ("initial", None, "", "", 111),
            ("source", nested / "nested.cpp", "return 1 +", "return 2 +", 112),
            ("header", nested / "value.hpp", "10", "20", 122),
            (
                "nested_cmake",
                nested / "CMakeLists.txt",
                "CONFIG_VALUE=100",
                "CONFIG_VALUE=200",
                222,
            ),
            (
                "root_cmake",
                work / "library/CMakeLists.txt",
                "ROOT_VALUE=0",
                "ROOT_VALUE=1000",
                1222,
            ),
            ("noop", None, "", "", 1222),
        )
        for name, path, old, new, expected in steps:
            if path is not None:
                content = path.read_text()
                if content.count(old) != 1:
                    raise RuntimeError(f"Invalid fixture edit: {path}")
                path.write_text(content.replace(old, new))
            run(command, work, log)
            row = {"case": name, "expected": expected, **snapshot(work, arch, log)}
            rows.append(row)
            (work / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        results[variant] = rows
        required = (
            [111, 111, 111, 111, 1222, 1222]
            if variant == "baseline"
            else [step[4] for step in steps]
        )
        if [row["observed"] for row in rows] != required:
            raise RuntimeError(f"Unexpected {variant} runtime values; see {work}")
        for key in ("archive_sha256", "extension_sha256", "archive_mtime_ns", "extension_mtime_ns"):
            if rows[-1][key] != rows[-2][key]:
                raise RuntimeError(f"No-op {variant} build rewrote {key}")
        if variant == "baseline":
            for row in rows[1:4]:
                for key in ("archive_sha256", "extension_sha256"):
                    if row[key] != rows[0][key]:
                        raise RuntimeError(f"Baseline failed to retain stale {key}")
        else:
            for before, after in pairwise(rows[:5]):
                for key in ("archive_sha256", "extension_sha256"):
                    if before[key] == after[key]:
                        raise RuntimeError(f"Repaired {after['case']} build retained stale {key}")
            cpp = nested / "nested.cpp"
            previous = cpp.read_text()
            cpp.write_text("#error intentional incremental build failure\n")
            run(command, work, log, expect_failure=True)
            failed = snapshot(work, arch, log)
            for key in (
                "archive_sha256",
                "extension_sha256",
                "archive_mtime_ns",
                "extension_mtime_ns",
            ):
                if failed[key] != rows[-1][key]:
                    raise RuntimeError(f"Failed build changed the retained {key}")
            cpp.write_text(previous.replace("return 2 +", "return 3 +"))
            run(command, work, log)
            recovered = snapshot(work, arch, log)
            if recovered["observed"] != 1223:
                raise RuntimeError("Build did not recover after compilation failure")
            for key in ("archive_sha256", "extension_sha256"):
                if recovered[key] == failed[key]:
                    raise RuntimeError(f"Recovery retained stale {key}")
            results["failure_recovery"] = {"failed": failed, "recovered": recovered}
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Pinned webrtc-native clone")
    parser.add_argument("--output", required=True, type=Path, help="New evidence directory")
    parser.add_argument("--scons", default="scons", help="SCons executable")
    parser.add_argument("--cmake", default="cmake", help="CMake executable")
    args = parser.parse_args()
    if sys.platform != "linux" or platform.machine() not in ("aarch64", "x86_64"):
        parser.error("This compiled control requires Linux ARM64 or x86-64")
    source = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    log = output / "commands.log"
    expected = run(["git", "show", f"{REVISION}:tools/cmake.py"], source, log)
    if (source / "tools/cmake.py").read_text() != expected:
        raise RuntimeError("CMake tool differs from the pinned source")
    scons = shutil.which(args.scons)
    cmake = shutil.which(args.cmake)
    if scons is None or cmake is None:
        parser.error("SCons and CMake must be installed")
    arch = "arm64" if platform.machine() == "aarch64" else "x86_64"
    results = {
        "revision": REVISION,
        "tool_sha256": digest(source / "tools/cmake.py"),
        "patch_sha256": digest(PATCH),
        "scons_version": run([scons, "--version"], output, log),
        "cmake_version": run([cmake, "--version"], output, log),
        **compare(expected, output, scons, cmake, arch),
    }
    (output / "assessment.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"Native incremental build control passed: {output / 'assessment.json'}")


if __name__ == "__main__":
    main()
