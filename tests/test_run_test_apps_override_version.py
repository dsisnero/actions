import importlib.util
from pathlib import Path

import pytest
import tomlkit.exceptions

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "run-test-apps" / "scripts" / "override_version.py"


def _import_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


override_mod = _import_script("run_test_apps_override_version", _SCRIPT_PATH)

_ENV_VARS = ("INPUT_LANGUAGE", "INPUT_VERSION", "INPUT_WORKING_DIRECTORY")

MANIFEST = """# managed by alef — do not edit by hand
[crates.crawlberg.e2e.registry.packages.python]
name = "crawlberg"
version = "1.0.0"

[crates.crawlberg.e2e.registry.packages.node]
name = "@xberg-io/crawlberg"
version = "1.0.0"
"""


@pytest.fixture
def isolated_env(tmp_path, monkeypatch) -> Path:
    """Run from an empty cwd with no inherited INPUT_* variables."""
    for name in _ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)
    return tmp_path


def _write_manifest(root: Path, content: str = MANIFEST) -> Path:
    path = root / "alef.toml"
    path.write_text(content)
    return path


def _set_inputs(monkeypatch, **inputs: str) -> None:
    for key, value in inputs.items():
        monkeypatch.setenv(f"INPUT_{key.upper()}", value)


def test_should_rewrite_only_the_requested_language_version(isolated_env, monkeypatch):
    manifest = _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="python", version="2.3.4", working_directory=str(isolated_env))

    override_mod.main()

    assert manifest.read_text() == (
        "# managed by alef — do not edit by hand\n"
        "[crates.crawlberg.e2e.registry.packages.python]\n"
        'name = "crawlberg"\n'
        'version = "2.3.4"\n'
        "\n"
        "[crates.crawlberg.e2e.registry.packages.node]\n"
        'name = "@xberg-io/crawlberg"\n'
        'version = "1.0.0"\n'
    )


def test_should_leave_the_manifest_byte_identical_when_the_version_already_matches(isolated_env, monkeypatch):
    manifest = _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="python", version="1.0.0", working_directory=str(isolated_env))

    override_mod.main()

    assert manifest.read_text() == MANIFEST


def test_should_report_the_crate_path_it_updated(isolated_env, monkeypatch, capsys):
    _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="node", version="9.9.9", working_directory=str(isolated_env))

    override_mod.main()

    assert capsys.readouterr().out == (
        "Updated crawlberg.e2e.registry.packages.node.version to 9.9.9\nSuccessfully updated alef.toml\n"
    )


def test_should_update_every_crate_that_declares_the_language(isolated_env, monkeypatch):
    manifest = _write_manifest(
        isolated_env,
        "[crates.core.e2e.registry.packages.python]\n"
        'version = "1.0.0"\n'
        "\n"
        "[crates.extras.e2e.registry.packages.python]\n"
        'version = "1.0.0"\n',
    )
    _set_inputs(monkeypatch, language="python", version="4.5.6", working_directory=str(isolated_env))

    override_mod.main()

    assert manifest.read_text() == (
        "[crates.core.e2e.registry.packages.python]\n"
        'version = "4.5.6"\n'
        "\n"
        "[crates.extras.e2e.registry.packages.python]\n"
        'version = "4.5.6"\n'
    )


def test_should_add_a_version_key_when_the_package_entry_declares_none(isolated_env, monkeypatch):
    manifest = _write_manifest(
        isolated_env,
        '[crates.core.e2e.registry.packages.python]\nname = "crawlberg"\n',
    )
    _set_inputs(monkeypatch, language="python", version="7.0.0", working_directory=str(isolated_env))

    override_mod.main()

    assert manifest.read_text() == (
        '[crates.core.e2e.registry.packages.python]\nname = "crawlberg"\nversion = "7.0.0"\n'
    )


def test_should_rewrite_an_inline_table_package_entry(isolated_env, monkeypatch):
    manifest = _write_manifest(
        isolated_env,
        '[crates.core.e2e.registry.packages]\npython = { name = "crawlberg", version = "1.0.0" }\n',
    )
    _set_inputs(monkeypatch, language="python", version="8.1.0", working_directory=str(isolated_env))

    override_mod.main()

    assert manifest.read_text() == (
        '[crates.core.e2e.registry.packages]\npython = { name = "crawlberg", version = "8.1.0" }\n'
    )


def test_should_strip_surrounding_whitespace_from_the_inputs(isolated_env, monkeypatch):
    manifest = _write_manifest(isolated_env)
    _set_inputs(
        monkeypatch,
        language="  python  ",
        version="  2.0.0\n",
        working_directory=f" {isolated_env} ",
    )

    override_mod.main()

    assert 'version = "2.0.0"' in manifest.read_text()


