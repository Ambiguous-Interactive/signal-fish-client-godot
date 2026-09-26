#!/usr/bin/env bash
# Install Godot export templates (web subset) for the pinned engine version.
#
# Usage: install-godot-templates.sh <version> <cache-dir> <templates-root>
#   <version>        Godot release tag, e.g. 4.3-stable (same value passed to
#                    install-godot.sh)
#   <cache-dir>      Download cache directory. The Dockerfile passes a
#                    BuildKit cache mount so rebuilds do not re-download the
#                    ~900 MB template archive.
#   <templates-root> Export templates root, e.g.
#                    /home/vscode/.local/share/godot/export_templates
#
# The upstream release ships one archive for every platform
# (Godot_v<version>_export_templates.tpz); this script downloads it once,
# then extracts only the web templates so the image carries megabytes, not
# the full multi-gigabyte set. Only web is needed because the repo's only
# export preset is "Web" (export_presets.cfg, web-export-smoke.yml).
#
# Source of truth:
#   https://github.com/godotengine/godot/releases/tag/<version>
set -euo pipefail

VERSION="${1:?Godot version required, e.g. 4.3-stable}"
CACHE_DIR="${2:?Download cache directory required}"
TEMPLATES_ROOT="${3:?Export templates root required}"

ZIP_NAME="Godot_v${VERSION}_export_templates.tpz"
URL="https://github.com/godotengine/godot/releases/download/${VERSION}/${ZIP_NAME}"

mkdir -p "${CACHE_DIR}"
CACHED_TGZ="${CACHE_DIR}/${ZIP_NAME}"

if [ -f "${CACHED_TGZ}" ] && unzip -tq "${CACHED_TGZ}" >/dev/null 2>&1; then
    echo "==> Using cached ${ZIP_NAME}"
else
    echo "==> Downloading ${URL}"
    rm -f "${CACHED_TGZ}"
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        --output "${CACHED_TGZ}" \
        "${URL}"
fi

echo "==> Verifying archive"
# A partial download must never be cached as good: the size floor catches
# truncated transfers and the zip test catches corrupt ones before the
# archive is accepted into the cache.
file_size="$(stat -c%s "${CACHED_TGZ}")"
if [ "${file_size}" -lt 100000000 ]; then
    echo "Downloaded archive is suspiciously small (${file_size} bytes)." >&2
    exit 1
fi
unzip -tq "${CACHED_TGZ}" >/dev/null

# The templates directory must be named after the editor's own version
# string ("4.3-stable" tag installs into "4.3.stable"), or the editor
# silently reports templates as missing. Derive it from the installed
# editor ("4.3.stable.official.<hash>" -> "4.3.stable") so the two installs
# can never drift; fall back to munging the tag if no editor is on PATH.
EDITOR_VERSION="$(godot --version 2>/dev/null || true)"
if [ -n "${EDITOR_VERSION}" ]; then
    VERSION_DIR="${EDITOR_VERSION%%.official*}"
else
    VERSION_DIR="${VERSION%-stable}.stable"
fi

TARGET_DIR="${TEMPLATES_ROOT}/${VERSION_DIR}"
echo "==> Extracting web templates into ${TARGET_DIR}"
SF_TMP="$(mktemp -d)"
trap 'rm -rf "${SF_TMP}"' EXIT
# -j junk paths: the archive nests everything under templates/.
unzip -q -j "${CACHED_TGZ}" 'templates/web_*' -d "${SF_TMP}"

mkdir -p "${TARGET_DIR}"
found=0
for template in "${SF_TMP}"/web_*; do
    [ -f "${template}" ] || continue
    install -m 0644 "${template}" "${TARGET_DIR}/$(basename "${template}")"
    found=1
done
if [ "${found}" -ne 1 ]; then
    echo "No web templates found in ${ZIP_NAME}; archive layout may have changed." >&2
    exit 1
fi

echo "==> Installed web templates for ${VERSION_DIR}:"
ls -lh "${TARGET_DIR}"
