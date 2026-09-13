"""Tests for stage-java-natives/scripts/stage.py."""

import importlib.util
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "stage-java-natives" / "scripts" / "stage.py"

_INPUT_ENV_VARS = (
    "INPUT_ARTIFACTS_DIR",
    "INPUT_RESOURCES_DIR",
    "INPUT_REQUIRED_CLASSIFIERS",
    "INPUT_LIB_NAME",
)


def _import_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage_mod = _import_script("stage_java_natives", _SCRIPT_PATH)


@pytest.fixture
def clean_inputs(monkeypatch):
    for name in _INPUT_ENV_VARS:
        monkeypatch.delenv(name, raising=False)


_MAGIC_BY_SUFFIX = {".so": b"\x7fELF", ".dylib": b"\xcf\xfa\xed\xfe", ".dll": b"MZ"}


def _library_bytes(classifier: str, filename: str) -> bytes:
    """A payload the staging gate accepts: real magic for the extension, plus a unique tail."""
    magic = _MAGIC_BY_SUFFIX.get(Path(filename).suffix, b"\x7fELF")
    return magic + f"{classifier}/{filename}".encode()


def _make_artifacts_tree(root: Path, libs_by_classifier: dict[str, list[str]]) -> Path:
    artifacts_dir = root / "artifacts"
    for classifier, filenames in libs_by_classifier.items():
        classifier_dir = artifacts_dir / "native" / classifier
        classifier_dir.mkdir(parents=True)
        for filename in filenames:
            (classifier_dir / filename).write_bytes(_library_bytes(classifier, filename))
    return artifacts_dir


def _write_lib(path: Path, payload: bytes | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_library_bytes(path.parent.name, path.name) if payload is None else payload)
    return path


def test_require_env_should_return_the_stripped_value_when_the_variable_is_set(monkeypatch):
    monkeypatch.setenv("INPUT_LIB_NAME", "  xberg_ffi  ")

    assert stage_mod.require_env("INPUT_LIB_NAME") == "xberg_ffi"


def test_require_env_should_exit_with_code_1_when_the_variable_is_unset(monkeypatch, capsys):
    monkeypatch.delenv("INPUT_LIB_NAME", raising=False)

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.require_env("INPUT_LIB_NAME")

    assert excinfo.value.code == 1
    assert capsys.readouterr().err == "::error::stage-java-natives: 'INPUT_LIB_NAME' is empty\n"


def test_require_env_should_exit_with_code_1_when_the_variable_holds_only_whitespace(monkeypatch):
    monkeypatch.setenv("INPUT_LIB_NAME", "   ")

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.require_env("INPUT_LIB_NAME")

    assert excinfo.value.code == 1


def test_discover_libs_should_find_so_dylib_and_dll_files_at_any_depth(tmp_path):
    artifacts_dir = _make_artifacts_tree(
        tmp_path,
        {
            "linux-x86_64": ["libxberg_ffi.so"],
            "darwin-aarch64": ["libxberg_ffi.dylib"],
            "windows-x86_64": ["xberg_ffi.dll"],
        },
    )

    found = stage_mod.discover_libs(artifacts_dir)

    assert [path.name for path in found] == ["libxberg_ffi.dylib", "libxberg_ffi.so", "xberg_ffi.dll"]


def test_discover_libs_should_return_paths_in_sorted_order(tmp_path):
    artifacts_dir = _make_artifacts_tree(
        tmp_path,
        {"b-classifier": ["libxberg_ffi.so"], "a-classifier": ["libxberg_ffi.so"]},
    )

    found = stage_mod.discover_libs(artifacts_dir)

    assert found == sorted(found)
    assert [path.parent.name for path in found] == ["a-classifier", "b-classifier"]


