#!/usr/bin/env python3
"""Build matrix discovery helper for GitHub Actions.

Centralize matrix generation in one CI-focused helper.

What it does:
- Reads the config file (default: config/config.yml).
- Extracts all build targets across domains and converts them to matrix entries.
- Validates two semantic rules needed by the build pipeline:
    1) image_name must be unique per domain
    2) each group name listed in build_targets.groups must match a groups.name
       entry in the same domain
- Prints a single line in GitHub output format:
    matrix={"include": [...]}.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml


CONFIG_FILE = Path("config/config.yml")


def main() -> int:
    config_file = CONFIG_FILE
    if not config_file.exists():
        print(f"ERROR: {config_file}: file does not exist", file=sys.stderr)
        return 1

    try:
        config_data = yaml.safe_load(config_file.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        print(f"ERROR: {config_file}: failed to parse YAML: {exc}", file=sys.stderr)
        return 1

    entries = []
    seen_image_names = set()

    for domain_item in config_data["domains"]:
        domain_name = domain_item["domain"]
        available_group_names = {group["name"] for group in domain_item["groups"]}

        for item in domain_item["build_targets"]:
            target_name = item["name"]
            groups = item["groups"]
            image_name = item["image_name"]

            image_key = (domain_name, image_name)
            if image_key in seen_image_names:
                print(
                    f"Duplicate image_name '{image_name}' in domain '{domain_name}'",
                    file=sys.stderr,
                )
                return 1
            seen_image_names.add(image_key)

            missing_groups = [group for group in groups if group not in available_group_names]
            if missing_groups:
                missing_csv = ", ".join(missing_groups)
                print(
                    f"Missing group(s) {missing_csv} in domain '{domain_name}' for target '{target_name}'",
                    file=sys.stderr,
                )
                return 1

            entries.append(
                {
                    "name": target_name,
                    "description": item.get("description"),
                    "domain": domain_name,
                    "target_name": target_name,
                    "image": image_name,
                }
            )

    if not entries:
        print("No build targets found in config/config.yml", file=sys.stderr)
        return 1

    print(f"matrix={json.dumps({'include': entries})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
