import importlib.util
import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "build-android-natives" / "scripts" / "build.py"


def _import_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


android_mod = _import_script("build_android_natives", _SCRIPT_PATH)

_ENV_VARS = (
    "INPUT_CRATE_NAME",
    "INPUT_LIB_NAME",
    "INPUT_ABIS",
    "INPUT_API_LEVEL",
    "INPUT_OUTPUT_DIR",
    "INPUT_FEATURES",
    "INPUT_NO_DEFAULT_FEATURES",
    "INPUT_DRY_RUN",
    "GITHUB_OUTPUT",
)


_FAKE_CARGO_NDK_PATH = "/fake/bin/cargo-ndk"


@pytest.fixture
def isolated_env(tmp_path, monkeypatch) -> Path:
    """Run from an empty cwd with no inherited INPUT_*/GITHUB_OUTPUT and cargo-ndk reported present.

    The cargo-ndk probe is stubbed here rather than per-test so no test's outcome depends on
    whether the machine running it happens to have cargo-ndk installed. ~keep
    """
    for name in _ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(android_mod.shutil, "which", lambda _name: _FAKE_CARGO_NDK_PATH)
    return tmp_path


@pytest.fixture
def output_sink(isolated_env, monkeypatch) -> Path:
    """GITHUB_OUTPUT pointed at a fresh file; depends on isolated_env so it wins the ordering."""
    sink = isolated_env / "github_output.txt"
    sink.touch()
    monkeypatch.setenv("GITHUB_OUTPUT", str(sink))
    return sink


@pytest.fixture
def recorded_commands(monkeypatch) -> list[list[str]]:
    """Replace subprocess.run with a recorder so the host toolchain is never probed."""
    calls: list[list[str]] = []

    def fake_run(cmd, **_kwargs):
        calls.append(list(cmd))
        return subprocess.CompletedProcess(list(cmd), 0)

    monkeypatch.setattr(android_mod.subprocess, "run", fake_run)
    return calls


def _install_runner(
    monkeypatch,
    calls: list[list[str]],
    *,
    cargo_ndk_installed: bool = True,
    on_build: Callable[[list[str]], None] | None = None,
) -> None:
    def fake_run(cmd, **_kwargs):
        cmd = list(cmd)
        calls.append(cmd)
        if on_build is not None and cmd[:2] == ["cargo", "ndk"]:
            on_build(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(android_mod.subprocess, "run", fake_run)
    monkeypatch.setattr(
        android_mod.shutil,
        "which",
        lambda _name: _FAKE_CARGO_NDK_PATH if cargo_ndk_installed else None,
    )


def _stage_libraries(
    output_dir: Path,
    lib_name: str,
    *,
    skip_abis: frozenset[str] = frozenset(),
    empty_abis: frozenset[str] = frozenset(),
) -> Callable[[list[str]], None]:
    """Mimic cargo-ndk copying lib<name>.so into <output-dir>/<abi>/ for the ABI being built."""

    def stage(cmd: list[str]) -> None:
        abi = cmd[cmd.index("--target") + 1]
        if abi in skip_abis:
            return
        abi_dir = output_dir / abi
        abi_dir.mkdir(parents=True, exist_ok=True)
        payload = b"" if abi in empty_abis else b"\x7fELF" + b"\x00" * 60
        (abi_dir / f"lib{lib_name}.so").write_bytes(payload)

    return stage


def _set_inputs(monkeypatch, **inputs: str) -> None:
    for key, value in inputs.items():
        monkeypatch.setenv(f"INPUT_{key.upper()}", value)


def test_should_map_each_supported_abi_to_its_rust_target():
    assert android_mod.ABI_TO_RUST_TARGET == {
        "arm64-v8a": "aarch64-linux-android",
        "x86_64": "x86_64-linux-android",
        "x86": "i686-linux-android",
        "armeabi-v7a": "armv7-linux-androideabi",
    }


def test_should_return_the_value_when_a_required_input_is_present():
    assert android_mod.ensure_input("INPUT_CRATE_NAME", "xberg-jni") == "xberg-jni"


def test_should_exit_one_when_a_required_input_is_empty(capsys):
    with pytest.raises(SystemExit) as exc_info:
        android_mod.ensure_input("INPUT_CRATE_NAME", "")

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: INPUT_CRATE_NAME is required\n"


def test_should_append_to_the_github_output_file_when_the_sink_is_set(github_output):
    github_output.write_text("pre-existing=1\n", encoding="utf-8")

    android_mod.write_github_output("output-dir", "dist/android-natives")

    assert github_output.read_text(encoding="utf-8") == "pre-existing=1\noutput-dir=dist/android-natives\n"


def test_should_write_to_stdout_when_github_output_is_unset(monkeypatch, capsys):
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)

    android_mod.write_github_output("output-dir", "dist/android-natives")

    assert capsys.readouterr().out == "output-dir=dist/android-natives\n"


