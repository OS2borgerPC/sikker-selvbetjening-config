#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"
: "${SCHEMAS_PATH_IN_IMAGE:?SCHEMAS_PATH_IN_IMAGE must be set by workflow environment}"
GROUPS_FILE="${GROUPS_FILE:-$REPO_ROOT/config/groups.yml}"
BUILD_TARGETS_FILE="${BUILD_TARGETS_FILE:-$REPO_ROOT/config/build_targets.yml}"

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is required to extract schemas from the base image" >&2
  exit 1
fi

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "check-jsonschema is required to validate config files" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
container_id=""

cleanup() {
  if [[ -n "$container_id" ]]; then
    podman rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

echo "Pulling base image: $BASE_IMAGE"
if ! podman pull "$BASE_IMAGE" >/dev/null; then
  cat >&2 <<'EOF'
Failed to pull base image for schema validation.

The base image must be publicly readable in GHCR, or the runner token/user must
have package read access to that image.
EOF
  exit 1
fi

container_id="$(podman create "$BASE_IMAGE")"
mkdir -p "$tmp_dir/schemas"
podman cp "$container_id:$SCHEMAS_PATH_IN_IMAGE/." "$tmp_dir/schemas"
podman rm "$container_id" >/dev/null
container_id=""

groups_schema_file="$tmp_dir/schemas/groups.schema.json"
build_targets_schema_file="$tmp_dir/schemas/build_targets.schema.json"

if [[ ! -f "$groups_schema_file" ]]; then
  cat >&2 <<EOF
Expected schema file not found in extracted image content.

Expected path in image:
- $SCHEMAS_PATH_IN_IMAGE/groups.schema.json
EOF
  exit 1
fi

if [[ ! -f "$build_targets_schema_file" ]]; then
  cat >&2 <<EOF
Expected schema file not found in extracted image content.

Expected path in image:
- $SCHEMAS_PATH_IN_IMAGE/build_targets.schema.json
EOF
  exit 1
fi

if [[ ! -f "$GROUPS_FILE" ]]; then
  echo "Missing groups config file: $GROUPS_FILE" >&2
  exit 1
fi

if [[ ! -f "$BUILD_TARGETS_FILE" ]]; then
  echo "Missing build targets config file: $BUILD_TARGETS_FILE" >&2
  exit 1
fi

echo "Validating $GROUPS_FILE against schema from base image"
check-jsonschema --schemafile "$groups_schema_file" "$GROUPS_FILE"

echo "Validating $BUILD_TARGETS_FILE against schema from base image"
check-jsonschema --schemafile "$build_targets_schema_file" "$BUILD_TARGETS_FILE"
