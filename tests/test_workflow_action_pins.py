"""Every install-bats / install-pester call site must name the version it installs.

`install-bats` used to default to `latest`. A floating default is invisible at the call site:
the workflow reads as if it pins something, the log reports whatever the Gallery or the release
API served that morning, and a run from six months ago cannot be reproduced. The default is now
a real version, but a default only helps the caller who omits the input -- so this asserts the
input is present rather than trusting the default to stay pinned.

Parsed from the committed workflows, so the assertion cannot drift away from what CI really does.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

_WORKFLOWS = sorted((Path(__file__).resolve().parents[1] / ".github" / "workflows").glob("*.yml"))

# Actions whose version input decides which third-party bytes execute in the job.
_MUST_PIN = ("install-bats", "install-pester")


def _uses_pinnable_action(uses: str) -> str | None:
    """Return the action name when `uses` refers to one of ours that must carry a version."""
    for name in _MUST_PIN:
        if uses in (f"./{name}", name) or uses.startswith((f"./{name}@", f"xberg-io/actions/{name}@")):
            return name
        if uses.startswith(f"xberg-io/actions/{name}"):
            return name
    return None


def _steps(document: dict) -> list[tuple[str, dict]]:
    """Yield (job id, step) for every step in the workflow."""
    return [
        (job_id, step)
        for job_id, job in (document.get("jobs") or {}).items()
        if isinstance(job, dict)
        for step in job.get("steps") or []
        if isinstance(step, dict)
    ]


@pytest.mark.parametrize("workflow", _WORKFLOWS, ids=lambda p: p.name)
def test_every_pinnable_action_call_site_names_a_version(workflow: Path) -> None:
    document = yaml.safe_load(workflow.read_text(encoding="utf-8"))
    assert document is not None, f"{workflow.name} is empty"

    unpinned = []
    for job_id, step in _steps(document):
        if _uses_pinnable_action(str(step.get("uses", ""))) is None:
            continue
        version = str((step.get("with") or {}).get("version", "")).strip()
        if not version:
            unpinned.append(f"{workflow.name}:{job_id} uses {step['uses']} without a `version` input")

    assert unpinned == [], "\n".join(unpinned)


def test_the_pin_gate_covers_at_least_one_real_call_site() -> None:
    """A gate that matches nothing passes for the wrong reason.

    If install-bats is ever renamed or every call site removed, this fails and someone decides
    deliberately, rather than the parametrised test above silently going vacuous.
    """
    call_sites = [
        (workflow.name, step["uses"])
        for workflow in _WORKFLOWS
        for _, step in _steps(yaml.safe_load(workflow.read_text(encoding="utf-8")) or {})
        if _uses_pinnable_action(str(step.get("uses", ""))) is not None
    ]
    assert call_sites, "no install-bats/install-pester call sites found; has the action been renamed?"