def test_discover_libs_should_ignore_files_without_a_shared_library_extension(tmp_path):
    artifacts_dir = _make_artifacts_tree(tmp_path, {"linux-x86_64": ["libxberg_ffi.so"]})
    (artifacts_dir / "native" / "linux-x86_64" / "xberg_ffi.h").write_text("header")
    (artifacts_dir / "native" / "linux-x86_64" / "libxberg_ffi.a").write_bytes(b"static")

    found = stage_mod.discover_libs(artifacts_dir)

    assert [path.name for path in found] == ["libxberg_ffi.so"]


def test_discover_libs_should_return_an_empty_list_when_the_tree_holds_no_libraries(tmp_path):
    empty_dir = tmp_path / "artifacts"
    empty_dir.mkdir()
    (empty_dir / "README.md").write_text("nothing here")

    assert stage_mod.discover_libs(empty_dir) == []


def test_stage_libs_should_copy_each_library_under_its_parent_directory_name(tmp_path):
    artifacts_dir = _make_artifacts_tree(
        tmp_path,
        {"linux-x86_64": ["libxberg_ffi.so"], "darwin-aarch64": ["libxberg_ffi.dylib"]},
    )
    resources_dir = tmp_path / "resources"

    staged = stage_mod.stage_libs(stage_mod.discover_libs(artifacts_dir), resources_dir)

    assert staged == {
        "darwin-aarch64": [resources_dir / "darwin-aarch64" / "libxberg_ffi.dylib"],
        "linux-x86_64": [resources_dir / "linux-x86_64" / "libxberg_ffi.so"],
    }


def test_stage_libs_should_preserve_the_library_contents_when_copying(tmp_path):
    artifacts_dir = _make_artifacts_tree(tmp_path, {"linux-x86_64": ["libxberg_ffi.so"]})
    resources_dir = tmp_path / "resources"

    stage_mod.stage_libs(stage_mod.discover_libs(artifacts_dir), resources_dir)

    staged_lib = resources_dir / "linux-x86_64" / "libxberg_ffi.so"
    assert staged_lib.read_bytes() == b"\x7fELFlinux-x86_64/libxberg_ffi.so"


def test_stage_libs_should_group_several_libraries_sharing_one_classifier(tmp_path):
    artifacts_dir = _make_artifacts_tree(tmp_path, {"linux-x86_64": ["libxberg_ffi.so", "libextra_dep.so"]})
    resources_dir = tmp_path / "resources"

    staged = stage_mod.stage_libs(stage_mod.discover_libs(artifacts_dir), resources_dir)

    assert sorted(path.name for path in staged["linux-x86_64"]) == ["libextra_dep.so", "libxberg_ffi.so"]


def test_stage_libs_should_create_the_resources_dir_when_it_does_not_exist(tmp_path):
    resources_dir = tmp_path / "deeply" / "nested" / "resources"

    staged = stage_mod.stage_libs([], resources_dir)

    assert staged == {}
    assert resources_dir.is_dir() is True


def test_expected_lib_filenames_should_list_one_exact_filename_per_platform():
    assert stage_mod.expected_lib_filenames("xberg_ffi") == (
        "libxberg_ffi.so",
        "libxberg_ffi.dylib",
        "xberg_ffi.dll",
    )


