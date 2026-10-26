#!/usr/bin/env bash
# Invite a user to the platform. Cognito emails them a temporary password.
#   scripts/create_user.sh alice@example.com           # employee
#   scripts/create_user.sh bob@example.com --admin     # employee + platform-admins
set -euo pipefail

EMAIL="${1:?usage: create_user.sh <email> [--admin]}"
ADMIN="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
POOL="$("$TF" -chdir="$ROOT/infra" output -raw cognito_user_pool_id)"
REGION="$("$TF" -chdir="$ROOT/infra" output -raw region)"

aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL" \
  --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --desired-delivery-mediums EMAIL >/dev/null

aws cognito-idp admin-add-user-to-group --region "$REGION" --user-pool-id "$POOL" \
  --username "$EMAIL" --group-name employees
if [[ "$ADMIN" == "--admin" ]]; then
  aws cognito-idp admin-add-user-to-group --region "$REGION" --user-pool-id "$POOL" \
    --username "$EMAIL" --group-name platform-admins
fi
echo "invited $EMAIL${ADMIN:+ (admin)}; they'll get a temporary password by email"