def test_should_accept_the_staging_when_every_abi_has_a_non_empty_library(tmp_path, capsys):
    for abi in ("arm64-v8a", "x86_64"):
        (tmp_path / abi).mkdir()
        (tmp_path / abi / "libxberg_jni.so").write_bytes(b"\x7fELF")

    assert android_mod.verify_staged_libs(tmp_path, ["arm64-v8a", "x86_64"], "xberg_jni") is None
    assert capsys.readouterr().err == ""


def test_should_exit_one_and_name_only_the_abi_whose_library_is_absent(tmp_path, capsys):
    (tmp_path / "arm64-v8a").mkdir()
    (tmp_path / "arm64-v8a" / "libxberg_jni.so").write_bytes(b"\x7fELF")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.verify_staged_libs(tmp_path, ["arm64-v8a", "x86_64"], "xberg_jni")

    assert exc_info.value.code == 1
    err_lines = capsys.readouterr().err.splitlines()
    assert err_lines[0] == "Error: expected libxberg_jni.so was not staged for: x86_64"
    assert (
        err_lines[1]
        == f"  x86_64: missing {tmp_path / 'x86_64' / 'libxberg_jni.so'} (found in {tmp_path / 'x86_64'}: nothing)"
    )


def test_should_exit_one_when_the_staged_library_is_zero_bytes(tmp_path):
    (tmp_path / "x86_64").mkdir()
    (tmp_path / "x86_64" / "libxberg_jni.so").write_bytes(b"")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.verify_staged_libs(tmp_path, ["x86_64"], "xberg_jni")

    assert exc_info.value.code == 1


def test_should_list_the_wrongly_named_library_it_found_instead(tmp_path, capsys):
    """A misnamed cdylib is the html-to-markdown#446 failure mode — the wrong name must be logged."""
    (tmp_path / "x86_64").mkdir()
    (tmp_path / "x86_64" / "libxberg_ffi.so").write_bytes(b"\x7fELF")

    with pytest.raises(SystemExit):
        android_mod.verify_staged_libs(tmp_path, ["x86_64"], "xberg_jni")

    assert "['libxberg_ffi.so']" in capsys.readouterr().err


def test_should_exit_one_when_the_crate_name_is_missing(isolated_env, recorded_commands, capsys):
    with pytest.raises(SystemExit) as exc_info:
        android_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: INPUT_CRATE_NAME is required\n"
    assert recorded_commands == []


def test_should_exit_one_when_the_abi_list_is_blank(isolated_env, monkeypatch, recorded_commands, capsys):
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis=" , ")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: no ABIs specified\n"
    assert recorded_commands == []


def test_should_exit_one_and_name_every_unknown_abi(isolated_env, monkeypatch, recorded_commands, capsys):
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="arm64-v8a,mips,riscv64")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: unknown ABIs: mips, riscv64\n"
    assert recorded_commands == []


def test_should_skip_the_build_and_emit_a_relative_output_dir_when_dry_run(
    output_sink, monkeypatch, recorded_commands, capsys
):
    _set_inputs(monkeypatch, crate_name="xberg-jni", dry_run="true")

    android_mod.main()

    assert recorded_commands == []
    assert output_sink.read_text(encoding="utf-8") == "output-dir=dist/android-natives\n"
    out = capsys.readouterr().out
    assert "[build-android-natives] dry-run: skipping cargo-ndk build" in out
    assert "    arm64-v8a    -> dist/android-natives/arm64-v8a/libxberg_jni.so" in out
    assert "    x86_64       -> dist/android-natives/x86_64/libxberg_jni.so" in out