def test_verify_required_should_return_none_when_every_classifier_has_a_matching_library(tmp_path):
    staged = {
        "linux-x86_64": [_write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.so")],
        "windows-x86_64": [_write_lib(tmp_path / "windows-x86_64" / "xberg_ffi.dll")],
    }

    result = stage_mod.verify_required(staged, tmp_path, ["linux-x86_64", "windows-x86_64"], "xberg_ffi")

    assert result is None


def test_verify_required_should_exit_with_code_1_when_a_required_classifier_was_never_staged(tmp_path, capsys):
    staged = {"linux-x86_64": [_write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.so")]}

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.verify_required(staged, tmp_path, ["linux-x86_64", "darwin-aarch64"], "xberg_ffi")

    assert excinfo.value.code == 1
    assert "'darwin-aarch64'" in capsys.readouterr().err


def test_verify_required_should_exit_with_code_1_when_the_staged_library_has_a_different_lib_name(tmp_path, capsys):
    staged = {"linux-x86_64": [_write_lib(tmp_path / "linux-x86_64" / "libsomething_else.so")]}

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.verify_required(staged, tmp_path, ["linux-x86_64"], "xberg_ffi")

    assert excinfo.value.code == 1
    assert "expected one of libxberg_ffi.so, libxberg_ffi.dylib, xberg_ffi.dll" in capsys.readouterr().err


@pytest.mark.parametrize(
    "filename",
    ["libnot_xberg_ffi_placeholder.so", "libxberg_ffi_extra.so", "libmyxberg_ffi.so", "xberg_ffi.so"],
)
def test_verify_required_should_reject_a_filename_that_merely_contains_the_lib_name(tmp_path, filename):
    """A substring test let libnot_xberg_ffi_placeholder.so satisfy a requirement for xberg_ffi."""
    staged = {"linux-x86_64": [_write_lib(tmp_path / "linux-x86_64" / filename)]}

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.verify_required(staged, tmp_path, ["linux-x86_64"], "xberg_ffi")

    assert excinfo.value.code == 1


def test_verify_required_should_exit_with_code_1_when_a_classifier_holds_two_matching_libraries(tmp_path, capsys):
    """The staging contract promises exactly one lib per classifier; two means the merge went wrong."""
    staged = {
        "linux-x86_64": [
            _write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.so"),
            _write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.dylib"),
        ]
    }

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.verify_required(staged, tmp_path, ["linux-x86_64"], "xberg_ffi")

    assert excinfo.value.code == 1
    assert "ambiguous lib for classifier 'linux-x86_64'" in capsys.readouterr().err
    assert excinfo.value.code == 1


def test_verify_required_should_accept_a_matching_library_beside_unrelated_libraries(tmp_path):
    staged = {
        "linux-x86_64": [
            _write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.so"),
            _write_lib(tmp_path / "linux-x86_64" / "libonnxruntime.so"),
        ]
    }

    assert stage_mod.verify_required(staged, tmp_path, ["linux-x86_64"], "xberg_ffi") is None


@pytest.mark.parametrize(
    ("description", "payload"),
    [
        ("zero bytes", b""),
        ("a dry-run placeholder", b"build-java-natives dry-run placeholder -- not a shared library\n"),
        ("an ASCII linker script", b"INPUT(libxberg_ffi.so.1)\n"),
    ],
)
def test_verify_required_should_exit_with_code_1_when_the_payload_is_not_a_shared_library(
    tmp_path, capsys, description, payload
):
    """A zero-byte dry-run artifact used to pass every check and could land in a published JAR."""
    staged = {"linux-x86_64": [_write_lib(tmp_path / "linux-x86_64" / "libxberg_ffi.so", payload)]}

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.verify_required(staged, tmp_path, ["linux-x86_64"], "xberg_ffi")

    assert excinfo.value.code == 1
    stderr = capsys.readouterr().err
    assert "carries no ELF/Mach-O/PE magic" in stderr, description
    assert f"({len(payload)} bytes)" in stderr


@pytest.mark.parametrize(
    ("filename", "magic"),
    [
        ("libxberg_ffi.so", b"\x7fELF"),
        ("libxberg_ffi.dylib", b"\xcf\xfa\xed\xfe"),
        ("libxberg_ffi.dylib", b"\xca\xfe\xba\xbe"),
        ("xberg_ffi.dll", b"MZ"),
    ],
)
def test_verify_required_should_accept_every_shared_library_format_it_can_stage(tmp_path, filename, magic):
    staged = {"c": [_write_lib(tmp_path / "c" / filename, magic + b"\x00" * 64)]}

    assert stage_mod.verify_required(staged, tmp_path, ["c"], "xberg_ffi") is None


def test_verify_required_should_report_every_missing_classifier_not_just_the_first(tmp_path, capsys):
    with pytest.raises(SystemExit):
        stage_mod.verify_required({}, tmp_path, ["linux-x86_64", "darwin-aarch64", "windows-x86_64"], "xberg_ffi")

    stderr = capsys.readouterr().err
    assert stderr.count("::error::stage-java-natives: missing lib for classifier") == 3


def test_main_should_stage_every_library_and_report_the_classifier_count_on_success(
    clean_inputs, monkeypatch, tmp_path
):
    artifacts_dir = _make_artifacts_tree(
        tmp_path,
        {
            "linux-x86_64": ["libxberg_ffi.so"],
            "darwin-aarch64": ["libxberg_ffi.dylib"],
            "windows-x86_64": ["xberg_ffi.dll"],
        },
    )
    resources_dir = tmp_path / "resources"
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(artifacts_dir))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(resources_dir))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "linux-x86_64 darwin-aarch64 windows-x86_64")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    stage_mod.main()

    assert sorted(
        path.relative_to(resources_dir).as_posix() for path in resources_dir.rglob("*") if path.is_file()
    ) == [
        "darwin-aarch64/libxberg_ffi.dylib",
        "linux-x86_64/libxberg_ffi.so",
        "windows-x86_64/xberg_ffi.dll",
    ]


