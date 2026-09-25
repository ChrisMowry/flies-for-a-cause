#!/usr/bin/env bash
# Builds the Vite/React/TypeScript UI for a given environment and publishes it
# to that environment's website bucket, then invalidates the CloudFront cache.
#
# Environment-specific configuration (API base URL, Cognito pool/client IDs)
# is read from SSM Parameter Store at build time (published by base.yaml and
# cognito.yaml) and injected into the bundle as VITE_* variables, so nothing
# environment-specific is committed to source control. The bucket name and
# distribution ID come from the hosting stack's outputs.
#
# Requires AWS credentials for the target environment, Node.js, and npm.
#
# Usage: ./deploy-ui.sh <dev|prod>
# Example: ./deploy-ui.sh dev

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="${SCRIPT_DIR}/../../ui"
HOSTING_STACK="flies-for-a-cause-${ENVIRONMENT}-hosting"
PARAMETER_PREFIX="/flies-for-a-cause/${ENVIRONMENT}"

if [[ ! -f "${UI_DIR}/package.json" ]]; then
  echo "UI project not found: expected ${UI_DIR}/package.json" >&2
  exit 1
fi

get_parameter() {
  aws ssm get-parameter --name "${PARAMETER_PREFIX}/$1" \
    --query "Parameter.Value" --output text
}

get_hosting_output() {
  aws cloudformation describe-stacks --stack-name "${HOSTING_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

echo "Reading ${ENVIRONMENT} configuration ..."
API_DOMAIN_NAME="$(get_parameter api-domain-name)"
export VITE_API_BASE_URL="https://${API_DOMAIN_NAME}"
export VITE_COGNITO_USER_POOL_ID="$(get_parameter cognito/user-pool-id)"
export VITE_COGNITO_USER_POOL_CLIENT_ID="$(get_parameter cognito/user-pool-client-id)"
export VITE_ENVIRONMENT="${ENVIRONMENT}"

BUCKET="$(get_hosting_output WebsiteBucketName)"
DISTRIBUTION_ID="$(get_hosting_output WebsiteDistributionId)"

if [[ -z "${BUCKET}" || -z "${DISTRIBUTION_ID}" ]]; then
  echo "Could not read the bucket name / distribution ID from stack '${HOSTING_STACK}' - has hosting.yaml been deployed for ${ENVIRONMENT}?" >&2
  exit 1
fi

cd "${UI_DIR}"

echo "Installing dependencies ..."
npm ci

echo "Building the production bundle ..."
npm run build

if [[ ! -f dist/index.html ]]; then
  echo "Build did not produce dist/index.html" >&2
  exit 1
fi

echo "Publishing dist/ to s3://${BUCKET} ..."

# Vite content-hashes everything under assets/, so those files are safe to
# cache forever. They're uploaded first (and never deleted here - an open tab
# still running the previous build keeps working) so the new index.html never
# references a file that isn't there yet.
aws s3 sync dist/assets "s3://${BUCKET}/assets" \
  --cache-control "public,max-age=31536000,immutable"

# Everything else (index.html, favicon, ...) keeps a stable name, so CloudFront
# and browsers must revalidate it. --delete removes files dropped from the
# build (the bucket is versioned, so this is recoverable); the assets/ prefix
# is excluded so it's left alone.
aws s3 sync dist "s3://${BUCKET}" \
  --exclude "assets/*" \
  --delete \
  --cache-control "no-cache"

echo "Invalidating CloudFront distribution ${DISTRIBUTION_ID} ..."
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths "/*" \
  --query "Invalidation.Id" --output text)"

aws cloudfront wait invalidation-completed \
  --distribution-id "${DISTRIBUTION_ID}" \
  --id "${INVALIDATION_ID}"

echo "UI deployed to the ${ENVIRONMENT} environment."
