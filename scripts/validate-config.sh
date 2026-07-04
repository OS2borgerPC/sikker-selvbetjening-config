#!/usr/bin/env bash
set -euo pipefail

# Validate one imageconfig file using validation tooling embedded in BASE_IMAGE.
#
# Inputs:
# - env: BASE_IMAGE
# - arg1: imageconfig file path (required, repository-relative)
# - arg2: policies root path (required, repository-relative)
# - arg3: assets root path (required, repository-relative)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"

IMAGECONFIG_FILE_REL="${1:?imageconfig file path argument is required}"
POLICIES_ROOT_REL="${2:?policies root path argument is required}"
ASSETS_ROOT_REL="${3:?assets root path argument is required}"

IMAGECONFIG_FILE_ABS="${REPO_ROOT}/${IMAGECONFIG_FILE_REL}"
POLICIES_ROOT_ABS="${REPO_ROOT}/${POLICIES_ROOT_REL}"
ASSETS_ROOT_ABS="${REPO_ROOT}/${ASSETS_ROOT_REL}"

if [[ ! -f "${IMAGECONFIG_FILE_ABS}" ]]; then
  echo "Missing imageconfig file: ${IMAGECONFIG_FILE_ABS}" >&2
  exit 1
fi

if [[ ! -d "${POLICIES_ROOT_ABS}" ]]; then
  echo "Missing policies root directory: ${POLICIES_ROOT_ABS}" >&2
  exit 1
fi

if [[ ! -d "${ASSETS_ROOT_ABS}" ]]; then
  echo "Missing assets root directory: ${ASSETS_ROOT_ABS}" >&2
  exit 1
fi

echo "Validating ${IMAGECONFIG_FILE_REL} using ${BASE_IMAGE}"

podman run --rm \
  -v "${IMAGECONFIG_FILE_ABS}:/work/imageconfig.yml:Z,ro" \
  -v "${POLICIES_ROOT_ABS}:/work/policies:Z,ro" \
  -v "${ASSETS_ROOT_ABS}:/work/assets:Z,ro" \
  "${BASE_IMAGE}" \
  /usr/libexec/sikker-validate-config \
  /work/imageconfig.yml \
  /work/policies \
  /work/assets

echo "Validation passed for ${IMAGECONFIG_FILE_REL}"