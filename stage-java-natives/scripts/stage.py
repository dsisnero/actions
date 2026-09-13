#!/usr/bin/env python3
"""Stage build-java-natives artifacts into a Maven resources tree.

build-java-natives produces `{output-dir}/native/{classifier}/{libfile}`. The
publish workflow uploads `{output-dir}` as the artifact `java-natives-{label}`
and the downstream Java package job downloads them all into a single tree. With
`merge-multiple: true` on actions/download-artifact, all per-classifier libs end
up under `{artifacts-dir}/native/{classifier}/{libfile}` regardless of which
upload they came from.

This script walks the artifacts tree, copies each lib into
`{resources-dir}/{classifier}/`, then verifies every classifier in
`required-classifiers` has exactly one matching library file — matching meaning
its name is one of the platform filenames `lib-name` can take and its payload
starts with a shared-library magic number, so a placeholder cannot pass as a lib.

Inputs (env vars):
    INPUT_ARTIFACTS_DIR: source tree containing native/{classifier}/{libfile}
    INPUT_RESOURCES_DIR: destination Maven resources dir
    INPUT_REQUIRED_CLASSIFIERS: whitespace-separated classifier list
    INPUT_LIB_NAME: library base name; each required classifier must hold exactly
        one of lib{lib-name}.so / lib{lib-name}.dylib / {lib-name}.dll
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

LIB_EXTENSIONS = (".so", ".dylib", ".dll")

# Leading bytes of every shared library this action can legitimately stage: ELF (.so), Mach-O in
# its four byte orders plus the universal-binary header (.dylib), and the DOS stub of a PE image
# (.dll). A dry-run placeholder, a truncated upload or a zero-byte file matches none of them, and
# nothing further downstream inspects the payload before it lands in a published JAR. ~keep
LIB_MAGIC_NUMBERS = (
    b"\x7fELF",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"MZ",
)
MAGIC_PREFIX_BYTES = max(len(magic) for magic in LIB_MAGIC_NUMBERS)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"::error::stage-java-natives: '{name}' is empty", file=sys.stderr)
        sys.exit(1)
    return value


def discover_libs(artifacts_dir: Path) -> list[Path]:
    libs: list[Path] = []
    for ext in LIB_EXTENSIONS:
        libs.extend(artifacts_dir.rglob(f"*{ext}"))
    return sorted(libs)


def stage_libs(libs: list[Path], resources_dir: Path) -> dict[str, list[Path]]:
    """Copy each lib into {resources_dir}/{classifier}/ and return a map of
    classifier -> staged file paths.
    """
    staged: dict[str, list[Path]] = {}
    resources_dir.mkdir(parents=True, exist_ok=True)
    for lib in libs:
        classifier = lib.parent.name
        target_dir = resources_dir / classifier
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / lib.name
        shutil.copy2(lib, target)
        staged.setdefault(classifier, []).append(target)
    return staged


def expected_lib_filenames(lib_name: str) -> tuple[str, ...]:
    """The exact filenames build-java-natives emits for `lib_name`, one per platform."""
    return (f"lib{lib_name}.so", f"lib{lib_name}.dylib", f"{lib_name}.dll")


def is_native_library(path: Path) -> bool:
    """True when `path` begins with a shared-library magic number."""
    try:
        with path.open("rb") as handle:
            return handle.read(MAGIC_PREFIX_BYTES).startswith(LIB_MAGIC_NUMBERS)
    except OSError:
        return False


def verify_required(
    staged: dict[str, list[Path]],
    resources_dir: Path,
    required: list[str],
    lib_name: str,
) -> None:
    expected = expected_lib_filenames(lib_name)
    failures: list[str] = []
    for classifier in required:
        candidates = [staged_lib for staged_lib in staged.get(classifier, []) if staged_lib.name in expected]
        if not candidates:
            failures.append(
                f"missing lib for classifier '{classifier}' (expected one of "
                f"{', '.join(expected)} under {resources_dir}/{classifier}/)"
            )
        elif len(candidates) > 1:
            names = ", ".join(sorted(staged_lib.name for staged_lib in candidates))
            failures.append(
                f"ambiguous lib for classifier '{classifier}': exactly one of "
                f"{', '.join(expected)} must be staged under {resources_dir}/{classifier}/, found {names}"
            )
        elif not is_native_library(candidates[0]):
            size = candidates[0].stat().st_size if candidates[0].is_file() else 0
            failures.append(
                f"lib for classifier '{classifier}' is not a shared library: {candidates[0]} "
                f"({size} bytes) carries no ELF/Mach-O/PE magic -- a dry-run placeholder?"
            )
    if failures:
        for failure in failures:
            print(f"::error::stage-java-natives: {failure}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    artifacts_dir = Path(require_env("INPUT_ARTIFACTS_DIR"))
    resources_dir = Path(require_env("INPUT_RESOURCES_DIR"))
    required = require_env("INPUT_REQUIRED_CLASSIFIERS").split()
    lib_name = require_env("INPUT_LIB_NAME")

    if not artifacts_dir.is_dir():
        print(
            f"::error::stage-java-natives: artifacts-dir '{artifacts_dir}' does not exist",
            file=sys.stderr,
        )
        sys.exit(1)

    libs = discover_libs(artifacts_dir)
    if not libs:
        print(
            f"::error::stage-java-natives: no *.so/*.dylib/*.dll files found under '{artifacts_dir}'",
            file=sys.stderr,
        )
        sys.exit(1)

    staged = stage_libs(libs, resources_dir)

    print("=== Staged native resources ===")
    for path in sorted(p for files in staged.values() for p in files):
        print(path)

    verify_required(staged, resources_dir, required, lib_name)
    print(f"stage-java-natives: all {len(required)} required classifier(s) present.")


if __name__ == "__main__":
    main()
