#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_CONFIG_FILE="${IMAGE_CONFIG_FILE:-$REPO_ROOT/.env}"

if [[ -f "$IMAGE_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$IMAGE_CONFIG_FILE"
fi

BASE_IMAGE="${BASE_IMAGE:-ghcr.io/os2borgerpc/sikker-selvbetjening:latest}"
SCHEMAS_PATH_IN_IMAGE="${SCHEMAS_PATH_IN_IMAGE:-/usr/share/sikker-selvbetjening/schemas}"
GROUP_VARS_GLOB="${GROUP_VARS_GLOB:-config/group_vars/*.yml}"

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is required to extract schemas from the base image" >&2
  exit 1
fi

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "check-jsonschema is required to validate group_vars" >&2
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

schema_file="$tmp_dir/schemas/group-vars.schema.json"

if [[ ! -f "$schema_file" ]]; then
  cat >&2 <<EOF
Expected schema file not found in extracted image content.

Expected path in image:
- $SCHEMAS_PATH_IN_IMAGE/group-vars.schema.json
EOF
  exit 1
fi

# Some schema bundles use relative $id values (for example "./group-vars.schema.json"),
# which can cause check-jsonschema to resolve sibling refs against the working directory.
# Removing relative $id values keeps $ref resolution anchored to the schema file location.
python3 - <<'PY' "$tmp_dir/schemas"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

for path in root.rglob("*.json"):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue

    if isinstance(data, dict):
        schema_id = data.get("$id")
        if isinstance(schema_id, str) and schema_id.startswith("./"):
            del data["$id"]
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

shopt -s nullglob
group_var_files=( $GROUP_VARS_GLOB )
shopt -u nullglob

if [[ ${#group_var_files[@]} -eq 0 ]]; then
  echo "No group_vars files found matching: $GROUP_VARS_GLOB" >&2
  exit 1
fi

echo "Validating ${#group_var_files[@]} group_vars file(s) against schema from base image"
check-jsonschema --schemafile "$schema_file" "${group_var_files[@]}"
