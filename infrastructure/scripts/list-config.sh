#!/usr/bin/env bash
# Lists every configuration parameter and secret stored for a given
# environment in SSM Parameter Store (/flies-for-a-cause/<env>/...). Plain
# configuration values are shown; secrets (SecureString) are listed by name
# only - their values are never printed.
#
# Usage: ./list-config.sh <dev|prod>
# Example: ./list-config.sh dev

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi

# Without --with-decryption a SecureString's value comes back as ciphertext;
# it's masked below regardless, so it's never shown.
aws ssm get-parameters-by-path \
  --path "/flies-for-a-cause/${ENVIRONMENT}" \
  --recursive \
  --query "Parameters[].[Name,Type,Value]" \
  --output text |
  while IFS=$'\t' read -r name type value; do
    if [[ "${type}" == "SecureString" ]]; then
      printf '%s\t(secret)\n' "${name}"
    else
      printf '%s\t%s\n' "${name}" "${value}"
    fi
  done |
  sort
