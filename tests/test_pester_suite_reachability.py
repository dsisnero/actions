"""Every Pester suite in the tree must actually be run by a workflow.

`bats --recursive .` discovers suites, so a new Bats file cannot go unrun. Pester has no
equivalent: `run-pester` takes one `path`, and `test-pester.yml` names its paths explicitly. That
is the same shape as pytest's `testpaths`, which is how several per-action suites in this repo sat
uncollected long enough for one of them to keep asserting an exit code the script had stopped
returning.

A suite nobody runs is worse than no suite: it reads as coverage. So the property gets a gate.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
import yaml

_ROOT = Path(__file__).resolve().parents[1]
_WORKFLOW = _ROOT / ".github" / "workflows" / "test-pester.yml"


def _tracked_pester_suites() -> list[str]:
    """Suites as git sees them, so an untracked scratch file never fails the gate."""
    completed = subprocess.run(  # noqa: S603
        ["git", "ls-files", "*.Tests.ps1"],  # noqa: S607
        cwd=_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return sorted(line for line in completed.stdout.splitlines() if line.strip())


def _covered_paths() -> list[str]:
    """The `path:` values test-pester.yml hands to run-pester."""
    document = yaml.safe_load(_WORKFLOW.read_text(encoding="utf-8"))
    return [
        str(step["with"]["path"]).strip("/")
        for job in (document.get("jobs") or {}).values()
        if isinstance(job, dict)
        for step in job.get("steps") or []
        if isinstance(step, dict)
        and str(step.get("uses", "")).endswith("run-pester")
        and (step.get("with") or {}).get("path")
    ]


def test_every_pester_suite_is_reached_by_the_workflow() -> None:
    covered = _covered_paths()
    assert covered, "test-pester.yml runs no run-pester steps"

    unreached = [
        suite
        for suite in _tracked_pester_suites()
        if not any(suite == path or suite.startswith(f"{path}/") for path in covered)
    ]
    assert unreached == [], (
        "these Pester suites are committed but no workflow step runs them:\n"
        + "\n".join(f"  {suite}" for suite in unreached)
        + f"\ncovered paths: {covered}\n"
        "Add a run-pester step in .github/workflows/test-pester.yml."
    )


def test_every_covered_path_still_contains_a_suite() -> None:
    """The other direction: a stale `path:` naming a directory with no suites.

    Without this the gate above stays green while silently covering nothing, which is how an
    allowance file becomes a graveyard.
    """
    suites = _tracked_pester_suites()
    stale = [
        path for path in _covered_paths() if not any(suite == path or suite.startswith(f"{path}/") for suite in suites)
    ]
    assert stale == [], f"test-pester.yml names paths that hold no *.Tests.ps1 suites: {stale}"


@pytest.mark.parametrize("suite", _tracked_pester_suites())
def test_every_pester_suite_is_tracked_under_a_tests_directory(suite: str) -> None:
    """Keeps discovery predictable: suites live in `<action>/tests/`, like the Bats ones."""
    assert "/tests/" in suite, f"{suite} is not under a tests/ directory"
