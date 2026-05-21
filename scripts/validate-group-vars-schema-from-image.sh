#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BASE_IMAGE:?BASE_IMAGE must be set by workflow environment}"
: "${SCHEMAS_PATH_IN_IMAGE:?SCHEMAS_PATH_IN_IMAGE must be set by workflow environment}"
GROUPS_FILE="${GROUPS_FILE:-$REPO_ROOT/config/groups.yml}"

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

# Explode groups.yml into per-group JSON files (sections only, no 'name' key)
# so each can be validated against group-vars.schema.json from the base image.
python3 - <<'PY' "$GROUPS_FILE" "$tmp_dir/groups"
import json
import pathlib
import sys

import yaml

groups_file = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)

try:
    data = yaml.safe_load(groups_file.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"ERROR: failed to parse {groups_file}: {exc}", file=sys.stderr)
    raise SystemExit(1)

domains = data.get("domains") if isinstance(data, dict) else None
if not isinstance(domains, list):
  print(f"ERROR: {groups_file}: top-level 'domains' must be a list", file=sys.stderr)
    raise SystemExit(1)

for domain in domains:
  if not isinstance(domain, dict):
    print(f"ERROR: domain entry must be an object: {domain}", file=sys.stderr)
    raise SystemExit(1)

  domain_name = domain.get("domain")
  if not isinstance(domain_name, str) or not domain_name:
    print(f"ERROR: domain entry missing valid 'domain': {domain}", file=sys.stderr)
    raise SystemExit(1)

  groups = domain.get("groups")
  if not isinstance(groups, list):
    print(
      f"ERROR: {groups_file}: domain '{domain_name}' must define 'groups' as a list",
      file=sys.stderr,
    )
    raise SystemExit(1)

  for group in groups:
    name = group.get("name") if isinstance(group, dict) else None
    if not isinstance(name, str) or not name:
      print(
        f"ERROR: group entry missing valid 'name' in domain '{domain_name}': {group}",
        file=sys.stderr,
      )
      raise SystemExit(1)
    sections = {k: v for k, v in group.items() if k != "name"}
    out_name = f"{domain_name}__{name}.json"
    (out_dir / out_name).write_text(json.dumps(sections), encoding="utf-8")
PY

group_section_files=( "$tmp_dir/groups"/*.json )

if [[ ${#group_section_files[@]} -eq 0 ]]; then
  echo "No groups found in: $GROUPS_FILE" >&2
  exit 1
fi

echo "Validating ${#group_section_files[@]} group(s) from $GROUPS_FILE against schema from base image"
check-jsonschema --schemafile "$schema_file" "${group_section_files[@]}"
