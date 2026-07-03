#!/usr/bin/env bash
set -euo pipefail

# Build one image from one imageconfig file.
#
# Inputs:
# - arg1: imageconfig file path (required)
# - arg2: image name (required)
# - arg3: image domain (required)
# - env: BASE_IMAGE and IMAGE_REPO
#
# Flow:
# 1) render combined configuration with Ansible
# 2) apply playbooks from BASE_IMAGE into build/
# 3) build derived image and push latest/date/sha tags

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Required CI-provided inputs.
: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"
: "${IMAGE_REPO:?IMAGE_REPO must be set by workflow environment}"

# Script args: imageconfig file path, required image name, required image domain.
IMAGECONFIG_FILE="${1:?imageconfig file path argument is required}"
IMAGE_NAME="${2:?image name argument is required}"
IMAGE_DOMAIN="${3:?image domain argument is required}"
IMAGE_REF_BASE="${IMAGE_REPO}/${IMAGE_DOMAIN}/${IMAGE_NAME}"
export IMAGE_REPO
DATE_TAG="$(date -u +%Y%m%d)"

echo "Using BASE_IMAGE=${BASE_IMAGE}"
echo "Using IMAGE_REPO=${IMAGE_REPO}"

# Derive an immutable commit tag for traceability from CI-provided GITHUB_SHA.
if [[ -n "${GITHUB_SHA:-}" ]]; then
  SHA_TAG="sha-${GITHUB_SHA:0:7}"
else
  SHA_TAG=""
fi

# Always publish date-based tags; add commit-based tag when available.
TAGS=(
  "latest"
  "latest.${DATE_TAG}"
  "${DATE_TAG}"
)

if [[ -n "$SHA_TAG" ]]; then
  TAGS+=("$SHA_TAG")
fi

# Recreate build output for this image name from scratch.
rm -rf "build/${IMAGE_NAME}"

# Render overlay payload from the selected imageconfig file.
ansible-playbook -i localhost, playbooks/render-host-overlays.yml \
  -e "imageconfig_file=${IMAGECONFIG_FILE}" \
  -e "build_name=${IMAGE_NAME}"

mkdir -p "build/${IMAGE_NAME}/usr" "build/${IMAGE_NAME}/etc"

CONFIGURATION_OVERLAY="${REPO_ROOT}/build/${IMAGE_NAME}/configuration-overlay.json"
POST_STEPS_FILE="${REPO_ROOT}/build/${IMAGE_NAME}/post-steps.json"

# Seed a default post-step payload. sikker-create-overlay may append steps to this file.
cat > "${POST_STEPS_FILE}" <<EOF
{
  "version": 1,
  "steps": []
}
EOF

# If a configuration overlay exists, apply it with the ansible playbooks from BASE_IMAGE.
if [[ -f "${CONFIGURATION_OVERLAY}" ]]; then
  echo "Configuration overlay payload (${CONFIGURATION_OVERLAY}):"
  if command -v jq >/dev/null 2>&1; then
    jq . "${CONFIGURATION_OVERLAY}"
  else
    cat "${CONFIGURATION_OVERLAY}"
  fi

  podman run --rm \
    -v "${REPO_ROOT}/config/assets:/assets:Z,ro" \
    -v "${REPO_ROOT}/build/${IMAGE_NAME}:/work:Z" \
    "${BASE_IMAGE}" \
    /usr/libexec/sikker-create-overlay \
    /work/configuration-overlay.json \
    /assets \
    /work
fi

POST_STEPS_DOCKER_SNIPPET=""
if [[ -f "${POST_STEPS_FILE}" ]]; then
  echo "Post-step metadata payload (${POST_STEPS_FILE}):"
  RUN_POST_STEPS="yes"
  if command -v jq >/dev/null 2>&1; then
    jq . "${POST_STEPS_FILE}"
    if ! jq -e '.steps | type == "array" and length > 0' "${POST_STEPS_FILE}" >/dev/null; then
      RUN_POST_STEPS="no"
    fi
  else
    cat "${POST_STEPS_FILE}"
  fi

  if [[ "${RUN_POST_STEPS}" == "yes" ]]; then
    POST_STEPS_DOCKER_SNIPPET=$'COPY build/'"${IMAGE_NAME}"$'/post-steps.json /tmp/post-steps.json\nRUN /usr/libexec/sikker-run-post-steps /tmp/post-steps.json && rm -f /tmp/post-steps.json'
  else
    echo "No post steps defined in post-steps.json; skipping post-step execution."
  fi
fi

# Build final image by layering generated /usr and /etc content on BASE_IMAGE.
podman build \
  -t ${IMAGE_REF_BASE}:latest \
  -f - . <<EOF
FROM ${BASE_IMAGE}
COPY build/${IMAGE_NAME}/usr/ /usr/
COPY build/${IMAGE_NAME}/etc/ /etc/
${POST_STEPS_DOCKER_SNIPPET}
EOF

# Push latest plus each derived tag.
for tag in "${TAGS[@]}"; do
  if [[ "$tag" != "latest" ]]; then
    podman tag "${IMAGE_REF_BASE}:latest" "${IMAGE_REF_BASE}:${tag}"
  fi
  podman push "${IMAGE_REF_BASE}:${tag}"
done
