#!/usr/bin/env bash
# Install Godot 4 (headless, Linux x86_64) into /usr/local/bin/godot.
#
# Usage: install-godot.sh <version> [cache-dir]
#   <version> example: 4.3-stable
#   [cache-dir] optional download cache (the Dockerfile passes a BuildKit
#               cache mount so rebuilds do not re-download the ~60 MB zip).
#
# Source of truth:
#   https://github.com/godotengine/godot/releases/tag/<version>
set -euo pipefail

VERSION="${1:?Godot version required, e.g. 4.3-stable}"
CACHE_DIR="${2:-}"
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

ZIP_PATH="${TMPDIR}/godot.zip"
if [ -n "${CACHE_DIR}" ]; then
    mkdir -p "${CACHE_DIR}" || { echo "Cannot create cache dir ${CACHE_DIR}" >&2; exit 1; }
    ZIP_PATH="${CACHE_DIR}/${ZIP_NAME}"
fi

# A cached copy is only trusted after the same checks a fresh download gets:
# size floor plus zip integrity. A partial or corrupt transfer must never be
# reused (or cached as good).
if [ -f "${ZIP_PATH}" ] \
    && [ "$(stat -c%s "${ZIP_PATH}")" -ge 1000000 ] \
    && unzip -tq "${ZIP_PATH}" >/dev/null 2>&1; then
    echo "==> Using cached ${ZIP_PATH}"
else
    echo "==> Downloading ${URL}"
    [ -z "${CACHE_DIR}" ] || rm -f "${ZIP_PATH}"
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        --output "${ZIP_PATH}" \
        "${URL}"
fi

echo "==> Verifying archive"
file_size="$(stat -c%s "${ZIP_PATH}")"
if [ "${file_size}" -lt 1000000 ]; then
    echo "Downloaded file is suspiciously small (${file_size} bytes)." >&2
    exit 1
fi
unzip -tq "${ZIP_PATH}" >/dev/null

echo "==> Installing to /usr/local/bin/godot"
unzip -q "${ZIP_PATH}" -d "${TMPDIR}/extracted"
BIN_PATH="$(find "${TMPDIR}/extracted" -maxdepth 2 -type f -name "Godot_v${VERSION}_*" | head -n1)"
if [ -z "${BIN_PATH}" ]; then
    echo "Could not locate Godot binary inside archive." >&2
    ls -R "${TMPDIR}/extracted" >&2
    exit 1
fi

install -m 0755 "${BIN_PATH}" /usr/local/bin/godot

echo "==> Verifying binary executes"
GODOT_VERSION_OUTPUT="${TMPDIR}/godot-version.txt"
if ! /usr/local/bin/godot --headless --version >"${GODOT_VERSION_OUTPUT}" 2>&1; then
    echo "Godot binary failed to run:" >&2
    cat "${GODOT_VERSION_OUTPUT}" >&2 || true
    exit 1
fi
echo "==> Installed: $(cat "${GODOT_VERSION_OUTPUT}")"