def test_should_emit_a_resolved_output_dir_when_dry_run_and_the_directory_already_exists(
    isolated_env, output_sink, monkeypatch, recorded_commands
):
    output_dir = isolated_env / "dist" / "android-natives"
    output_dir.mkdir(parents=True)
    _set_inputs(monkeypatch, crate_name="xberg-jni", dry_run="true")

    android_mod.main()

    assert output_sink.read_text(encoding="utf-8") == f"output-dir={output_dir.resolve()}\n"


def test_should_derive_the_lib_name_from_the_crate_name_when_lib_name_is_unset(
    output_sink, monkeypatch, recorded_commands, capsys
):
    _set_inputs(monkeypatch, crate_name="xberg-android-jni", abis="x86_64", dry_run="true")

    android_mod.main()

    assert "  lib:       xberg_android_jni\n" in capsys.readouterr().out


def test_should_prefer_an_explicit_lib_name_over_the_crate_name(output_sink, monkeypatch, recorded_commands, capsys):
    _set_inputs(monkeypatch, crate_name="xberg-android-jni", lib_name="crawlberg_jni", abis="x86_64", dry_run="true")

    android_mod.main()

    out = capsys.readouterr().out
    assert "  lib:       crawlberg_jni\n" in out
    assert "    x86_64       -> dist/android-natives/x86_64/libcrawlberg_jni.so" in out


def test_should_add_each_rust_target_once_when_an_abi_is_repeated(isolated_env, output_sink, monkeypatch):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch, calls, on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64,x86_64")

    android_mod.main()

    assert [c for c in calls if c[0] == "rustup"] == [["rustup", "target", "add", "x86_64-linux-android"]]


def test_should_install_cargo_ndk_when_it_is_not_on_path(isolated_env, output_sink, monkeypatch, capsys):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch,
        calls,
        cargo_ndk_installed=False,
        on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni"),
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    android_mod.main()

    assert ["cargo", "install", "cargo-ndk", "--locked"] in calls
    assert "[build-android-natives] Installing cargo-ndk..." in capsys.readouterr().out


def test_should_not_install_cargo_ndk_when_it_is_already_on_path(isolated_env, output_sink, monkeypatch, capsys):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch, calls, on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    android_mod.main()

    assert ["cargo", "install", "cargo-ndk", "--locked"] not in calls
    assert "[build-android-natives] cargo-ndk already installed" in capsys.readouterr().out


def test_should_probe_for_cargo_ndk_without_shelling_out_to_the_which_binary(isolated_env, output_sink, monkeypatch):
    """A runner without /usr/bin/which used to crash with FileNotFoundError instead of installing."""
    calls: list[list[str]] = []

    def fake_run(cmd, **_kwargs):
        cmd = list(cmd)
        if cmd[0] == "which":
            raise FileNotFoundError(2, "No such file or directory: 'which'")
        calls.append(cmd)
        if cmd[:2] == ["cargo", "ndk"]:
            _stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(android_mod.subprocess, "run", fake_run)
    monkeypatch.setattr(android_mod.shutil, "which", lambda _name: None)
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    android_mod.main()

    assert ["cargo", "install", "cargo-ndk", "--locked"] in calls


def test_should_build_a_repeated_abi_only_once(isolated_env, output_sink, monkeypatch):
    """Deduplication used to apply to `rustup target add` only, so cargo ndk ran twice per ABI."""
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch, calls, on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64,x86_64,arm64-v8a,x86_64")

    android_mod.main()

    built_abis = [c[c.index("--target") + 1] for c in calls if c[:2] == ["cargo", "ndk"]]
    assert built_abis == ["x86_64", "arm64-v8a"]


def test_should_list_a_repeated_abi_only_once_in_the_dry_run_plan(output_sink, monkeypatch, capsys):
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64,x86_64", dry_run="true")

    android_mod.main()

    out = capsys.readouterr().out
    assert "  abis:      x86_64\n" in out
    assert out.count("-> dist/android-natives/x86_64/libxberg_jni.so") == 1


