# syntax=docker/dockerfile:1.7
# Signal Fish Godot Client — Dev Container image
#
# Base: Microsoft devcontainers base on Ubuntu 24.04 (Noble).
# Pinned by digest is preferred long-term; we pin by tag here for readability
# and let Renovate / manual review bump it. See:
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

# pipx — used to install pre-commit cleanly outside system Python.
# Installed system-wide (PIPX_HOME / PIPX_BIN_DIR set above) so all users
# share the same `pre-commit` on PATH regardless of the runtime UID.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pipx python3-venv; \
    rm -rf /var/lib/apt/lists/*; \
    pipx ensurepath --global || true; \
    PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install pre-commit

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
      org.opencontainers.image.description="Ubuntu 24.04 + Godot ${GODOT_VERSION} (headless) + PowerShell 7 + Python + Node LTS." \
      org.opencontainers.image.source="https://github.com/Ambiguous-Interactive/signal-fish-client-godot" \
      org.opencontainers.image.licenses="See repository LICENSE"
