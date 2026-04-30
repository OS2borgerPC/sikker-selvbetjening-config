#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_CONFIG_FILE="${IMAGE_CONFIG_FILE:-$REPO_ROOT/.env}"

if [[ -f "$IMAGE_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$IMAGE_CONFIG_FILE"
fi

TARGET_GROUPS_CSV="$1"
FIRST_GROUP="${TARGET_GROUPS_CSV%%,*}"
IMAGE_NAME="${2:-$FIRST_GROUP}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/bibsdb/sikker-selvbetjening-config}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/bibsdb/sikker-selvbetjening:latest}"
DATE_TAG="$(date -u +%Y%m%d)"

if [[ -n "${GITHUB_SHA:-}" ]]; then
  SHA_TAG="sha-${GITHUB_SHA:0:7}"
elif command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
  SHA_TAG="sha-$(git rev-parse --short HEAD)"
else
  SHA_TAG=""
fi

TAGS=(
  "latest"
  "latest.${DATE_TAG}"
  "${DATE_TAG}"
)

if [[ -n "$SHA_TAG" ]]; then
  TAGS+=("$SHA_TAG")
fi

rm -rf "build/${IMAGE_NAME}"
ansible-playbook -i localhost, playbooks/render-host-overlays.yml -e "target_groups=${TARGET_GROUPS_CSV}" -e "build_name=${IMAGE_NAME}"

mkdir -p "build/${IMAGE_NAME}/usr" "build/${IMAGE_NAME}/etc"

# Derive Git repo URL from IMAGE_REPO: ghcr.io/<org>/<repo> -> https://github.com/<org>/<repo>.git
ANSIBLE_PULL_REPO="${ANSIBLE_PULL_REPO:-https://github.com/${IMAGE_REPO#ghcr.io/}.git}"
ANSIBLE_PULL_PLAYBOOK="${ANSIBLE_PULL_PLAYBOOK:-playbooks/switch-installed-target.yml}"
ANSIBLE_PULL_INVENTORY="${ANSIBLE_PULL_INVENTORY:-config/inventory/hosts.yml}"

mkdir -p "build/${IMAGE_NAME}/etc/sikker-selvbetjening"
cat > "build/${IMAGE_NAME}/etc/sikker-selvbetjening/ansible-pull.env" <<ENVFILE
ANSIBLE_PULL_REPO=${ANSIBLE_PULL_REPO}
ANSIBLE_PULL_PLAYBOOK=${ANSIBLE_PULL_PLAYBOOK}
ANSIBLE_PULL_INVENTORY=${ANSIBLE_PULL_INVENTORY}
ENVFILE

NORMALIZED_OVERLAY_PAYLOAD="${REPO_ROOT}/build/${IMAGE_NAME}/overlay.normalized.json"

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

podman build \
  -t ${IMAGE_REPO}/${IMAGE_NAME}:latest \
  -f - . <<EOF
FROM ${BASE_IMAGE}
COPY build/${IMAGE_NAME}/usr/ /usr/
COPY build/${IMAGE_NAME}/etc/ /etc/
RUN if command -v dconf >/dev/null 2>&1; then dconf update; else echo "dconf not found; skipping dconf update"; fi
EOF

for tag in "${TAGS[@]}"; do
  if [[ "$tag" != "latest" ]]; then
    podman tag "${IMAGE_REPO}/${IMAGE_NAME}:latest" "${IMAGE_REPO}/${IMAGE_NAME}:${tag}"
  fi
  podman push "${IMAGE_REPO}/${IMAGE_NAME}:${tag}"
done
