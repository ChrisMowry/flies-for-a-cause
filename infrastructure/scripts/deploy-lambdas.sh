#!/usr/bin/env bash
# Tests, packages, and deploys the project's Lambda functions and the shared
# data-access layer for a given environment.
#
# Repository layout (see infrastructure/README.md for the full contract):
#   layers/shared/       Node/TypeScript shared data-access layer (optional)
#   lambdas/<name>/      One directory per function: Node/TypeScript
#                        (package.json) or Python (requirements.txt)
#
# Each lambdas/<name>/ is deployed to the function
# flies-for-a-cause-<env>-<name> (e.g. lambdas/website ->
# flies-for-a-cause-dev-website), and layers/shared is published as the layer
# flies-for-a-cause-<env>-shared. The functions must already exist (they are
# defined in CloudFormation) - this script only ships new code.
#
# Everything is tested and built first, and nothing is written to AWS until
# every component has passed, so a failing test blocks the whole deploy. The
# layer is then published as a new version and attached to the functions that
# consume it, before their code is updated. Each update is atomic, so
# invocations are never dropped; layer changes should stay backward
# compatible with the function code that's currently deployed.
#
# Requires AWS credentials for the target environment, Node.js/npm, Python 3,
# and zip. Intended for CI, Linux, macOS, or WSL.
#
# Usage: ./deploy-lambdas.sh <dev|prod>
# Example: ./deploy-lambdas.sh dev

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAMBDAS_DIR="${REPO_ROOT}/lambdas"
LAYER_DIR="${REPO_ROOT}/layers/shared"

NAME_PREFIX="flies-for-a-cause-${ENVIRONMENT}"
LAYER_NAME="${NAME_PREFIX}-shared"

# Functions that consume the shared layer (the Website and Social Media Post
# Processor Lambdas share it - Epic 2, Story 2.10).
LAYER_CONSUMERS=("website" "post-processor")

if ! command -v zip >/dev/null 2>&1; then
  echo "'zip' is required but was not found on PATH." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/zips"

# --- Helpers -----------------------------------------------------------------

zip_dir() {
  local source_dir="$1" output_zip="$2"
  (cd "${source_dir}" && zip -qr "${output_zip}" .)
}

is_layer_consumer() {
  local candidate
  for candidate in "${LAYER_CONSUMERS[@]}"; do
    [[ "${candidate}" == "$1" ]] && return 0
  done
  return 1
}

# Runs the component's tests (if it has any) and builds its deployment zip.
# Node components must define `npm run build` producing a self-contained
# dist/ (bundled), and may define `npm test`.
build_node_lambda() {
  local name="$1" dir="$2"
  (
    cd "${dir}"
    npm ci
    npm test --if-present
    npm run build
  )
  if [[ ! -d "${dir}/dist" ]]; then
    echo "Build of lambdas/${name} did not produce a dist/ directory" >&2
    return 1
  fi
  zip_dir "${dir}/dist" "${WORK_DIR}/zips/${name}.zip"
}

# Python components list dependencies in requirements.txt (may be empty) and
# may have a tests/ directory, run with pytest (add it to
# requirements-dev.txt, which is installed for testing only).
build_python_lambda() {
  local name="$1" dir="$2"
  local venv="${WORK_DIR}/venv-${name}" venv_bin stage="${WORK_DIR}/stage-${name}"

  python3 -m venv "${venv}"
  venv_bin="${venv}/bin"
  [[ -d "${venv}/Scripts" ]] && venv_bin="${venv}/Scripts"

  if [[ -d "${dir}/tests" ]]; then
    "${venv_bin}/pip" install -q -r "${dir}/requirements.txt"
    [[ -f "${dir}/requirements-dev.txt" ]] && "${venv_bin}/pip" install -q -r "${dir}/requirements-dev.txt"
    (cd "${dir}" && "${venv_bin}/python" -m pytest)
  fi

  mkdir -p "${stage}"
  "${venv_bin}/pip" install -q -r "${dir}/requirements.txt" -t "${stage}"
  tar -C "${dir}" \
    --exclude=tests --exclude=__pycache__ --exclude=.pytest_cache \
    --exclude=.venv --exclude=requirements-dev.txt \
    -cf - . | tar -C "${stage}" -xf -
  zip_dir "${stage}" "${WORK_DIR}/zips/${name}.zip"
}