def test_main_should_split_required_classifiers_on_arbitrary_whitespace(clean_inputs, monkeypatch, tmp_path, capsys):
    artifacts_dir = _make_artifacts_tree(
        tmp_path,
        {"linux-x86_64": ["libxberg_ffi.so"], "darwin-aarch64": ["libxberg_ffi.dylib"]},
    )
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(artifacts_dir))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(tmp_path / "resources"))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "  linux-x86_64 \n\t darwin-aarch64  ")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    stage_mod.main()

    assert "stage-java-natives: all 2 required classifier(s) present." in capsys.readouterr().out


def test_main_should_exit_with_code_1_when_the_artifacts_dir_does_not_exist(
    clean_inputs, monkeypatch, tmp_path, capsys
):
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(tmp_path / "absent"))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(tmp_path / "resources"))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "linux-x86_64")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.main()

    assert excinfo.value.code == 1
    assert capsys.readouterr().err == (
        f"::error::stage-java-natives: artifacts-dir '{tmp_path / 'absent'}' does not exist\n"
    )
    assert (tmp_path / "resources").exists() is False


def test_main_should_exit_with_code_1_when_the_artifacts_dir_holds_no_libraries(
    clean_inputs, monkeypatch, tmp_path, capsys
):
    artifacts_dir = tmp_path / "artifacts"
    artifacts_dir.mkdir()
    (artifacts_dir / "notes.txt").write_text("no libs here")
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(artifacts_dir))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(tmp_path / "resources"))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "linux-x86_64")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.main()

    assert excinfo.value.code == 1
    assert "no *.so/*.dylib/*.dll files found" in capsys.readouterr().err


def test_main_should_exit_with_code_1_when_one_required_classifier_never_arrived(
    clean_inputs, monkeypatch, tmp_path, capsys
):
    artifacts_dir = _make_artifacts_tree(tmp_path, {"linux-x86_64": ["libxberg_ffi.so"]})
    resources_dir = tmp_path / "resources"
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(artifacts_dir))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(resources_dir))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "linux-x86_64 windows-aarch64")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.main()

    assert excinfo.value.code == 1
    assert "'windows-aarch64'" in capsys.readouterr().err
    assert (resources_dir / "linux-x86_64" / "libxberg_ffi.so").is_file() is True


def test_main_should_exit_with_code_1_when_the_required_classifiers_input_is_empty(clean_inputs, monkeypatch, tmp_path):
    monkeypatch.setenv("INPUT_ARTIFACTS_DIR", str(tmp_path))
    monkeypatch.setenv("INPUT_RESOURCES_DIR", str(tmp_path / "resources"))
    monkeypatch.setenv("INPUT_REQUIRED_CLASSIFIERS", "")
    monkeypatch.setenv("INPUT_LIB_NAME", "xberg_ffi")

    with pytest.raises(SystemExit) as excinfo:
        stage_mod.main()

    assert excinfo.value.code == 1
