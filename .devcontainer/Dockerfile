# syntax=docker/dockerfile:1.7
# Signal Fish Godot Client — Dev Container image
#
# Base: Microsoft devcontainers base on Ubuntu 24.04 (Noble).
# Pinned by digest is preferred long-term; we pin by tag here for readability
# and let Dependabot / manual review bump it. See:
#   https://github.com/devcontainers/images/tree/main/src/base-ubuntu
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG GODOT_VERSION=4.3-stable
ARG GODOT_RELEASE_LABEL=4.3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    GODOT_VERSION=${GODOT_VERSION} \
    PIPX_HOME=/usr/local/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    PATH=/usr/local/bin:${PATH}

# System packages required by Godot headless and project tooling.
# Keep this list small and explainable.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        xz-utils \
        gnupg \
        jq \
        less \
        locales \
        # Godot runtime/native libs (headless still links many of these)
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
    ; \
    rm -rf /var/lib/apt/lists/*

# Install Godot 4 editor binary (runs headless via the `--headless` flag).
# Source: https://github.com/godotengine/godot/releases
# We verify HTTPS + size + zip integrity + binary executability; SHA256 is not
# pinned here to keep this readable — downstream users may pin via
# SHA256SUMS.txt from the same release page.
#
# COPY paths are relative to the build context (`.devcontainer/`), set by
# devcontainer.json (`"context": "."` with this Dockerfile alongside).
COPY install-godot.sh /usr/local/bin/install-godot.sh
RUN chmod +x /usr/local/bin/install-godot.sh \
    && /usr/local/bin/install-godot.sh "${GODOT_VERSION}" \
    && rm /usr/local/bin/install-godot.sh

# Optional compatibility tooling: install the pre-commit CLI cleanly outside
# system Python so users can manually run `.pre-commit-config.yaml` if desired.
# The canonical hook is still the direct shim installed by post-create into the
# path from `git rev-parse --git-path hooks`; the devcontainer must not run `pre-commit install`.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pipx python3-venv; \
    rm -rf /var/lib/apt/lists/*; \
    pipx ensurepath --global || true; \
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
RUN set -euxo pipefail; \
    chmod +x /usr/local/bin/sf-github-mcp; \
    case "$(dpkg --print-architecture)" in \
        amd64) GH_MCP_ARCH=x86_64 ;; \
        arm64) GH_MCP_ARCH=arm64 ;; \
        *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    # The archive keeps its canonical asset name: the checksums file lists
    # that name, and `sha256sum -c` resolves entries relative to the cwd.
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused \
        --output "/tmp/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz" \
        "https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}/github-mcp-server_Linux_${GH_MCP_ARCH}.tar.gz"; \
    curl --fail --silent --show-error --location \
        --retry 5 --retry-delay 2 --retry-connrefused \
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
RUN --mount=type=cache,target=/var/cache/godot-templates \
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
