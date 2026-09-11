#!/usr/bin/env bash
# Deletes a previously deployed CloudFormation stack for a given environment
# and waits for deletion to complete, so cleanup is scripted and repeatable
# rather than a manual console step.
#
# Usage: ./delete-stack.sh <dev|prod> <template-name>
# Example: ./delete-stack.sh dev base

set -euo pipefail

ENVIRONMENT="${1:-}"
TEMPLATE_NAME="${2:-}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod> <template-name>" >&2
  exit 1
fi

if [[ -z "${TEMPLATE_NAME}" ]]; then
  echo "Usage: $0 <dev|prod> <template-name>" >&2
  exit 1
fi

STACK_NAME="flies-for-a-cause-${ENVIRONMENT}-${TEMPLATE_NAME}"

echo "Deleting stack '${STACK_NAME}' ..."

aws cloudformation delete-stack --stack-name "${STACK_NAME}"

echo "Waiting for stack '${STACK_NAME}' to finish deleting ..."

aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"

echo "Stack '${STACK_NAME}' deleted successfully."
