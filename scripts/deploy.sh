#!/usr/bin/env bash
# Deploy the whole platform from your machine. No CI required.
#
#   scripts/deploy.sh            # plan + confirm + apply
#   AUTO_APPROVE=1 scripts/deploy.sh
#
# Needs: terraform >= 1.10, docker with buildx (arm64 builds), aws CLI v2, python3 >= 3.10,
# and AWS credentials for the target account in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA="$ROOT/infra"
TF="${TERRAFORM:-terraform}"
APPROVE=()
[[ "${AUTO_APPROVE:-0}" == "1" ]] && APPROVE=(-auto-approve)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for bin in "$TF" docker aws python3; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done
docker buildx version >/dev/null || { echo "docker buildx is required for arm64 images" >&2; exit 1; }

log "Validating agent definitions"
mkdir -p "$ROOT/build"
(cd "$ROOT" && python3 -m eap.manifest > build/agents.json)
python3 -c "import json,sys; print('agents:', ', '.join(json.load(open(sys.argv[1]))))" "$ROOT/build/agents.json"

# Content-addressed tags: an image is rebuilt only when its inputs change, and a
# new tag gives the runtime a new immutable version.
hash_of() { (cd "$ROOT" && find "$@" -type f -not -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12); }
AGENT_TAG="a-$(hash_of pyproject.toml README.md eap agents runtime/Dockerfile)"
MCP_TAG="m-$(hash_of mcp_servers/knowledge)"
TF_VARS=(-var "agent_image_tag=$AGENT_TAG" -var "mcp_image_tag=$MCP_TAG")

log "Terraform init"
"$TF" -chdir="$INFRA" init -input=false

log "Creating ECR repositories (first run only)"
"$TF" -chdir="$INFRA" apply -input=false "${APPROVE[@]}" "${TF_VARS[@]}" \
  -target=aws_ecr_repository.agent_runtime -target=aws_ecr_repository.mcp_knowledge

repo_url() { "$TF" -chdir="$INFRA" state show -no-color "$1" | awk -F'"' '$1 ~ /^ *repository_url/ {print $2}'; }
AGENT_REPO="$(repo_url aws_ecr_repository.agent_runtime)"
MCP_REPO="$(repo_url aws_ecr_repository.mcp_knowledge)"
REGISTRY="${AGENT_REPO%%/*}"                 # <account>.dkr.ecr.<region>.amazonaws.com
REGION="$(cut -d. -f4 <<<"$REGISTRY")"

log "Logging in to ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() { # repo tag dockerfile context
  local repo="$1" tag="$2" dockerfile="$3" context="$4" name="${1#*/}"
  if aws ecr describe-images --region "$REGION" --repository-name "$name" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "$repo:$tag already exists, skipping build"
    return
  fi
  log "Building $repo:$tag (linux/arm64)"
  docker buildx build --platform linux/arm64 --provenance=false -f "$dockerfile" -t "$repo:$tag" --push "$context"
}
build_push "$AGENT_REPO" "$AGENT_TAG" "$ROOT/runtime/Dockerfile" "$ROOT"
build_push "$MCP_REPO" "$MCP_TAG" "$ROOT/mcp_servers/knowledge/Dockerfile" "$ROOT/mcp_servers/knowledge"

log "Applying platform"
"$TF" -chdir="$INFRA" apply -input=false "${APPROVE[@]}" "${TF_VARS[@]}"

log "Writing chat UI config"
"$ROOT/scripts/configure_frontend.sh"

cat <<EOF

Done.
  1. Create a user:   scripts/create_user.sh you@example.com [--admin]
  2. Start the UI:    make ui    (http://localhost:8501)
  3. Dashboard:       $("$TF" -chdir="$INFRA" output -raw dashboard_url)
EOF
