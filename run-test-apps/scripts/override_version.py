#!/usr/bin/env python3
"""Override test-app version pin in alef.toml."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def override_package_versions(doc: dict[str, object], language: str, version: str) -> tuple[bool, list[str]]:
    """Rewrite every crates.*.e2e.registry.packages.{language}.version in place.

    Returns whether any entry was rewritten, and the paths of entries that exist but are not
    tables -- a `{language} = "1.0.0"` shorthand has no version key to overwrite.
    """
    found = False
    non_table_entries: list[str] = []
    crates = doc.get("crates") if isinstance(doc, dict) else None
    if not isinstance(crates, dict):
        return found, non_table_entries

    for crate_name, crate_config in crates.items():
        packages = _read_packages_table(crate_config)
        if packages is None or language not in packages:
            continue
        pkg = packages[language]
        if isinstance(pkg, dict):
            pkg["version"] = version
            found = True
            print(f"Updated {crate_name}.e2e.registry.packages.{language}.version to {version}")
        else:
            non_table_entries.append(f"{crate_name}.e2e.registry.packages.{language}")

    return found, non_table_entries


def _read_packages_table(crate_config: object) -> dict[str, object] | None:
    node: object = crate_config
    for key in ("e2e", "registry", "packages"):
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node if isinstance(node, dict) else None


def main() -> None:
    try:
        import tomlkit
    except ImportError:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--break-system-packages", "tomlkit"],
            check=True,
        )
        import tomlkit

    language = os.environ.get("INPUT_LANGUAGE", "").strip()
    version = os.environ.get("INPUT_VERSION", "").strip()
    working_directory = os.environ.get("INPUT_WORKING_DIRECTORY", ".").strip()

    if not language:
        print("::error::INPUT_LANGUAGE is required", file=sys.stderr)
        sys.exit(1)
    if not version:
        print("::error::INPUT_VERSION is required", file=sys.stderr)
        sys.exit(1)

    alef_toml_path = Path(working_directory) / "alef.toml"
    if not alef_toml_path.exists():
        print(
            f"::error::alef.toml not found at {alef_toml_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    content = alef_toml_path.read_text()
    try:
        doc = tomlkit.parse(content)
    except tomlkit.exceptions.ParseError as error:
        print(
            f"::error::Failed to parse {alef_toml_path}: {error}",
            file=sys.stderr,
        )
        sys.exit(1)

    found, non_table_entries = override_package_versions(doc, language, version)

    if not found:
        if non_table_entries:
            print(
                f"::error::Package entry for language '{language}' is not a table and has no version key "
                f"to override: {', '.join(non_table_entries)}. Expand it to "
                f'`{language} = {{ version = "..." }}` in alef.toml.',
                file=sys.stderr,
            )
        else:
            print(
                f"::error::No matching package entry for language '{language}' found in alef.toml",
                file=sys.stderr,
            )
        sys.exit(1)

    alef_toml_path.write_text(tomlkit.dumps(doc))
    print("Successfully updated alef.toml")


if __name__ == "__main__":
    main()
