#!/usr/bin/env python3
"""Build matrix discovery helper for GitHub Actions.

Centralize matrix generation in one CI-focused helper.

What it does:
- Reads the config file (default: config/config.yml).
- Extracts all device groups across domains and converts them to matrix entries.
- Validates two semantic rules needed by the build pipeline:
    1) image_name must be unique per domain
    2) each policy name listed in device_groups.policies must match a policies.name
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
        available_policies_names = {policy["name"] for policy in domain_item["policies"]}

        for item in domain_item["device_groups"]:
            device_group_name = item["name"]
            policies = item["policies"]
            image_name = item["image_name"]

            image_key = (domain_name, image_name)
            if image_key in seen_image_names:
                print(
                    f"Duplicate image_name '{image_name}' in domain '{domain_name}'",
                    file=sys.stderr,
                )
                return 1
            seen_image_names.add(image_key)

            missing_policies = [policy for policy in policies if policy not in available_policy_names]
            if missing_policies:
                missing_csv = ", ".join(missing_policies)
                print(
                    f"Missing policy(s) {missing_csv} in domain '{domain_name}' for device_group '{device_group_name}'",
                    file=sys.stderr,
                )
                return 1

            entries.append(
                {
                    "name": device_group_name,
                    "description": item.get("description"),
                    "domain": domain_name,
                    "device_group_name": device_group_name,
                    "image": image_name,
                }
            )

    if not entries:
        print("No device groups found in config/config.yml", file=sys.stderr)
        return 1

    print(f"matrix={json.dumps({'include': entries})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
