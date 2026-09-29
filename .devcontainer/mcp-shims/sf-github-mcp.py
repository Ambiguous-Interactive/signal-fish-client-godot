#!/usr/bin/env python3
"""Launcher shim for GitHub's official MCP server (github-mcp-server).

Every agent configuration in this repo points at this shim by name rather
than at the binary directly, so the token is read from the shim's inherited
environment at launch time and is never written into any configuration
file. The shim maps the repo's GITHUB_MCP_PAT convention (see .env.example)
onto the binary's canonical GITHUB_PERSONAL_ACCESS_TOKEN.

Installed to /usr/local/bin/sf-github-mcp by the dev container Dockerfile.
"""

import os
import sys

SERVER = "/usr/local/bin/github-mcp-server"


def fail(message: str) -> None:
    print(f"sf-github-mcp: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    token = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN") or os.environ.get("GITHUB_MCP_PAT") or ""
    if "${" in token:
        # A client that did not expand ${GITHUB_MCP_PAT:-} hands us the
        # literal text; that must fail loudly, not authenticate with garbage.
        fail(
            "token is an unexpanded variable reference; this client does not"
            " substitute ${VAR} in .mcp.json env maps"
        )
    if not token:
        fail(
            "no token found; set GITHUB_MCP_PAT in .env.local (see .env.example) and rebuild the container"
        )
    os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = token
    # Read-only by default; opt out with GITHUB_READ_ONLY=0 in .env.local.
    os.environ.setdefault("GITHUB_READ_ONLY", "1")
    os.execv(SERVER, [SERVER, "stdio"])  # noqa: S606


if __name__ == "__main__":
    main()
