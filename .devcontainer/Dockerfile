# syntax=docker/dockerfile:1.7
# Signal Fish Godot Client — Dev Container image
#
# Base: Microsoft devcontainers base on Ubuntu 24.04 (Noble).
# Pinned by digest is preferred long-term; we pin by tag here for readability
# and let Dependabot / manual review bump it. See:
#   https://github.com/devcontainers/images/tree/main/src/base-ubuntu
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Run every RUN step under bash with pipefail. The default shell is /bin/sh,
# which is dash on Ubuntu: dash rejects `set -o pipefail` outright
# ("set: Illegal option -o pipefail"), which aborted the whole image build at
# the first RUN that used it. bash is present in this base image.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG GODOT_VERSION=4.3-stable
ARG GODOT_RELEASE_LABEL=4.3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    GODOT_VERSION=${GODOT_VERSION} \
    PIPX_HOME=/usr/local/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    PATH=/usr/local/bin:${PATH}

# System packages required by Godot headless, the project tooling, and the
# Python toolchain below (merged here so the whole build pays for exactly one
# apt transaction). Python comes from Ubuntu apt (3.12; docs CI pins 3.12
# and runtime CI tracks 3.x) instead of the python devcontainer feature,
# whose standalone-python download added ~2.5 minutes to every no-cache
# rebuild.
# BuildKit cache mounts persist the package indexes and .deb archives across
# builds - including `--no-cache` full rebuilds - so only the first build
# pays for the downloads, and /var/lib/apt/lists never lands in an image
# layer. If a warm cache ever goes stale, the install retry refreshes the
# indexes once and tries again.
# Keep PKGS a plain word list: Docker strips full-line comments before the
# shell runs, so a comment here cannot document the list at all - grouping
# notes live in the block comment above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    PKGS="\
        ca-certificates \
        curl \
        unzip \
        xz-utils \
        gnupg \
        jq \
        less \
        locales \
        pipx \
        python3 \
        python3-pip \
        python3-venv \
        python-is-python3 \
        libfontconfig1 \
        libfreetype6 \
        libx11-6 \
        libxcursor1 \
        libxext6 \
        libxi6 \
        libxinerama1 \
        libxrandr2 \
        libgl1 \
        libglu1-mesa \
        libasound2t64 \
        libpulse0 \
        libdbus-1-3 \
        libudev1 \
    "; \
    if [ -n "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then \
        echo "==> apt indexes cached; skipping apt-get update"; \
    else \
        apt-get update; \
    fi; \
    apt-get install -y --no-install-recommends ${PKGS} \
        || { echo "==> apt install failed; refreshing indexes and retrying"; \
             apt-get update; \
             apt-get install -y --no-install-recommends ${PKGS}; }

# Install Godot 4 editor binary (runs headless via the `--headless` flag).
# Source: https://github.com/godotengine/godot/releases
# We verify HTTPS + size + zip integrity + binary executability; SHA256 is not
# pinned here to keep this readable — downstream users may pin via
# SHA256SUMS.txt from the same release page.
#
# COPY paths are relative to the build context (`.devcontainer/`), set by
# devcontainer.json (`"context": "."` with this Dockerfile alongside).
COPY install-godot.sh /usr/local/bin/install-godot.sh
# The editor zip (~60 MB) is downloaded through a BuildKit cache mount so
# rebuilds - including `--no-cache` - do not re-fetch it.
RUN --mount=type=cache,target=/var/cache/godot-editor,sharing=locked \
    chmod +x /usr/local/bin/install-godot.sh \
    && /usr/local/bin/install-godot.sh "${GODOT_VERSION}" /var/cache/godot-editor \
    && rm /usr/local/bin/install-godot.sh

# Ubuntu's Python enforces PEP 668 (EXTERNALLY-MANAGED), which blocks the
# user-site installs that post-start.sh uses to heal the local automation
# gates. CI runner images ship their Python globally without that marker, so
# this keeps the local gate on the same install path as CI.
RUN printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf

# Optional compatibility tooling: install the pre-commit CLI cleanly outside
# system Python so users can manually run `.pre-commit-config.yaml` if desired.
# The canonical hook is still the direct shim installed by post-create into the
# path from `git rev-parse --git-path hooks`; the devcontainer must not run `pre-commit install`.
# (pipx itself and python3-venv come from the apt layer above.)
# pipx/pip download caches are cache-mounted so rebuilds - including
# `--no-cache` - reuse already-fetched wheels instead of re-downloading them.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=type=cache,target=/root/.cache/pipx,sharing=locked \
    set -eux; \
    PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install pre-commit

