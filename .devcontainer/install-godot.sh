#!/usr/bin/env bash
# Install Godot 4 (headless, Linux x86_64) into /usr/local/bin/godot.
#
# Usage: install-godot.sh <version>
#   <version> example: 4.3-stable
#
# Source of truth:
#   https://github.com/godotengine/godot/releases/tag/<version>
set -euo pipefail

VERSION="${1:?Godot version required, e.g. 4.3-stable}"
ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64)  GODOT_ARCH="linux.x86_64" ;;
    aarch64) GODOT_ARCH="linux.arm64"  ;;
    *)
        echo "Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

ZIP_NAME="Godot_v${VERSION}_${GODOT_ARCH}.zip"
URL="https://github.com/godotengine/godot/releases/download/${VERSION}/${ZIP_NAME}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "==> Downloading ${URL}"
curl --fail --silent --show-error --location \
    --retry 5 --retry-delay 2 --retry-connrefused \
    --output "${TMPDIR}/godot.zip" \
    "${URL}"

echo "==> Verifying archive"
file_size="$(stat -c%s "${TMPDIR}/godot.zip")"
if [ "${file_size}" -lt 1000000 ]; then
    echo "Downloaded file is suspiciously small (${file_size} bytes)." >&2
    exit 1
fi
unzip -tq "${TMPDIR}/godot.zip" >/dev/null

echo "==> Installing to /usr/local/bin/godot"
unzip -q "${TMPDIR}/godot.zip" -d "${TMPDIR}/extracted"
BIN_PATH="$(find "${TMPDIR}/extracted" -maxdepth 2 -type f -name "Godot_v${VERSION}_*" | head -n1)"
if [ -z "${BIN_PATH}" ]; then
    echo "Could not locate Godot binary inside archive." >&2
    ls -R "${TMPDIR}/extracted" >&2
    exit 1
fi

install -m 0755 "${BIN_PATH}" /usr/local/bin/godot

echo "==> Verifying binary executes"
if ! /usr/local/bin/godot --headless --version >/tmp/godot-version.txt 2>&1; then
    echo "Godot binary failed to run:" >&2
    cat /tmp/godot-version.txt >&2 || true
    exit 1
fi
echo "==> Installed: $(cat /tmp/godot-version.txt)"
rm -f /tmp/godot-version.txt
