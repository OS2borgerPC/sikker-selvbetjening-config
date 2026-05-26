#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Required CI-provided inputs.
: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"
: "${IMAGE_REPO:?IMAGE_REPO must be set by workflow environment}"

# Script args: groups CSV, optional image name, required target domain.
TARGET_GROUPS_CSV="$1"
FIRST_GROUP="${TARGET_GROUPS_CSV%%,*}"
IMAGE_NAME="${2:-$FIRST_GROUP}"
TARGET_DOMAIN="${3:?target domain argument is required}"
IMAGE_REF_BASE="${IMAGE_REPO}/${TARGET_DOMAIN}/${IMAGE_NAME}"
export IMAGE_REPO
DATE_TAG="$(date -u +%Y%m%d)"

echo "Using BASE_IMAGE=${BASE_IMAGE}"
echo "Using IMAGE_REPO=${IMAGE_REPO}"

if [[ -n "${GITHUB_SHA:-}" ]]; then
  SHA_TAG="sha-${GITHUB_SHA:0:7}"
elif command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
  SHA_TAG="sha-$(git rev-parse --short HEAD)"
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

# Render overlay payload from group/domain data.
ansible-playbook -i localhost, playbooks/render-host-overlays.yml -e "target_domain=${TARGET_DOMAIN}" -e "target_groups=${TARGET_GROUPS_CSV}" -e "build_name=${IMAGE_NAME}"

mkdir -p "build/${IMAGE_NAME}/usr" "build/${IMAGE_NAME}/etc"

NORMALIZED_OVERLAY_PAYLOAD="${REPO_ROOT}/build/${IMAGE_NAME}/overlay.normalized.json"

# If a normalized overlay exists, apply it with the helper from BASE_IMAGE.
if [[ -f "${NORMALIZED_OVERLAY_PAYLOAD}" ]]; then
  echo "Normalized overlay payload (${NORMALIZED_OVERLAY_PAYLOAD}):"
  if command -v jq >/dev/null 2>&1; then
    jq . "${NORMALIZED_OVERLAY_PAYLOAD}"
  else
    cat "${NORMALIZED_OVERLAY_PAYLOAD}"
  fi

  podman run --rm \
    -v "${REPO_ROOT}/config/assets:/assets:Z,ro" \
    -v "${REPO_ROOT}/build/${IMAGE_NAME}:/work:Z" \
    "${BASE_IMAGE}" \
    /usr/libexec/sikker-apply-overlay \
    /work/overlay.normalized.json \
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
