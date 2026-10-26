#!/usr/bin/env bash
# Write frontend/.streamlit/secrets.toml from Terraform outputs.
# Re-run after adding agents. The file holds the Cognito client secret; it is git-ignored.
#   UI_URL=https://agents.example.com scripts/configure_frontend.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
OUT="$ROOT/frontend/.streamlit/secrets.toml"

mkdir -p "$(dirname "$OUT")"
umask 077
"$TF" -chdir="$ROOT/infra" output -json | python3 "$ROOT/scripts/frontend_config.py" > "$OUT"
echo "wrote $OUT"
