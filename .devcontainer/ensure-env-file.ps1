# Host-side create-time guard for the dev container.
#
# devcontainer.json passes `.env.local` to `docker run --env-file`, and docker
# fails the whole container create when the file is missing. This script -
# invoked by `initializeCommand` before the container exists - materializes
# `.env.local` from the committed `.env.example` so a fresh clone opens the
# container without a manual pre-step. Placeholder values are inert: MCP
# servers that need secrets fail loudly at launch, never at container create.
# Never overwrites an existing `.env.local`.

$ErrorActionPreference = 'Stop'

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$example = Join-Path $workspaceRoot '.env.example'
$envFile = Join-Path $workspaceRoot '.env.local'

if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    exit 0
}

if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
    Write-Error "ensure-env-file: $example is missing; cannot create .env.local. Create .env.local manually (see .devcontainer/README.md)."
    exit 1
}

Copy-Item -LiteralPath $example -Destination $envFile
Write-Host "==> Created .env.local from .env.example (placeholder values; edit it and rebuild to apply secrets)"
exit 0