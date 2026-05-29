#!/usr/bin/env python3
"""Validate config against JSON Schema.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover - environment-specific dependency hint
    print(
        "ERROR: missing dependency 'jsonschema'. Install with: pip install jsonschema",
        file=sys.stderr,
    )
    raise


def validate_schema(config_data: dict, schema_file: Path, source: Path) -> list[str]:
    if not schema_file.exists():
        return [f"{schema_file}: schema file does not exist"]

    try:
        schema = json.loads(schema_file.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"{schema_file}: failed to parse schema JSON: {exc}"]

    try:
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
    except Exception as exc:
        return [f"{schema_file}: invalid JSON schema: {exc}"]

    # Flatten validator output into stable, user-readable error messages.
    errors: list[str] = []
    for error in sorted(validator.iter_errors(config_data), key=lambda e: list(e.path)):
        path = ".".join(str(part) for part in error.path)
        if path:
            errors.append(f"{source}:{path}: {error.message}")
        else:
            errors.append(f"{source}: {error.message}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate combined config against JSON Schema."
    )
    parser.add_argument(
        "--config-file",
        type=Path,
        default=Path("config/config.yml"),
        help="Path to combined config (default: config/config.yml)",
    )
    parser.add_argument(
        "--schema-file",
        type=Path,
        required=True,
        help="Path to schema.json (for CI this is exported from BASE_IMAGE)",
    )
    args = parser.parse_args()

    config_file: Path = args.config_file
    schema_file: Path = args.schema_file
    if not config_file.exists():
        print(f"ERROR: {config_file}: file does not exist", file=sys.stderr)
        return 1

    try:
        data = yaml.safe_load(config_file.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        print(f"ERROR: {config_file}: failed to parse YAML: {exc}", file=sys.stderr)
        return 1

    all_errors: list[str] = []
    # First pass: structural validation from JSON Schema.
    all_errors.extend(validate_schema(data, schema_file, config_file))

    domains = data.get("domains")
    if not isinstance(domains, list):
        all_errors.append(f"{config_file}: top-level 'domains' must be a list")
        for error in all_errors:
            print(error, file=sys.stderr)
        return 1

    if all_errors:
        # Print all discovered problems in one run to reduce edit/validate cycles.
        for error in all_errors:
            print(error, file=sys.stderr)
        return 1

    print("combined config schema validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