def test_should_resolve_the_manifest_from_the_process_cwd_when_no_working_directory_is_given(isolated_env, monkeypatch):
    manifest = _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="python", version="3.3.3")

    override_mod.main()

    assert 'version = "3.3.3"' in manifest.read_text()


def test_should_exit_one_when_the_language_input_is_missing(isolated_env, monkeypatch, capsys):
    _write_manifest(isolated_env)
    _set_inputs(monkeypatch, version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "::error::INPUT_LANGUAGE is required\n"


def test_should_exit_one_when_the_language_input_is_only_whitespace(isolated_env, monkeypatch, capsys):
    _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="   ", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "::error::INPUT_LANGUAGE is required\n"


def test_should_exit_one_when_the_version_input_is_missing(isolated_env, monkeypatch, capsys):
    _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="python", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "::error::INPUT_VERSION is required\n"


def test_should_exit_one_when_the_manifest_does_not_exist(isolated_env, monkeypatch, capsys):
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == f"::error::alef.toml not found at {isolated_env / 'alef.toml'}\n"


def test_should_exit_one_and_leave_the_manifest_untouched_when_the_language_is_absent(
    isolated_env, monkeypatch, capsys
):
    manifest = _write_manifest(isolated_env)
    _set_inputs(monkeypatch, language="ruby", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "::error::No matching package entry for language 'ruby' found in alef.toml\n"
    assert manifest.read_text() == MANIFEST


def test_should_exit_one_when_the_package_entry_is_a_bare_string(isolated_env, monkeypatch, capsys):
    """A `python = "1.0.0"` shorthand has no version key to rewrite — silently passing would ship the old pin."""
    manifest = _write_manifest(
        isolated_env,
        '[crates.core.e2e.registry.packages]\npython = "1.0.0"\n',
    )
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    assert manifest.read_text() == '[crates.core.e2e.registry.packages]\npython = "1.0.0"\n'
    assert capsys.readouterr().err == (
        "::error::Package entry for language 'python' is not a table and has no version key to override: "
        'core.e2e.registry.packages.python. Expand it to `python = { version = "..." }` in alef.toml.\n'
    )


def test_should_name_every_crate_whose_package_entry_is_a_bare_string(isolated_env, monkeypatch, capsys):
    _write_manifest(
        isolated_env,
        '[crates.core.e2e.registry.packages]\npython = "1.0.0"\n'
        "\n"
        '[crates.extras.e2e.registry.packages]\npython = "1.0.0"\n',
    )
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit):
        override_mod.main()

    stderr = capsys.readouterr().err
    assert "core.e2e.registry.packages.python, extras.e2e.registry.packages.python" in stderr


def test_should_exit_one_when_the_manifest_has_no_crates_table(isolated_env, monkeypatch):
    _write_manifest(isolated_env, '[workspace]\nmembers = ["core"]\n')
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1


def test_should_exit_one_when_a_crate_has_no_e2e_registry_section(isolated_env, monkeypatch):
    _write_manifest(isolated_env, "[crates.core.e2e]\nenabled = true\n")
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1


def test_should_exit_one_when_the_registry_has_no_packages_table(isolated_env, monkeypatch):
    _write_manifest(isolated_env, '[crates.core.e2e.registry]\nurl = "https://example.invalid"\n')
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1


def test_should_exit_one_with_an_error_annotation_when_the_manifest_is_malformed(isolated_env, monkeypatch, capsys):
    """A syntax error must surface as an ::error:: annotation, like every other failure path here."""
    _write_manifest(isolated_env, "[crates\nbroken =\n")
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit) as exc_info:
        override_mod.main()

    assert exc_info.value.code == 1
    stderr = capsys.readouterr().err
    assert stderr.startswith(f"::error::Failed to parse {isolated_env / 'alef.toml'}: ")
    assert stderr.endswith("\n")


def test_should_not_swallow_the_parser_diagnostic_when_the_manifest_is_malformed(isolated_env, monkeypatch, capsys):
    _write_manifest(isolated_env, "[crates\nbroken =\n")
    _set_inputs(monkeypatch, language="python", version="2.0.0", working_directory=str(isolated_env))

    with pytest.raises(SystemExit):
        override_mod.main()

    expected = str(_parse_error_for("[crates\nbroken =\n"))
    assert expected in capsys.readouterr().err


def _parse_error_for(content: str) -> tomlkit.exceptions.ParseError:
    try:
        tomlkit.parse(content)
    except tomlkit.exceptions.ParseError as error:
        return error
    raise AssertionError("expected the fixture content to be unparseable")