def test_should_build_every_abi_with_the_requested_api_level_and_output_dir(isolated_env, output_sink, monkeypatch):
    calls: list[list[str]] = []
    _install_runner(monkeypatch, calls, on_build=_stage_libraries(isolated_env / "natives", "xberg_jni"))
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="arm64-v8a,x86_64", api_level="24", output_dir="natives")

    android_mod.main()

    build_calls = [c for c in calls if c[:2] == ["cargo", "ndk"]]
    assert build_calls == [
        [
            "cargo",
            "ndk",
            "--target",
            abi,
            "--platform",
            "24",
            "-o",
            "natives",
            "build",
            "--locked",
            "-p",
            "xberg-jni",
            "--release",
        ]
        for abi in ("arm64-v8a", "x86_64")
    ]


def test_should_forward_feature_selection_flags_to_cargo_ndk(isolated_env, output_sink, monkeypatch):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch, calls, on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")
    )
    _set_inputs(
        monkeypatch,
        crate_name="xberg-jni",
        abis="x86_64",
        features="jni,ocr",
        no_default_features="true",
    )

    android_mod.main()

    build_call = next(c for c in calls if c[:2] == ["cargo", "ndk"])
    assert build_call[-3:] == ["--no-default-features", "--features", "jni,ocr"]


def test_should_omit_feature_flags_when_no_default_features_is_not_true(isolated_env, output_sink, monkeypatch):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch, calls, on_build=_stage_libraries(isolated_env / "dist" / "android-natives", "xberg_jni")
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64", no_default_features="false", features="")

    android_mod.main()

    build_call = next(c for c in calls if c[:2] == ["cargo", "ndk"])
    assert "--no-default-features" not in build_call
    assert "--features" not in build_call
    assert build_call[-1] == "--release"


def test_should_exit_one_when_cargo_ndk_staged_nothing_for_an_abi(isolated_env, output_sink, monkeypatch, capsys):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch,
        calls,
        on_build=_stage_libraries(
            isolated_env / "dist" / "android-natives",
            "xberg_jni",
            skip_abis=frozenset({"x86_64"}),
        ),
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="arm64-v8a,x86_64")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.main()

    assert exc_info.value.code == 1
    assert "was not staged for: x86_64" in capsys.readouterr().err
    assert output_sink.read_text(encoding="utf-8") == ""


def test_should_exit_one_when_a_staged_library_is_empty(isolated_env, output_sink, monkeypatch):
    calls: list[list[str]] = []
    _install_runner(
        monkeypatch,
        calls,
        on_build=_stage_libraries(
            isolated_env / "dist" / "android-natives",
            "xberg_jni",
            empty_abis=frozenset({"x86_64"}),
        ),
    )
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    with pytest.raises(SystemExit) as exc_info:
        android_mod.main()

    assert exc_info.value.code == 1
    assert output_sink.read_text(encoding="utf-8") == ""


def test_should_emit_the_resolved_output_dir_after_a_successful_build(isolated_env, output_sink, monkeypatch):
    output_dir = isolated_env / "dist" / "android-natives"
    calls: list[list[str]] = []
    _install_runner(monkeypatch, calls, on_build=_stage_libraries(output_dir, "xberg_jni"))
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    android_mod.main()

    assert output_sink.read_text(encoding="utf-8") == f"output-dir={output_dir.resolve()}\n"


def test_should_propagate_the_failure_when_a_cargo_ndk_build_exits_non_zero(isolated_env, output_sink, monkeypatch):
    def failing_run(cmd, **_kwargs):
        if list(cmd)[:2] == ["cargo", "ndk"]:
            raise subprocess.CalledProcessError(101, list(cmd))
        return subprocess.CompletedProcess(list(cmd), 0)

    monkeypatch.setattr(android_mod.subprocess, "run", failing_run)
    _set_inputs(monkeypatch, crate_name="xberg-jni", abis="x86_64")

    with pytest.raises(subprocess.CalledProcessError) as exc_info:
        android_mod.main()

    assert exc_info.value.returncode == 101
    assert output_sink.read_text(encoding="utf-8") == ""