# MCP servers that do not depend on the Node devcontainer feature (which is
# layered on *after* this image; those live in install-mcp-servers.sh).
# All versions pinned; see .devcontainer/README.md ("MCP servers").
# GitHub's official server runs as a native binary because the upstream
# Docker image would require Docker-in-Docker inside this container.
ARG GITHUB_MCP_VERSION=1.12.2
ARG MCP_SERVER_GIT_VERSION=2026.8.18
ARG MCP_SERVER_FETCH_VERSION=2026.8.18
COPY mcp-shims/sf-github-mcp.sh /usr/local/bin/sf-github-mcp
# pipx/pip download caches are cache-mounted (same rationale as the
# pre-commit layer above): warm rebuilds reuse fetched wheels.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=type=cache,target=/root/.cache/pipx,sharing=locked \
    set -euxo pipefail; \
    chmod +x /usr/local/bin/sf-github-mcp; \
    case "$(dpkg --print-architecture)" in \
        amd64) GH_MCP_ARCH=x86_64 ;; \
        arm64) GH_MCP_ARCH=arm64 ;; \
        *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    # The archive keeps its canonical asset name: the checksums file lists
    # that name, and `sha256sum -c` resolves entries relative to the cwd.
    # --retry-all-errors: plain --retry does not retry most HTTP-level
    # failures (proxy resets, transient 4xx), which is where flaky networks
    # actually fail.
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        --output "/tmp/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz" \
        "https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz"; \
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        --output /tmp/gh-mcp-checksums.txt \
        "https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}/github-mcp-server_${GITHUB_MCP_VERSION}_checksums.txt"; \
    grep "github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz" /tmp/gh-mcp-checksums.txt \
        | (cd /tmp && sha256sum -c -); \
    tar -xzf "/tmp/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz" -C /usr/local/bin github-mcp-server; \
    rm -f "/tmp/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz" /tmp/gh-mcp-checksums.txt; \
    /usr/local/bin/github-mcp-server --version; \
    PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install "mcp-server-git==${MCP_SERVER_GIT_VERSION}"; \
    PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install "mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"; \
    mcp-server-git --help >/dev/null; \
    mcp-server-fetch --help >/dev/null

# Web export templates (the only platform this repo exports; see
# export_presets.cfg and web-export-smoke.yml). The archive is downloaded
# through a BuildKit cache mount so rebuilds do not re-fetch ~900 MB, and
# only the web templates are extracted into the image. Must run after
# install-godot.sh: the templates directory is named after the installed
# editor's own version string.
COPY install-godot-templates.sh /usr/local/bin/install-godot-templates.sh
# The templates script runs as root and creates the ~/.local parent chain;
# hand the whole subtree back to the container user or every later
# user-level write under ~/.local fails with EACCES.
RUN --mount=type=cache,target=/var/cache/godot-templates,sharing=locked \
    chmod +x /usr/local/bin/install-godot-templates.sh \
    && /usr/local/bin/install-godot-templates.sh "${GODOT_VERSION}" \
        /var/cache/godot-templates \
        /home/vscode/.local/share/godot/export_templates \
    && rm /usr/local/bin/install-godot-templates.sh \
    && chown -R vscode:vscode /home/vscode/.local

# Persist bash history via mounted volume (`/commandhistory`, declared in
# devcontainer.json `mounts`). The PowerShell profile that persists pwsh
# history is installed by post-create.sh, since the PowerShell feature lays
# down /opt/microsoft/powershell/7/ *after* this Dockerfile finishes building.
RUN set -eux; \
    mkdir -p /commandhistory; \
    touch /commandhistory/.bash_history /commandhistory/pwsh_history.txt; \
    chown -R vscode:vscode /commandhistory; \
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc

# Friendlier defaults
RUN echo 'export PAGER=less' >> /etc/profile.d/sf-defaults.sh \
    && echo 'export LESS="-R -F -X"' >> /etc/profile.d/sf-defaults.sh

USER vscode
WORKDIR /workspaces

LABEL org.opencontainers.image.title="Signal Fish Godot Client Dev Container" \
      org.opencontainers.image.description="Ubuntu 24.04 + Godot ${GODOT_VERSION} (headless, web export templates) + PowerShell 7 + Python + Node LTS + MCP servers." \
      org.opencontainers.image.source="https://github.com/Ambiguous-Interactive/signal-fish-client-godot" \
      org.opencontainers.image.licenses="See repository LICENSE"
