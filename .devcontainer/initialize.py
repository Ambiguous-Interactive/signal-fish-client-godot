"""Create the host env file before Docker reads --env-file."""

import os
import stat
import sys
from pathlib import Path


def initialize(workspace: Path) -> int:
    target = workspace / ".env.local"
    if target.exists():
        if target.is_file():
            return 0
        print("ERROR: .env.local must be a file.", file=sys.stderr)
        return 1

    source = workspace / ".env.example"
    try:
        source_info = source.stat()
        if not stat.S_ISREG(source_info.st_mode):
            raise OSError("not a file")
        source_file = source.open("rb")
    except OSError:
        print("ERROR: .env.example is missing or unreadable.", file=sys.stderr)
        return 1

    with source_file:
        try:
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            if target.is_file():
                return 0
            print("ERROR: .env.local must be a file.", file=sys.stderr)
            return 1
        except OSError as error:
            print(f"ERROR: could not create .env.local: {error}", file=sys.stderr)
            return 1

        try:
            with os.fdopen(descriptor, "wb") as target_file:
                while chunk := source_file.read(1024 * 1024):
                    target_file.write(chunk)
        except OSError as error:
            print(f"ERROR: could not write .env.local: {error}", file=sys.stderr)
            return 1

    try:
        os.chown(target, source_info.st_uid, source_info.st_gid)
    except OSError:
        try:
            os.chmod(target, stat.S_IMODE(target.stat().st_mode) | 0o444)
            print(
                "WARN: could not set .env.local ownership; made it world-readable instead. "
                "Tighten after editing.",
                file=sys.stderr,
            )
        except OSError:
            print(
                "WARN: could not set .env.local ownership or mode; fix by hand before rebuilding.",
                file=sys.stderr,
            )

    print("==> Created .env.local; edit it and rebuild to apply secrets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(initialize(Path.cwd()))