# The layer is a Node package: `npm run build` produces dist/, and the layer
# ships it as nodejs/node_modules/<package name>/ (which Lambda puts on the
# module path) along with its production dependencies.
build_shared_layer() {
  local package_name stage
  (
    cd "${LAYER_DIR}"
    npm ci
    npm test --if-present
    npm run build
  )
  if [[ ! -d "${LAYER_DIR}/dist" ]]; then
    echo "Build of layers/shared did not produce a dist/ directory" >&2
    return 1
  fi

  package_name="$(cd "${LAYER_DIR}" && node -p "require('./package.json').name")"
  stage="${WORK_DIR}/layer/nodejs/node_modules/${package_name}"
  mkdir -p "${stage}"
  cp "${LAYER_DIR}/package.json" "${LAYER_DIR}/package-lock.json" "${stage}/"
  cp -R "${LAYER_DIR}/dist" "${stage}/dist"
  # --ignore-scripts: the staged copy has no source, so a "prepare" script
  # that rebuilds it would fail.
  (cd "${stage}" && npm ci --omit=dev --ignore-scripts)
  zip_dir "${WORK_DIR}/layer" "${WORK_DIR}/zips/shared-layer.zip"
}

# --- Discover components -------------------------------------------------------

components=()
if [[ -d "${LAMBDAS_DIR}" ]]; then
  for dir in "${LAMBDAS_DIR}"/*/; do
    if [[ -f "${dir}package.json" || -f "${dir}requirements.txt" ]]; then
      components+=("$(basename "${dir}")")
    fi
  done
fi

has_layer=false
[[ -f "${LAYER_DIR}/package.json" ]] && has_layer=true

if [[ ${#components[@]} -eq 0 && "${has_layer}" == false ]]; then
  echo "No Lambda functions (lambdas/*/) or shared layer (layers/shared/) found - nothing to deploy."
  exit 0
fi

# --- Check the target functions exist before doing any work ---------------------

missing=()
for name in "${components[@]}"; do
  if ! result="$(aws lambda get-function-configuration \
      --function-name "${NAME_PREFIX}-${name}" \
      --query "FunctionArn" --output text 2>&1)"; then
    echo "${result}" >&2
    missing+=("${NAME_PREFIX}-${name}")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "These functions could not be found: ${missing[*]}" >&2
  echo "Functions are created by CloudFormation - deploy their stack first, or check the names above match lambdas/<name>." >&2
  exit 1
fi

# --- Test and build everything -----------------------------------------------------

if [[ "${has_layer}" == true ]]; then
  echo "=== Testing and building layers/shared ==="
  build_shared_layer
fi

for name in "${components[@]}"; do
  echo "=== Testing and building lambdas/${name} ==="
  if [[ -f "${LAMBDAS_DIR}/${name}/package.json" ]]; then
    build_node_lambda "${name}" "${LAMBDAS_DIR}/${name}"
  else
    build_python_lambda "${name}" "${LAMBDAS_DIR}/${name}"
  fi
done

# --- Deploy ------------------------------------------------------------------------------

layer_arn=""
if [[ "${has_layer}" == true ]]; then
  echo "=== Publishing layer ${LAYER_NAME} ==="
  layer_arn="$(aws lambda publish-layer-version \
    --layer-name "${LAYER_NAME}" \
    --description "Shared data-access layer (commit ${GITHUB_SHA:-local})" \
    --zip-file "fileb://${WORK_DIR}/zips/shared-layer.zip" \
    --compatible-runtimes nodejs20.x nodejs22.x \
    --query "LayerVersionArn" --output text)"
  echo "Published ${layer_arn}"
fi

for name in "${components[@]}"; do
  function_name="${NAME_PREFIX}-${name}"
  echo "=== Deploying ${function_name} ==="

  if [[ -n "${layer_arn}" ]] && is_layer_consumer "${name}"; then
    # --layers replaces the whole list, so keep any other layers the function
    # has and swap only earlier versions of the shared layer for the new one.
    current_layers="$(aws lambda get-function-configuration \
      --function-name "${function_name}" \
      --query "Layers[].Arn" --output text)"
    new_layers=("${layer_arn}")
    for arn in ${current_layers}; do
      [[ "${arn}" == "None" ]] && continue
      [[ "${arn}" == "${layer_arn%:*}:"* ]] && continue
      new_layers+=("${arn}")
    done

    aws lambda update-function-configuration \
      --function-name "${function_name}" \
      --layers "${new_layers[@]}" >/dev/null
    aws lambda wait function-updated --function-name "${function_name}"
  fi

  aws lambda update-function-code \
    --function-name "${function_name}" \
    --zip-file "fileb://${WORK_DIR}/zips/${name}.zip" \
    --query "CodeSha256" --output text >/dev/null
  aws lambda wait function-updated --function-name "${function_name}"
  echo "${function_name} updated."
done

echo "Lambdas deployed to the ${ENVIRONMENT} environment."
