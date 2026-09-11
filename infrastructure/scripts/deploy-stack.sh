#!/usr/bin/env bash
# Deploys a CloudFormation template for a given environment, using this
# project's stack naming and tagging conventions.
#
# Usage: ./deploy-stack.sh <dev|prod> <template-name> [additional --parameter-overrides key=value ...]
# Example: ./deploy-stack.sh dev base

set -euo pipefail

ENVIRONMENT="${1:-}"
TEMPLATE_NAME="${2:-}"
shift 2 || true

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod> <template-name> [--parameter-overrides key=value ...]" >&2
  exit 1
fi

if [[ -z "${TEMPLATE_NAME}" ]]; then
  echo "Usage: $0 <dev|prod> <template-name> [--parameter-overrides key=value ...]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/../cloudformation/${TEMPLATE_NAME}.yaml"
STACK_NAME="flies-for-a-cause-${ENVIRONMENT}-${TEMPLATE_NAME}"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Template not found: ${TEMPLATE_FILE}" >&2
  exit 1
fi

echo "Deploying stack '${STACK_NAME}' from ${TEMPLATE_FILE} ..."

aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameter-overrides "Environment=${ENVIRONMENT}" "$@" \
  --tags "Project=FliesForACause" "Environment=${ENVIRONMENT}" "ManagedBy=CloudFormation" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

echo "Stack '${STACK_NAME}' deployed successfully."
