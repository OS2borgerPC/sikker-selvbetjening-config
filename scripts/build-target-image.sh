#!/usr/bin/env bash
set -euo pipefail

# Build one target-specific image from the combined config.
#
# The combined config comes from the selected build target's group list:
# - CI discovers a build target in config/config.yml
# - this script passes the build target name and domain to Ansible
# - the playbook looks up that build target and merges the attached groups
#   (in order) into a conbined configuration used for image build
#
# Inputs:
# - arg1: build target name
# - arg2: image name (required)
# - arg3: target domain
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

# Script args: build target name, required image name, required target domain.
TARGET_NAME="$1"
IMAGE_NAME="${2:?image name argument is required}"
TARGET_DOMAIN="${3:?target domain argument is required}"
IMAGE_REF_BASE="${IMAGE_REPO}/${TARGET_DOMAIN}/${IMAGE_NAME}"
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

# Render overlay payload from the selected build target.
ansible-playbook -i localhost, playbooks/render-host-overlays.yml -e "target_domain=${TARGET_DOMAIN}" -e "target_name=${TARGET_NAME}" -e "build_name=${IMAGE_NAME}"

mkdir -p "build/${IMAGE_NAME}/usr" "build/${IMAGE_NAME}/etc"

CONFIGURATION_OVERLAY="${REPO_ROOT}/build/${IMAGE_NAME}/configuration-overlay.json"

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

  echo "Post-helper debug: listing generated desktop artifacts"
  ls -la "${REPO_ROOT}/build/${IMAGE_NAME}/usr/share/backgrounds/sikker-selvbetjening" || true
  ls -la "${REPO_ROOT}/build/${IMAGE_NAME}/etc/dconf/db/local.d" || true

  DCONF_DEFAULTS_FILE="${REPO_ROOT}/build/${IMAGE_NAME}/etc/dconf/db/local.d/03-desktop-background"
  if [[ -f "${DCONF_DEFAULTS_FILE}" ]]; then
    echo "Post-helper debug: found ${DCONF_DEFAULTS_FILE}"
    cat "${DCONF_DEFAULTS_FILE}"
  else
    echo "Post-helper debug: missing ${DCONF_DEFAULTS_FILE}"
  fi
fi

# Build final image by layering generated /usr and /etc content on BASE_IMAGE.
podman build \
  -t ${IMAGE_REF_BASE}:latest \
  -f - . <<EOF
FROM ${BASE_IMAGE}
COPY build/${IMAGE_NAME}/usr/ /usr/
COPY build/${IMAGE_NAME}/etc/ /etc/
RUN if command -v dconf >/dev/null 2>&1; then dconf update; else echo "dconf not found; skipping dconf update"; fi
EOF

# Push latest plus each derived tag.
for tag in "${TAGS[@]}"; do
  if [[ "$tag" != "latest" ]]; then
    podman tag "${IMAGE_REF_BASE}:latest" "${IMAGE_REF_BASE}:${tag}"
  fi
  podman push "${IMAGE_REF_BASE}:${tag}"
done
