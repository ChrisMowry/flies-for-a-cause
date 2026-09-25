#!/usr/bin/env bash
# Stores a secret (e.g. a third-party API key) for a given environment as an
# encrypted SecureString parameter in SSM Parameter Store, at
#   /flies-for-a-cause/<env>/secrets/<consumer>/<name>
# where <consumer> is the Lambda that reads it. CloudFormation can't create
# SecureString parameters, and a secret's value must never be in a template
# or in source control, so this is the one place secrets are written - out of
# band, by hand. Re-running it for an existing secret replaces its value.
#
# The value is read from stdin when piped, or prompted for without echo when
# run interactively, so it never appears on the command line or in shell
# history. It is handed to the AWS CLI through a private temporary file that
# is deleted on exit.
#
# Usage: ./set-secret.sh <dev|prod> <website|scraper|post-processor> <secret-name>
# Example: ./set-secret.sh dev scraper instagram-access-token
#          printf '%s' "$TOKEN" | ./set-secret.sh dev scraper instagram-access-token

set -euo pipefail

ENVIRONMENT="${1:-}"
CONSUMER="${2:-}"
SECRET_NAME="${3:-}"

USAGE="Usage: $0 <dev|prod> <website|scraper|post-processor> <secret-name>"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "${USAGE}" >&2
  exit 1
fi

if [[ "${CONSUMER}" != "website" && "${CONSUMER}" != "scraper" && "${CONSUMER}" != "post-processor" ]]; then
  echo "${USAGE}" >&2
  exit 1
fi

if [[ ! "${SECRET_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "Secret name must be lowercase letters, digits, and hyphens (e.g. instagram-access-token)." >&2
  echo "${USAGE}" >&2
  exit 1
fi

PARAMETER_NAME="/flies-for-a-cause/${ENVIRONMENT}/secrets/${CONSUMER}/${SECRET_NAME}"

if [[ -t 0 ]]; then
  read -r -s -p "Value for ${PARAMETER_NAME}: " SECRET_VALUE
  echo
else
  SECRET_VALUE="$(cat)"
fi

if [[ -z "${SECRET_VALUE}" ]]; then
  echo "The secret value is empty - nothing stored." >&2
  exit 1
fi

umask 077
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
printf '%s' "${SECRET_VALUE}" > "${WORK_DIR}/value"
unset SECRET_VALUE

# The AWS CLI is a native program: on Git Bash for Windows it needs a
# Windows-style path to read the file.
VALUE_FILE="${WORK_DIR}/value"
if command -v cygpath >/dev/null 2>&1; then
  VALUE_FILE="$(cygpath -m "${VALUE_FILE}")"
fi

aws ssm put-parameter \
  --name "${PARAMETER_NAME}" \
  --type SecureString \
  --overwrite \
  --description "Secret '${SECRET_NAME}' for the ${CONSUMER} Lambda (${ENVIRONMENT}). Set with scripts/set-secret.sh." \
  --value "file://${VALUE_FILE}" >/dev/null

# put-parameter can't set tags when overwriting, so tag separately.
aws ssm add-tags-to-resource \
  --resource-type Parameter \
  --resource-id "${PARAMETER_NAME}" \
  --tags "Key=Project,Value=FliesForACause" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=set-secret.sh"

echo "Stored ${PARAMETER_NAME}."
