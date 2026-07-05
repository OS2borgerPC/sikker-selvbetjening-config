#!/usr/bin/env bash
set -euo pipefail

# Validate one imageconfig file using validation tooling embedded in BASE_IMAGE.
#
# Inputs:
# - env: BASE_IMAGE
# - env: GITHUB_SHA (optional)
# - arg1: imageconfig file path (required, repository-relative)
# - arg2: policies root path (required, repository-relative)
# - arg3: assets root path (required, repository-relative)
# - arg4: target image ref (required)
# - arg5: output root path (optional, repository-relative, default: build)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"

IMAGECONFIG_FILE_REL="${1:?imageconfig file path argument is required}"
POLICIES_ROOT_REL="${2:?policies root path argument is required}"
ASSETS_ROOT_REL="${3:?assets root path argument is required}"
TARGET_IMAGE_REF="${4:?target image ref argument is required}"
OUTPUT_ROOT_REL="${5:-build}"

IMAGECONFIG_FILE_ABS="${REPO_ROOT}/${IMAGECONFIG_FILE_REL}"
POLICIES_ROOT_ABS="${REPO_ROOT}/${POLICIES_ROOT_REL}"
ASSETS_ROOT_ABS="${REPO_ROOT}/${ASSETS_ROOT_REL}"
OUTPUT_ROOT_ABS="${REPO_ROOT}/${OUTPUT_ROOT_REL}"

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

mkdir -p "${OUTPUT_ROOT_ABS}"

echo "Validating ${IMAGECONFIG_FILE_REL} using ${BASE_IMAGE}"
echo "Using TARGET_IMAGE_REF=${TARGET_IMAGE_REF}"

# Share the host Podman engine with the containerized validator so built images
# are visible when this script pushes refs on the host.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="${XDG_RUNTIME_DIR}/podman/podman.sock"
mkdir -p "$(dirname "${SOCK}")"

PODMAN_SERVICE_PID=""
if [[ ! -S "${SOCK}" ]]; then
  podman system service --time=0 "unix://${SOCK}" >/tmp/podman-service.log 2>&1 &
  PODMAN_SERVICE_PID="$!"
fi

podman_ready="no"
for _ in {1..30}; do
  if podman --url "unix://${SOCK}" info >/dev/null 2>&1; then
    podman_ready="yes"
    break
  fi
  sleep 1
done

if [[ "${podman_ready}" != "yes" ]]; then
  echo "Podman socket did not become ready: ${SOCK}" >&2
  if [[ -f /tmp/podman-service.log ]]; then
    echo "Podman service log:" >&2
    tail -n 50 /tmp/podman-service.log >&2 || true
  fi
  exit 1
fi

build_log="$(mktemp)"
cleanup() {
  if [[ -n "${PODMAN_SERVICE_PID}" ]]; then
    kill "${PODMAN_SERVICE_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${build_log}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

podman run --rm \
  --privileged \
  -e BASE_IMAGE="${BASE_IMAGE}" \
  -e GITHUB_SHA="${GITHUB_SHA:-}" \
  -e SIKKER_OUTPUT_ROOT="/work/out" \
  -e CONTAINER_HOST="unix:///run/podman/podman.sock" \
  -v "${SOCK}:/run/podman/podman.sock:Z" \
  -v "${IMAGECONFIG_FILE_ABS}:/work/imageconfig.yml:Z,ro" \
  -v "${POLICIES_ROOT_ABS}:/work/policies:Z,ro" \
  -v "${ASSETS_ROOT_ABS}:/work/assets:Z,ro" \
  -v "${OUTPUT_ROOT_ABS}:/work/out:Z" \
  "${BASE_IMAGE}" \
  /usr/libexec/sikker-validate-config \
  /work/imageconfig.yml \
  /work/policies \
  /work/assets \
  "${TARGET_IMAGE_REF}" | tee "${build_log}"

mapfile -t refs < <(awk '/^PUSH_REFS_BEGIN$/{on=1;next}/^PUSH_REFS_END$/{on=0}on{print}' "${build_log}")

for ref in "${refs[@]}"; do
  echo "Pushing ${ref}"
  podman push "${ref}"
done

echo "Validation passed for ${IMAGECONFIG_FILE_REL}"

