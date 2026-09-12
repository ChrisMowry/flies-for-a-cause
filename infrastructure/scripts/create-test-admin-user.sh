#!/usr/bin/env bash
# Creates (or resets) a test administrator user in an environment's Cognito
# user pool, authenticates as that user, and prints the resulting JWTs -
# verifying Story 1.5's "create/invite an admin test user and successfully
# authenticate to receive a JWT" acceptance criterion end-to-end.
#
# For test/dev verification only. The password is passed as a CLI argument
# (visible in shell history/process list) - don't reuse a real credential.
#
# Usage: ./create-test-admin-user.sh <dev|prod> <email> <password>
# Example: ./create-test-admin-user.sh dev test-admin@example.com 'Tempp@ssw0rd123'

set -euo pipefail

ENVIRONMENT="${1:-}"
EMAIL="${2:-}"
PASSWORD="${3:-}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod> <email> <password>" >&2
  exit 1
fi

if [[ -z "${EMAIL}" || -z "${PASSWORD}" ]]; then
  echo "Usage: $0 <dev|prod> <email> <password>" >&2
  exit 1
fi

STACK_NAME="flies-for-a-cause-${ENVIRONMENT}-cognito"

USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

echo "Creating test admin user '${EMAIL}' in pool ${USER_POOL_ID} ..."

if aws cognito-idp admin-get-user --user-pool-id "${USER_POOL_ID}" --username "${EMAIL}" >/dev/null 2>&1; then
  echo "User already exists, skipping creation."
else
  aws cognito-idp admin-create-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --user-attributes Name=email,Value="${EMAIL}" Name=email_verified,Value=true \
    --message-action SUPPRESS
fi

echo "Setting permanent password ..."

aws cognito-idp admin-set-user-password \
  --user-pool-id "${USER_POOL_ID}" \
  --username "${EMAIL}" \
  --password "${PASSWORD}" \
  --permanent

echo "Authenticating as '${EMAIL}' ..."

aws cognito-idp admin-initiate-auth \
  --user-pool-id "${USER_POOL_ID}" \
  --client-id "${CLIENT_ID}" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${EMAIL},PASSWORD=${PASSWORD}"

echo "Authentication succeeded - JWTs (IdToken/AccessToken/RefreshToken) printed above."
