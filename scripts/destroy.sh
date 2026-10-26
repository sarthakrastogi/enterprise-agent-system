#!/usr/bin/env bash
# Tear everything down. Tags are irrelevant for destroy, so placeholders are passed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
(cd "$ROOT" && python3 -m eap.manifest > build/agents.json)
"$TF" -chdir="$ROOT/infra" destroy -var agent_image_tag=x -var mcp_image_tag=x "$@"
