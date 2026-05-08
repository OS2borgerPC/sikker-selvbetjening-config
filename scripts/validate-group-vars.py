#!/usr/bin/env python3
"""Validate cross-field constraints for groups.yml.

JSON Schema cannot portably enforce that printer.default_printer matches one of
the dynamic keys under printer.no_ppd or printer.with_ppd. This script enforces
that rule.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml


def _collect_ids(printer_section: dict) -> set[str]:
    ids: set[str] = set()
    for bucket_name in ("no_ppd", "with_ppd"):
        bucket = printer_section.get(bucket_name)
        if isinstance(bucket, dict):
            ids.update(str(key) for key in bucket.keys())
    return ids


def validate_group(group: dict, source: str) -> list[str]:
    errors: list[str] = []

    printer = group.get("printer")
    if not isinstance(printer, dict):
        return errors

    default_printer = printer.get("default_printer")
    if default_printer is None:
        return errors

    available_ids = _collect_ids(printer)
    if not available_ids:
        errors.append(
            f"{source}: printer.default_printer is set to '{default_printer}', "
            "but no printer IDs exist under printer.no_ppd or printer.with_ppd"
        )
        return errors

    if str(default_printer) not in available_ids:
        ordered = ", ".join(sorted(available_ids))
        errors.append(
            f"{source}: printer.default_printer '{default_printer}' does not match "
            f"any known printer ID ({ordered})"
        )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate cross-field rules for groups.yml."
    )
    parser.add_argument(
        "--groups-file",
        type=Path,
        default=Path("config/groups.yml"),
        help="Path to groups.yml (default: config/groups.yml)",
    )
    args = parser.parse_args()

    groups_file: Path = args.groups_file
    if not groups_file.exists():
        print(f"ERROR: {groups_file}: file does not exist", file=sys.stderr)
        return 1

    try:
        data = yaml.safe_load(groups_file.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        print(f"ERROR: {groups_file}: failed to parse YAML: {exc}", file=sys.stderr)
        return 1

    groups = data.get("groups")
    if not isinstance(groups, list):
        print(f"ERROR: {groups_file}: top-level 'groups' must be a list", file=sys.stderr)
        return 1

    all_errors: list[str] = []
    for group in groups:
        name = group.get("name", "<unnamed>")
        all_errors.extend(validate_group(group, f"{groups_file}[{name}]"))

    if all_errors:
        for error in all_errors:
            print(error, file=sys.stderr)
        return 1

    print("groups.yml validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
