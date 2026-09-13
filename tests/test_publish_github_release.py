import importlib.util
from pathlib import Path

import pytest

_ENSURE_RELEASE_PATH = Path(__file__).resolve().parents[1] / "publish-github-release" / "scripts" / "ensure_release.py"
_UPLOAD_ARTIFACTS_PATH = (
    Path(__file__).resolve().parents[1] / "publish-github-release" / "scripts" / "upload_artifacts.py"
)


def _import_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ensure_mod = _import_script("ensure_release", _ENSURE_RELEASE_PATH)
upload_mod = _import_script("upload_artifacts", _UPLOAD_ARTIFACTS_PATH)


def _capture_payload(monkeypatch):
    """Return a list that will be populated with the body_dict passed to github_request."""
    captured = []

    def _fake_github_request(method, url, token, data=None):
        captured.append(data)
        return 201, {"id": 1, "upload_url": "https://uploads.example.com/assets{?name,label}"}

    monkeypatch.setattr(ensure_mod, "github_request", _fake_github_request)
    return captured


def test_create_release_default(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release("owner", "repo", "v1.2.3", "v1.2.3", generate_notes=True, draft=False, prerelease=False)

    payload = captured[0]
    assert payload["tag_name"] == "v1.2.3"
    assert payload["name"] == "v1.2.3"
    assert payload["draft"] is False
    assert payload["prerelease"] is False
    assert payload["generate_release_notes"] is True
    assert "body" not in payload
    assert "target_commitish" not in payload


def test_create_release_posts_to_releases_endpoint(monkeypatch):
    calls = []

    def _fake_github_request(method, url, token, data=None):
        calls.append((method, url))
        return 201, {"id": 1}

    monkeypatch.setattr(ensure_mod, "github_request", _fake_github_request)
    ensure_mod.create_release("owner", "repo", "v1.2.3", "v1.2.3", generate_notes=True, draft=False, prerelease=False)

    method, url = calls[0]
    assert method == "POST"
    assert url == "https://api.github.com/repos/owner/repo/releases"


def test_create_release_draft(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release("owner", "repo", "v1.2.3", "v1.2.3", generate_notes=True, draft=True, prerelease=False)

    payload = captured[0]
    assert payload["draft"] is True
    assert payload["prerelease"] is False


def test_create_release_prerelease(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release("owner", "repo", "v1.2.3", "v1.2.3", generate_notes=True, draft=False, prerelease=True)

    payload = captured[0]
    assert payload["prerelease"] is True
    assert payload["draft"] is False


def test_create_release_no_generate_notes(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release("owner", "repo", "v1.2.3", "v1.2.3", generate_notes=False, draft=False, prerelease=False)

    payload = captured[0]
    assert "generate_release_notes" not in payload
    assert "body" not in payload
    assert payload["tag_name"] == "v1.2.3"
    assert payload["name"] == "v1.2.3"


def test_create_release_target_commitish(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release(
        "owner",
        "repo",
        "v1.2.3",
        "v1.2.3",
        generate_notes=True,
        draft=False,
        prerelease=False,
        target="abc123",
    )

    payload = captured[0]
    assert payload["target_commitish"] == "abc123"


def test_create_release_notes_overrides_generate_notes(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release(
        "owner",
        "repo",
        "v1.2.3",
        "v1.2.3",
        generate_notes=True,
        draft=False,
        prerelease=False,
        notes="Release v1.2.3",
    )

    payload = captured[0]
    assert payload["body"] == "Release v1.2.3"
    assert "generate_release_notes" not in payload


def test_create_release_empty_notes_falls_back_to_generate(monkeypatch):
    captured = _capture_payload(monkeypatch)

    ensure_mod.create_release(
        "owner",
        "repo",
        "v1.2.3",
        "v1.2.3",
        generate_notes=True,
        draft=False,
        prerelease=False,
        notes="",
    )

    payload = captured[0]
    assert payload["generate_release_notes"] is True
    assert "body" not in payload


def test_expand_artifact_patterns(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "package-1.0.0.whl").write_text("fake")
    (tmp_path / "package-1.0.0.tar.gz").write_text("fake")
    (tmp_path / "unrelated.txt").write_text("ignore me")

    result = upload_mod.expand_artifact_patterns("*.whl,*.tar.gz")

    names = {p.name for p in result}
    assert "package-1.0.0.whl" in names
    assert "package-1.0.0.tar.gz" in names
    assert "unrelated.txt" not in names


def test_expand_artifact_patterns_newline(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "artifact.zip").write_text("fake")

    result = upload_mod.expand_artifact_patterns("*.zip\n*.tar.gz")

    assert any(p.name == "artifact.zip" for p in result)


def test_expand_artifact_patterns_no_match(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)

    result = upload_mod.expand_artifact_patterns("*.nupkg,*.whl")

    assert result == []


def test_expand_artifact_patterns_mixed(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "found.whl").write_text("fake")

    result = upload_mod.expand_artifact_patterns("*.whl,*.tar.gz")

    assert len(result) == 1
    assert result[0].name == "found.whl"


def _upload_env(monkeypatch, tmp_path):
    """Put main() in an empty cwd with every required input satisfied but no matching files."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("INPUT_TAG", "v1.2.3")
    monkeypatch.setenv("INPUT_ARTIFACTS", "dist/*.whl")
    monkeypatch.setenv("GH_TOKEN", "fake-token")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.delenv("INPUT_FAIL_IF_EMPTY", raising=False)

    def _must_not_run(*_args, **_kwargs):
        raise AssertionError("the release lookup must not run when no artifacts matched")

    monkeypatch.setattr(upload_mod, "get_release_by_tag", _must_not_run)


def test_main_exits_nonzero_when_no_artifacts_match(tmp_path, monkeypatch, capsys):
    _upload_env(monkeypatch, tmp_path)

    with pytest.raises(SystemExit) as exc_info:
        upload_mod.main()

    assert exc_info.value.code == 1, "a zero-match artifact glob must not report success"
    assert "dist/*.whl" in capsys.readouterr().err


def test_main_warns_instead_of_failing_when_fail_if_empty_is_false(tmp_path, monkeypatch, capsys):
    _upload_env(monkeypatch, tmp_path)
    monkeypatch.setenv("INPUT_FAIL_IF_EMPTY", "false")

    upload_mod.main()

    assert "::warning::" in capsys.readouterr().out


def test_main_uploads_when_artifacts_match(tmp_path, monkeypatch):
    _upload_env(monkeypatch, tmp_path)
    (tmp_path / "dist").mkdir()
    (tmp_path / "dist" / "pkg-1.0.0.whl").write_text("fake")

    monkeypatch.setattr(
        upload_mod,
        "get_release_by_tag",
        lambda *_a, **_k: {"upload_url": "https://uploads.example.com/assets{?name,label}", "assets": []},
    )
    uploaded = []
    monkeypatch.setattr(upload_mod, "upload_asset", lambda _url, name, *_a, **_k: uploaded.append(name))

    upload_mod.main()

    assert uploaded == ["pkg-1.0.0.whl"]


# ~keep Regression coverage for the read-after-write race reported from tslp v1.19.1: the
# create step made a draft at 13:36:19 and the upload step failed at 13:36:28 with
# "not found (checked drafts and published)" -- 8.3s later, against a draft that was real and
# sat at index 0 of page 1 of the listing. One fact derived twice across an eventual-consistency
# window. These pin the pass-through that removes the second derivation.
def test_upload_uses_the_release_id_from_the_create_step_without_consulting_the_listing(monkeypatch):
    def _must_not_run(*_args, **_kwargs):
        raise AssertionError(
            "upload re-derived the release from the listing endpoint despite holding the id "
            "the create step resolved -- this is the race that failed tslp v1.19.1"
        )

    monkeypatch.setattr(upload_mod, "find_release_by_tag", _must_not_run)
    monkeypatch.setattr(
        upload_mod, "get_release_by_id", lambda owner, repo, rid, token: {"id": rid, "tag_name": "v1.19.1"}
    )
    monkeypatch.setenv("INPUT_RELEASE_ID", "4242")

    release = upload_mod.get_release_by_tag("owner", "repo", "v1.19.1", "token")

    assert release == {"id": 4242, "tag_name": "v1.19.1"}


def test_upload_falls_back_to_the_listing_when_no_release_id_was_passed(monkeypatch):
    monkeypatch.delenv("INPUT_RELEASE_ID", raising=False)
    monkeypatch.setattr(upload_mod, "find_release_by_tag", lambda owner, repo, tag, token: {"id": 7, "tag_name": tag})

    release = upload_mod.get_release_by_tag("owner", "repo", "v1.19.1", "token")

    assert release == {"id": 7, "tag_name": "v1.19.1"}


def test_upload_falls_back_to_the_listing_when_the_passed_release_id_does_not_resolve(monkeypatch, capsys):
    monkeypatch.setenv("INPUT_RELEASE_ID", "4242")
    monkeypatch.setattr(upload_mod, "get_release_by_id", lambda owner, repo, rid, token: None)
    monkeypatch.setattr(upload_mod, "find_release_by_tag", lambda owner, repo, tag, token: {"id": 9, "tag_name": tag})

    release = upload_mod.get_release_by_tag("owner", "repo", "v1.19.1", "token")

    assert release == {"id": 9, "tag_name": "v1.19.1"}
    assert "did not resolve" in capsys.readouterr().err


def test_ensure_release_publishes_the_resolved_release_id_for_the_upload_step(monkeypatch, tmp_path):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))

    ensure_mod.write_github_output("release-id", "4242")

    assert output.read_text(encoding="utf-8") == "release-id=4242\n"
