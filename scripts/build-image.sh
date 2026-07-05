#!/usr/bin/env bash
set -euo pipefail

# Build and push one image from one imageconfig file using tooling embedded in
# BASE_IMAGE.
#
# Flow:
# 1) Validate input paths and ensure output directory exists.
# 2) Start/reuse a host Podman API socket and wait for readiness.
# 3) Run /usr/libexec/sikker-build-image inside BASE_IMAGE with shared socket.
# 4) Parse emitted PUSH_REFS and push each reference from the host context.
#
# Inputs:
# - env: BASE_IMAGE
# - env: GITHUB_SHA (optional)
# - arg1: imageconfig file path (required, repository-relative)
# - arg2: policies root path (required, repository-relative)
# - arg3: assets root path (required, repository-relative)
# - arg4: target image ref (required)
# - arg5: output root path (optional, repository-relative, default: build)
#
# Notes:
# - This script uses Podman socket sharing so image build and host-side pushes
#   use the same image store.
# - /usr/libexec/sikker-build-image must emit PUSH_REFS_BEGIN/PUSH_REFS_END for
#   push discovery.

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

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="${XDG_RUNTIME_DIR}/podman/podman.sock"
PODMAN_SERVICE_LOG="/tmp/podman-service.log"

PODMAN_SERVICE_PID=""
build_log=""

die() {
  echo "$*" >&2
  exit 1
}

ensure_paths() {
  [[ -f "${IMAGECONFIG_FILE_ABS}" ]] || die "Missing imageconfig file: ${IMAGECONFIG_FILE_ABS}"
  [[ -d "${POLICIES_ROOT_ABS}" ]] || die "Missing policies root directory: ${POLICIES_ROOT_ABS}"
  [[ -d "${ASSETS_ROOT_ABS}" ]] || die "Missing assets root directory: ${ASSETS_ROOT_ABS}"
  mkdir -p "${OUTPUT_ROOT_ABS}"
}

ensure_podman_socket_ready() {
  mkdir -p "$(dirname "${SOCK}")"

  # Share the host Podman engine with the containerized build tool so built
  # images are visible when this script pushes refs on the host.
  if [[ ! -S "${SOCK}" ]]; then
    podman system service --time=0 "unix://${SOCK}" >"${PODMAN_SERVICE_LOG}" 2>&1 &
    PODMAN_SERVICE_PID="$!"
  fi

  for _ in {1..30}; do
    if podman --url "unix://${SOCK}" info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  if [[ -f "${PODMAN_SERVICE_LOG}" ]]; then
    echo "Podman service log:" >&2
    tail -n 50 "${PODMAN_SERVICE_LOG}" >&2 || true
  fi
  die "Podman socket did not become ready: ${SOCK}"
}

cleanup() {
  if [[ -n "${PODMAN_SERVICE_PID}" ]]; then
    kill "${PODMAN_SERVICE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${build_log}" ]]; then
    rm -f "${build_log}" >/dev/null 2>&1 || true
  fi
}

run_build() {
  build_log="$(mktemp)"

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
    /usr/libexec/sikker-build-image \
    /work/imageconfig.yml \
    /work/policies \
    /work/assets \
    "${TARGET_IMAGE_REF}" | tee "${build_log}"
}

push_refs() {
  local refs=()
  mapfile -t refs < <(awk '/^PUSH_REFS_BEGIN$/{on=1;next}/^PUSH_REFS_END$/{on=0}on{print}' "${build_log}")

  if [[ "${#refs[@]}" -eq 0 ]]; then
    die "No PUSH_REFS were emitted by /usr/libexec/sikker-build-image"
  fi

  for ref in "${refs[@]}"; do
    echo "Pushing ${ref}"
    podman push "${ref}"
  done
}

echo "Building image from ${IMAGECONFIG_FILE_REL} using ${BASE_IMAGE}"
echo "Using TARGET_IMAGE_REF=${TARGET_IMAGE_REF}"

trap cleanup EXIT

ensure_paths
ensure_podman_socket_ready
run_build
push_refs

echo "Build and push completed for ${IMAGECONFIG_FILE_REL}"

