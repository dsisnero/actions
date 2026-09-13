"""Tests for build-csharp-natives/scripts/build.py.

Every external tool (otool, install_name_tool, codesign, patchelf, ldd) is replaced with an
in-process double, and every environment variable the script reads is cleared or set explicitly,
so nothing here depends on what the host machine happens to have installed. The sibling
musl_builder.py is covered by test_build_csharp_natives_musl_builder.py.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

_SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "build-csharp-natives" / "scripts"


def _load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


musl_mod = _load_script("csharp_musl_builder", _SCRIPTS_DIR / "musl_builder.py")

# build.py resolves `from musl_builder import build_or_fallback` through sys.modules, and three
# actions ship a file of that name. This copy and build-java-natives' are byte-identical, but
# build-elixir-natives' takes a fourth parameter and calls build_in_docker positionally, so if it
# won the shared sys.modules slot a call here would silently bind the wrong argument. Bind this
# action's copy for the exec and restore whatever was there, so import order between test files
# cannot decide which implementation build.py ends up holding. ~keep
_previous_musl = sys.modules.get("musl_builder")
sys.modules["musl_builder"] = musl_mod
try:
    build_mod = _load_script("csharp_build", _SCRIPTS_DIR / "build.py")
finally:
    if _previous_musl is None:
        del sys.modules["musl_builder"]
    else:
        sys.modules["musl_builder"] = _previous_musl


_SCRIPT_ENV_VARS = (
    "INPUT_TARGET",
    "INPUT_RID",
    "INPUT_CRATE_NAME",
    "INPUT_LIB_NAME",
    "INPUT_OUTPUT_DIR",
    "INPUT_DRY_RUN",
    "INPUT_GLIBC_VERSION",
    "GITHUB_OUTPUT",
    "ORT_LIB_LOCATION",
    "ORT_DYLIB_PATH",
    "XDG_CACHE_HOME",
)


@pytest.fixture
def hermetic_env(monkeypatch):
    """Clear every env var the scripts read and blank PATH, so host state cannot leak in."""
    for name in _SCRIPT_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("PATH", "")
    return monkeypatch


class _FakeRunner:
    """A subprocess.run double dispatching on argv[0], recording every invocation."""

    def __init__(self, handlers=None):
        self.handlers = handlers or {}
        self.calls: list[list[str]] = []
        self.kwargs: list[dict] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append(list(cmd))
        self.kwargs.append(kwargs)
        handler = self.handlers.get(cmd[0])
        if handler is None:
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        return handler(list(cmd))

    def argv_for(self, executable: str) -> list[list[str]]:
        return [cmd for cmd in self.calls if cmd[0] == executable]


def _completed(stdout: str = "", returncode: int = 0, stderr: str = "") -> SimpleNamespace:
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


@pytest.mark.parametrize(
    ("target", "expected"),
    [
        ("x86_64-pc-windows-msvc", "xberg_ffi.dll"),
        ("x86_64-pc-windows-gnu", "xberg_ffi.dll"),
        ("aarch64-apple-darwin", "libxberg_ffi.dylib"),
        ("x86_64-apple-darwin", "libxberg_ffi.dylib"),
        ("x86_64-unknown-linux-gnu", "libxberg_ffi.so"),
        ("aarch64-unknown-linux-musl", "libxberg_ffi.so"),
    ],
)
def test_should_name_library_by_platform_convention_when_target_varies(target, expected):
    assert build_mod.library_filename("xberg_ffi", target) == expected


def test_should_resolve_cargo_release_dir_under_the_target_triple():
    assert build_mod.cargo_release_dir("aarch64-apple-darwin") == Path("target/aarch64-apple-darwin/release")


def test_should_append_to_github_output_file_when_env_var_is_set(github_output):
    build_mod.write_github_output("library-path", "/staged/libxberg_ffi.so")
    build_mod.write_github_output("staging-dir", "/staged")

    assert github_output.read_text(encoding="utf-8") == "library-path=/staged/libxberg_ffi.so\nstaging-dir=/staged\n"


def test_should_write_to_stdout_when_github_output_is_unset(hermetic_env, capsys):
    build_mod.write_github_output("library-path", "/staged/libxberg_ffi.so")

    assert capsys.readouterr().out == "library-path=/staged/libxberg_ffi.so\n"


def test_should_return_value_when_required_input_is_present():
    assert build_mod.ensure_input("INPUT_TARGET", "x86_64-unknown-linux-gnu") == "x86_64-unknown-linux-gnu"


def test_should_exit_one_when_required_input_is_empty(capsys):
    with pytest.raises(SystemExit) as exc_info:
        build_mod.ensure_input("INPUT_RID", "")

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: INPUT_RID is required\n"


@pytest.mark.parametrize(
    ("dep", "expected"),
    [
        ("/usr/lib/libSystem.B.dylib", False),
        ("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", False),
        ("@loader_path/libonnxruntime.1.22.0.dylib", False),
        ("@executable_path/libheif.1.dylib", False),
        ("@rpath/libonnxruntime.1.22.0.dylib", True),
        ("/tmp/xberg-heif/lib/libheif.1.dylib", True),
        ("/opt/homebrew/lib/libde265.0.dylib", True),
        ("libjustaname.dylib", False),
    ],
)
def test_should_classify_macho_dep_vendorability_by_load_command_form(dep, expected):
    assert build_mod._is_vendorable(dep) is expected


def test_should_exclude_header_and_own_id_when_listing_macho_deps(monkeypatch, tmp_path):
    binary = tmp_path / "libxberg_ffi.dylib"
    listing = (
        f"{binary}:\n"
        "\t@rpath/libxberg_ffi.dylib (compatibility version 0.0.0, current version 0.0.0)\n"
        "\t@rpath/libonnxruntime.1.22.0.dylib (compatibility version 0.0.0, current version 1.22.0)\n"
        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)\n"
    )
    identity = f"{binary}:\n@rpath/libxberg_ffi.dylib\n"
    runner = _FakeRunner({"otool": lambda cmd: _completed(identity if cmd[1] == "-D" else listing)})
    monkeypatch.setattr(build_mod.subprocess, "run", runner)

    assert build_mod._macho_deps(binary) == [
        "@rpath/libonnxruntime.1.22.0.dylib",
        "/usr/lib/libSystem.B.dylib",
    ]


def test_should_report_no_macho_deps_when_otool_is_not_installed(monkeypatch, tmp_path):
    def missing_tool(cmd, **kwargs):
        raise FileNotFoundError(cmd[0])

    monkeypatch.setattr(build_mod.subprocess, "run", missing_tool)

    assert build_mod._macho_deps(tmp_path / "libxberg_ffi.dylib") == []


def test_should_report_no_macho_deps_when_otool_exits_non_zero(monkeypatch, tmp_path):
    def failing(cmd, **kwargs):
        raise subprocess.CalledProcessError(1, cmd)

    monkeypatch.setattr(build_mod.subprocess, "run", failing)

    assert build_mod._macho_deps(tmp_path / "libxberg_ffi.dylib") == []


def test_should_resolve_absolute_dep_when_the_file_exists(tmp_path):
    dep = tmp_path / "libheif.1.dylib"
    dep.write_bytes(b"heif")

    assert build_mod._locate_dep(str(dep), "libheif.1.dylib", []) == dep.resolve()


def test_should_find_rpath_dep_by_basename_in_a_nested_search_root(tmp_path):
    nested = tmp_path / "ort" / "onnxruntime" / "lib"
    nested.mkdir(parents=True)
    dep = nested / "libonnxruntime.1.22.0.dylib"
    dep.write_bytes(b"ort")

    located = build_mod._locate_dep(
        "@rpath/libonnxruntime.1.22.0.dylib",
        "libonnxruntime.1.22.0.dylib",
        [tmp_path / "ort"],
    )

    assert located == dep.resolve()


def test_should_return_none_when_dep_is_absent_from_every_search_root(tmp_path):
    assert build_mod._locate_dep("@rpath/libmissing.dylib", "libmissing.dylib", [tmp_path / "nope", tmp_path]) is None


def test_should_copy_dep_beside_the_staged_library_when_located(tmp_path):
    source_root = tmp_path / "ort"
    source_root.mkdir()
    (source_root / "libonnxruntime.1.22.0.dylib").write_bytes(b"ort-bytes")
    staging = tmp_path / "native"
    staging.mkdir()

    dest = build_mod._stage_macos_dep(
        "@rpath/libonnxruntime.1.22.0.dylib",
        "libonnxruntime.1.22.0.dylib",
        staging,
        [source_root],
        "libxberg_ffi.dylib",
    )

    assert dest == staging / "libonnxruntime.1.22.0.dylib"
    assert dest.read_bytes() == b"ort-bytes"


def test_should_keep_the_existing_copy_when_dep_is_already_staged(tmp_path):
    source_root = tmp_path / "ort"
    source_root.mkdir()
    (source_root / "libheif.1.dylib").write_bytes(b"fresh")
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libheif.1.dylib").write_bytes(b"already-there")

    dest = build_mod._stage_macos_dep("@rpath/libheif.1.dylib", "libheif.1.dylib", staging, [source_root], "lib.dylib")

    assert dest.read_bytes() == b"already-there"


def test_should_exit_one_when_a_macos_dep_cannot_be_located(tmp_path, capsys):
    staging = tmp_path / "native"
    staging.mkdir()

    with pytest.raises(SystemExit) as exc_info:
        build_mod._stage_macos_dep("@rpath/libghost.dylib", "libghost.dylib", staging, [], "libxberg_ffi.dylib")

    assert exc_info.value.code == 1
    assert "could not locate runtime dep @rpath/libghost.dylib for libxberg_ffi.dylib" in capsys.readouterr().err


@pytest.mark.parametrize("prefix", ["/opt/homebrew/lib", "/usr/local/lib"])
def test_should_refuse_to_vendor_a_dylib_from_a_package_manager_prefix(monkeypatch, tmp_path, capsys, prefix):
    """Homebrew dylibs are built for the host OS floor; vendoring one silently raises it."""
    staging = tmp_path / "native"
    staging.mkdir()
    monkeypatch.setattr(build_mod, "_locate_dep", lambda dep, basename, roots: Path(prefix) / basename)

    with pytest.raises(SystemExit) as exc_info:
        build_mod._stage_macos_dep("@rpath/libde265.0.dylib", "libde265.0.dylib", staging, [], "libxberg_ffi.dylib")

    assert exc_info.value.code == 1
    assert "refusing to vendor Homebrew dylib" in capsys.readouterr().err
    assert list(staging.iterdir()) == []


def test_should_search_ort_lib_location_first_when_it_is_exported(hermetic_env, tmp_path):
    home = tmp_path / "home"
    hermetic_env.setattr(build_mod.Path, "home", classmethod(lambda cls: home))
    hermetic_env.setenv("ORT_LIB_LOCATION", "/exported/ort/lib")
    hermetic_env.setenv("XDG_CACHE_HOME", "/xdg/cache")

    assert build_mod._macos_search_roots() == [
        Path("/exported/ort/lib"),
        Path("/tmp/xberg-heif/lib"),
        Path("/xdg/cache/ort.pyke.io/dfbin"),
        home / ".cache" / "ort.pyke.io" / "dfbin",
        home / "Library" / "Caches" / "ort.pyke.io" / "dfbin",
    ]


def test_should_omit_env_derived_search_roots_when_their_variables_are_unset(hermetic_env, tmp_path):
    home = tmp_path / "home"
    hermetic_env.setattr(build_mod.Path, "home", classmethod(lambda cls: home))

    assert build_mod._macos_search_roots() == [
        Path("/tmp/xberg-heif/lib"),
        home / ".cache" / "ort.pyke.io" / "dfbin",
        home / "Library" / "Caches" / "ort.pyke.io" / "dfbin",
    ]


def test_should_skip_macos_vendoring_when_the_staged_library_is_not_a_dylib(monkeypatch, tmp_path):
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: None)
    runner = _FakeRunner()
    monkeypatch.setattr(build_mod.subprocess, "run", runner)
    staged = tmp_path / "libxberg_ffi.so"
    staged.write_bytes(b"elf")

    build_mod.copy_macos_runtime_deps(staged, tmp_path)

    assert runner.calls == []


def test_should_warn_and_skip_macos_vendoring_when_otool_is_unavailable(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: None)
    runner = _FakeRunner()
    monkeypatch.setattr(build_mod.subprocess, "run", runner)
    staged = tmp_path / "libxberg_ffi.dylib"
    staged.write_bytes(b"macho")

    build_mod.copy_macos_runtime_deps(staged, tmp_path)

    assert runner.calls == []
    assert "otool/install_name_tool unavailable" in capsys.readouterr().err


def _macho_toolchain(monkeypatch, deps_by_path: dict[str, list[str]]) -> _FakeRunner:
    """Install otool/install_name_tool/codesign doubles backed by a mutable dep table."""
    identities: dict[str, str] = {}

    def otool(cmd):
        path = cmd[2]
        if cmd[1] == "-D":
            return _completed(f"{path}:\n{identities.get(path, '')}\n")
        body = "".join(
            f"\t{dep} (compatibility version 0.0.0, current version 0.0.0)\n" for dep in deps_by_path.get(path, [])
        )
        return _completed(f"{path}:\n{body}")

    def install_name_tool(cmd):
        if cmd[1] == "-change":
            old, new, path = cmd[2], cmd[3], cmd[4]
            deps_by_path[path] = [new if dep == old else dep for dep in deps_by_path.get(path, [])]
        elif cmd[1] == "-id":
            identities[cmd[3]] = cmd[2]
        return _completed()

    runner = _FakeRunner({"otool": otool, "install_name_tool": install_name_tool})
    monkeypatch.setattr(build_mod.subprocess, "run", runner)
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: f"/usr/bin/{tool}")
    return runner


def test_should_vendor_rpath_dep_and_rewrite_it_to_loader_path_when_vendoring_macos(hermetic_env, tmp_path):
    ort = tmp_path / "ort"
    ort.mkdir()
    (ort / "libonnxruntime.1.22.0.dylib").write_bytes(b"ort-bytes")
    hermetic_env.setenv("ORT_LIB_LOCATION", str(ort))
    hermetic_env.setattr(build_mod.Path, "home", classmethod(lambda cls: tmp_path / "home"))
    staging = tmp_path / "native"
    staging.mkdir()
    staged = staging / "libxberg_ffi.dylib"
    staged.write_bytes(b"macho")
    runner = _macho_toolchain(
        hermetic_env,
        {str(staged): ["@rpath/libonnxruntime.1.22.0.dylib", "/usr/lib/libSystem.B.dylib"]},
    )

    build_mod.copy_macos_runtime_deps(staged, staging)

    assert (staging / "libonnxruntime.1.22.0.dylib").read_bytes() == b"ort-bytes"
    assert runner.argv_for("install_name_tool")[0] == [
        "install_name_tool",
        "-change",
        "@rpath/libonnxruntime.1.22.0.dylib",
        "@loader_path/libonnxruntime.1.22.0.dylib",
        str(staged),
    ]


def test_should_rewrite_a_vendored_dylib_id_to_loader_path_when_vendoring_macos(hermetic_env, tmp_path):
    ort = tmp_path / "ort"
    ort.mkdir()
    (ort / "libonnxruntime.1.22.0.dylib").write_bytes(b"ort-bytes")
    hermetic_env.setenv("ORT_LIB_LOCATION", str(ort))
    hermetic_env.setattr(build_mod.Path, "home", classmethod(lambda cls: tmp_path / "home"))
    staging = tmp_path / "native"
    staging.mkdir()
    staged = staging / "libxberg_ffi.dylib"
    staged.write_bytes(b"macho")
    runner = _macho_toolchain(hermetic_env, {str(staged): ["@rpath/libonnxruntime.1.22.0.dylib"]})

    build_mod.copy_macos_runtime_deps(staged, staging)

    assert [
        "install_name_tool",
        "-id",
        "@loader_path/libonnxruntime.1.22.0.dylib",
        str(staging / "libonnxruntime.1.22.0.dylib"),
    ] in runner.argv_for("install_name_tool")


def test_should_resign_every_rewritten_binary_when_vendoring_macos(hermetic_env, tmp_path):
    ort = tmp_path / "ort"
    ort.mkdir()
    (ort / "libonnxruntime.1.22.0.dylib").write_bytes(b"ort-bytes")
    hermetic_env.setenv("ORT_LIB_LOCATION", str(ort))
    hermetic_env.setattr(build_mod.Path, "home", classmethod(lambda cls: tmp_path / "home"))
    staging = tmp_path / "native"
    staging.mkdir()
    staged = staging / "libxberg_ffi.dylib"
    staged.write_bytes(b"macho")
    runner = _macho_toolchain(hermetic_env, {str(staged): ["@rpath/libonnxruntime.1.22.0.dylib"]})

    build_mod.copy_macos_runtime_deps(staged, staging)

    signed = [cmd[-1] for cmd in runner.argv_for("codesign") if cmd[1] == "-f"]
    assert sorted(signed) == sorted([str(staged), str(staging / "libonnxruntime.1.22.0.dylib")])


def test_should_exit_one_when_the_closure_still_references_an_unvendored_dep(monkeypatch, tmp_path, capsys):
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libxberg_ffi.dylib").write_bytes(b"macho")
    monkeypatch.setattr(build_mod, "_macho_deps", lambda binary: ["@rpath/libonnxruntime.1.22.0.dylib"])

    with pytest.raises(SystemExit) as exc_info:
        build_mod._assert_no_unvendored_deps(staging)

    assert exc_info.value.code == 1
    assert "unvendored dep libxberg_ffi.dylib -> @rpath/libonnxruntime.1.22.0.dylib" in capsys.readouterr().err


def test_should_accept_the_closure_when_only_system_libraries_remain(monkeypatch, tmp_path):
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libxberg_ffi.dylib").write_bytes(b"macho")
    monkeypatch.setattr(
        build_mod,
        "_macho_deps",
        lambda binary: ["/usr/lib/libSystem.B.dylib", "@loader_path/libonnxruntime.1.22.0.dylib"],
    )

    assert build_mod._assert_no_unvendored_deps(staging) is None


@pytest.mark.parametrize(
    ("basename", "expected"),
    [
        ("libc.so.6", True),
        ("ld-linux-x86-64.so.2", True),
        ("ld-musl-x86_64.so.1", True),
        ("libstdc++.so.6", True),
        ("libgcc_s.so.1", True),
        ("libssl.so.3", True),
        ("libcrypto.so.3", True),
        ("libonnxruntime.so.1.22.0", False),
        ("libheif.so.1", False),
        ("libwebp.so.7", False),
    ],
)
def test_should_classify_base_linux_libraries_as_never_vendorable(basename, expected):
    assert build_mod._is_base_linux_lib(basename) is expected


def test_should_collect_resolved_and_missing_deps_when_parsing_ldd_output(monkeypatch, tmp_path):
    listing = (
        "\tlinux-vdso.so.1 (0x00007ffd2f9f0000)\n"
        "\tlibonnxruntime.so.1.22.0 => /opt/ort/lib/libonnxruntime.so.1.22.0 (0x00007f4a00000000)\n"
        "\tlibheif.so.1 => not found\n"
        "\t/lib64/ld-linux-x86-64.so.2 (0x00007f4a01000000)\n"
    )
    monkeypatch.setattr(build_mod.subprocess, "run", _FakeRunner({"ldd": lambda cmd: _completed(listing)}))

    assert build_mod._ldd_deps(tmp_path / "libxberg_ffi.so") == [
        "/opt/ort/lib/libonnxruntime.so.1.22.0",
        "libheif.so.1",
        "/lib64/ld-linux-x86-64.so.2",
    ]


def test_should_report_no_deps_when_ldd_produces_no_output(monkeypatch, tmp_path):
    monkeypatch.setattr(build_mod.subprocess, "run", _FakeRunner({"ldd": lambda cmd: _completed("")}))

    assert build_mod._ldd_deps(tmp_path / "libxberg_ffi.so") == []


def test_should_skip_linux_vendoring_when_the_library_is_not_an_so(monkeypatch, tmp_path):
    """The suffix check must precede the tooling check, or macOS runners would fail here."""
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: None)
    runner = _FakeRunner()
    monkeypatch.setattr(build_mod.subprocess, "run", runner)

    build_mod.copy_linux_runtime_deps(tmp_path / "libxberg_ffi.dylib", tmp_path)

    assert runner.calls == []


@pytest.mark.parametrize(("missing", "purpose"), [("patchelf", "set RUNPATH"), ("ldd", "resolve runtime deps")])
def test_should_exit_one_when_required_linux_tooling_is_unavailable(monkeypatch, tmp_path, capsys, missing, purpose):
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: None if tool == missing else f"/usr/bin/{tool}")
    source = tmp_path / "libxberg_ffi.so"
    source.write_bytes(b"elf")

    with pytest.raises(SystemExit) as exc_info:
        build_mod.copy_linux_runtime_deps(source, tmp_path)

    assert exc_info.value.code == 1
    assert f"error: {missing} unavailable; cannot {purpose}" in capsys.readouterr().err


def _linux_toolchain(monkeypatch, deps_by_path: dict[str, list[str]], patchelf_returncode: int = 0) -> _FakeRunner:
    def ldd(cmd):
        body = "".join(f"\tsoname => {dep} (0x00007f0000000000)\n" for dep in deps_by_path.get(cmd[1], []))
        return _completed(body)

    def patchelf(cmd):
        return _completed(returncode=patchelf_returncode, stderr="patchelf: cannot find section")

    runner = _FakeRunner({"ldd": ldd, "patchelf": patchelf})
    monkeypatch.setattr(build_mod.subprocess, "run", runner)
    monkeypatch.setattr(build_mod.shutil, "which", lambda tool: f"/usr/bin/{tool}")
    return runner


def test_should_stage_only_vendorable_linux_deps_and_set_origin_runpath(monkeypatch, tmp_path):
    release = tmp_path / "release"
    release.mkdir()
    source = release / "libxberg_ffi.so"
    source.write_bytes(b"elf")
    ort = tmp_path / "ort"
    ort.mkdir()
    onnx = ort / "libonnxruntime.so.1.22.0"
    onnx.write_bytes(b"ort-bytes")
    libc = ort / "libc.so.6"
    libc.write_bytes(b"libc")
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libxberg_ffi.so").write_bytes(b"elf")
    runner = _linux_toolchain(monkeypatch, {str(source): [str(onnx), str(libc)]})

    build_mod.copy_linux_runtime_deps(source, staging)

    assert sorted(path.name for path in staging.iterdir()) == ["libonnxruntime.so.1.22.0", "libxberg_ffi.so"]
    assert (staging / "libonnxruntime.so.1.22.0").read_bytes() == b"ort-bytes"
    assert runner.argv_for("patchelf") == [["patchelf", "--set-rpath", "$ORIGIN", str(staging / "libxberg_ffi.so")]]


def test_should_walk_the_transitive_closure_when_staging_linux_deps(monkeypatch, tmp_path):
    release = tmp_path / "release"
    release.mkdir()
    source = release / "libxberg_ffi.so"
    source.write_bytes(b"elf")
    lib_root = tmp_path / "lib"
    lib_root.mkdir()
    heif = lib_root / "libheif.so.1"
    heif.write_bytes(b"heif")
    de265 = lib_root / "libde265.so.0"
    de265.write_bytes(b"de265")
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libxberg_ffi.so").write_bytes(b"elf")
    _linux_toolchain(monkeypatch, {str(source): [str(heif)], str(heif): [str(de265)]})

    build_mod.copy_linux_runtime_deps(source, staging)

    assert sorted(path.name for path in staging.iterdir()) == [
        "libde265.so.0",
        "libheif.so.1",
        "libxberg_ffi.so",
    ]


def test_should_exit_one_when_a_linux_runtime_dep_cannot_be_resolved(monkeypatch, tmp_path, capsys):
    source = tmp_path / "libxberg_ffi.so"
    source.write_bytes(b"elf")
    staging = tmp_path / "native"
    staging.mkdir()
    _linux_toolchain(monkeypatch, {str(source): ["/gone/libonnxruntime.so.1.22.0"]})

    with pytest.raises(SystemExit) as exc_info:
        build_mod.copy_linux_runtime_deps(source, staging)

    assert exc_info.value.code == 1
    assert "could not resolve runtime dep '/gone/libonnxruntime.so.1.22.0'" in capsys.readouterr().err


def test_should_exit_one_when_patchelf_fails_to_set_the_runpath(monkeypatch, tmp_path, capsys):
    source = tmp_path / "libxberg_ffi.so"
    source.write_bytes(b"elf")
    staging = tmp_path / "native"
    staging.mkdir()
    (staging / "libxberg_ffi.so").write_bytes(b"elf")
    _linux_toolchain(monkeypatch, {str(source): []}, patchelf_returncode=1)

    with pytest.raises(SystemExit) as exc_info:
        build_mod.copy_linux_runtime_deps(source, staging)

    assert exc_info.value.code == 1
    assert "patchelf --set-rpath failed: patchelf: cannot find section" in capsys.readouterr().err


def test_should_skip_windows_vendoring_when_the_staged_library_is_not_a_dll(hermetic_env, tmp_path):
    staged = tmp_path / "libxberg_ffi.so"
    staged.write_bytes(b"elf")

    build_mod.copy_windows_runtime_deps(staged, tmp_path)

    assert sorted(path.name for path in tmp_path.iterdir()) == ["libxberg_ffi.so"]


def _windows_staging(tmp_path: Path) -> tuple[Path, Path]:
    staging = tmp_path / "native"
    staging.mkdir()
    staged = staging / "xberg_ffi.dll"
    staged.write_bytes(b"pe")
    return staged, staging


def test_should_prefer_ort_dylib_path_over_every_other_candidate_when_vendoring_onnxruntime(hermetic_env, tmp_path):
    staged, staging = _windows_staging(tmp_path)
    preferred = tmp_path / "preferred"
    preferred.mkdir()
    (preferred / "onnxruntime.dll").write_bytes(b"preferred")
    on_path = tmp_path / "onpath"
    on_path.mkdir()
    (on_path / "onnxruntime.dll").write_bytes(b"from-path")
    hermetic_env.setenv("ORT_DYLIB_PATH", str(preferred / "onnxruntime.dll"))
    hermetic_env.setenv("ORT_LIB_LOCATION", str(on_path))
    hermetic_env.setenv("PATH", str(on_path))

    build_mod.copy_windows_runtime_deps(staged, staging)

    assert (staging / "onnxruntime.dll").read_bytes() == b"preferred"


def test_should_fall_back_to_ort_lib_location_when_ort_dylib_path_is_unset(hermetic_env, tmp_path):
    staged, staging = _windows_staging(tmp_path)
    lib_location = tmp_path / "ortlib"
    lib_location.mkdir()
    (lib_location / "onnxruntime.dll").write_bytes(b"from-lib-location")
    hermetic_env.setenv("ORT_LIB_LOCATION", str(lib_location))

    build_mod.copy_windows_runtime_deps(staged, staging)

    assert (staging / "onnxruntime.dll").read_bytes() == b"from-lib-location"


def test_should_fall_back_to_a_path_scan_when_no_ort_variable_is_exported(hermetic_env, tmp_path):
    staged, staging = _windows_staging(tmp_path)
    empty = tmp_path / "empty"
    empty.mkdir()
    on_path = tmp_path / "onpath"
    on_path.mkdir()
    (on_path / "onnxruntime.dll").write_bytes(b"from-path")
    hermetic_env.setenv("PATH", f"{empty}{build_mod.os.pathsep}{on_path}")

    build_mod.copy_windows_runtime_deps(staged, staging)

    assert (staging / "onnxruntime.dll").read_bytes() == b"from-path"


def test_should_exit_one_when_onnxruntime_dll_is_nowhere_to_be_found(hermetic_env, tmp_path, capsys):
    staged, staging = _windows_staging(tmp_path)

    with pytest.raises(SystemExit) as exc_info:
        build_mod.copy_windows_runtime_deps(staged, staging)

    assert exc_info.value.code == 1
    assert "could not locate onnxruntime.dll to bundle beside xberg_ffi.dll" in capsys.readouterr().err


def test_should_keep_the_existing_onnxruntime_dll_when_it_is_already_staged(hermetic_env, tmp_path):
    staged, staging = _windows_staging(tmp_path)
    (staging / "onnxruntime.dll").write_bytes(b"already-there")
    lib_location = tmp_path / "ortlib"
    lib_location.mkdir()
    (lib_location / "onnxruntime.dll").write_bytes(b"fresh")
    hermetic_env.setenv("ORT_LIB_LOCATION", str(lib_location))

    build_mod.copy_windows_runtime_deps(staged, staging)

    assert (staging / "onnxruntime.dll").read_bytes() == b"already-there"


@pytest.fixture
def main_harness(hermetic_env, tmp_path):
    """Run main() in an empty cwd with the cargo build and every vendoring step stubbed out."""
    hermetic_env.chdir(tmp_path)
    calls: dict[str, list] = {"build": [], "macos": [], "linux": [], "windows": []}
    hermetic_env.setattr(build_mod, "run_cargo_build", lambda *args: calls["build"].append(args))
    hermetic_env.setattr(build_mod, "copy_macos_runtime_deps", lambda *args: calls["macos"].append(args))
    hermetic_env.setattr(build_mod, "copy_linux_runtime_deps", lambda *args: calls["linux"].append(args))
    hermetic_env.setattr(build_mod, "copy_windows_runtime_deps", lambda *args: calls["windows"].append(args))
    output_file = tmp_path / "github_output.txt"
    output_file.touch()
    hermetic_env.setenv("GITHUB_OUTPUT", str(output_file))
    return SimpleNamespace(calls=calls, output=output_file, root=tmp_path, env=hermetic_env)


def _plant_built_library(root: Path, target: str, filename: str) -> Path:
    release = root / "target" / target / "release"
    release.mkdir(parents=True)
    built = release / filename
    built.write_bytes(b"built-library")
    return built


def test_should_exit_one_when_target_input_is_missing(main_harness, capsys):
    main_harness.env.setenv("INPUT_RID", "linux-x64")

    with pytest.raises(SystemExit) as exc_info:
        build_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: INPUT_TARGET is required\n"


def test_should_exit_one_when_rid_input_is_missing(main_harness, capsys):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")

    with pytest.raises(SystemExit) as exc_info:
        build_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == "Error: INPUT_RID is required\n"


def test_should_emit_the_planned_rid_layout_without_building_when_dry_run(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    main_harness.env.setenv("INPUT_DRY_RUN", "true")

    build_mod.main()

    assert main_harness.output.read_text(encoding="utf-8") == (
        "library-path=dist/csharp-natives/runtimes/linux-x64/native/libxberg_ffi.so\n"
        "staging-dir=dist/csharp-natives/runtimes/linux-x64/native\n"
    )
    assert main_harness.calls["build"] == []


def test_should_treat_dry_run_as_false_when_the_input_is_not_the_word_true(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    main_harness.env.setenv("INPUT_DRY_RUN", "false")
    _plant_built_library(main_harness.root, "x86_64-unknown-linux-gnu", "libxberg_ffi.so")

    build_mod.main()

    assert main_harness.calls["build"] == [("xberg-ffi", "x86_64-unknown-linux-gnu", "")]


def test_should_derive_the_library_name_from_the_crate_name_when_lib_name_is_unset(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "aarch64-apple-darwin")
    main_harness.env.setenv("INPUT_RID", "osx-arm64")
    main_harness.env.setenv("INPUT_CRATE_NAME", "my-custom-ffi")
    main_harness.env.setenv("INPUT_DRY_RUN", "true")

    build_mod.main()

    assert main_harness.output.read_text(encoding="utf-8").splitlines()[0] == (
        "library-path=dist/csharp-natives/runtimes/osx-arm64/native/libmy_custom_ffi.dylib"
    )


def test_should_prefer_an_explicit_lib_name_over_the_crate_name(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-pc-windows-msvc")
    main_harness.env.setenv("INPUT_RID", "win-x64")
    main_harness.env.setenv("INPUT_CRATE_NAME", "my-custom-ffi")
    main_harness.env.setenv("INPUT_LIB_NAME", "explicit_name")
    main_harness.env.setenv("INPUT_DRY_RUN", "true")

    build_mod.main()

    assert main_harness.output.read_text(encoding="utf-8").splitlines()[0] == (
        "library-path=dist/csharp-natives/runtimes/win-x64/native/explicit_name.dll"
    )


def test_should_honour_a_custom_output_dir_when_staging(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    main_harness.env.setenv("INPUT_OUTPUT_DIR", "artifacts/natives")
    main_harness.env.setenv("INPUT_DRY_RUN", "true")

    build_mod.main()

    assert main_harness.output.read_text(encoding="utf-8").splitlines()[1] == (
        "staging-dir=artifacts/natives/runtimes/linux-x64/native"
    )


def test_should_exit_one_when_the_built_library_is_missing_from_the_release_dir(main_harness, capsys):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")

    with pytest.raises(SystemExit) as exc_info:
        build_mod.main()

    assert exc_info.value.code == 1
    assert capsys.readouterr().err == (
        "Error: built library not found at target/x86_64-unknown-linux-gnu/release/libxberg_ffi.so\n"
    )


def test_should_stage_the_built_library_and_emit_resolved_paths(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    _plant_built_library(main_harness.root, "x86_64-unknown-linux-gnu", "libxberg_ffi.so")

    build_mod.main()

    staging = main_harness.root / "dist" / "csharp-natives" / "runtimes" / "linux-x64" / "native"
    assert (staging / "libxberg_ffi.so").read_bytes() == b"built-library"
    assert main_harness.output.read_text(encoding="utf-8") == (
        f"library-path={(staging / 'libxberg_ffi.so').resolve()}\nstaging-dir={staging.resolve()}\n"
    )


def test_should_forward_the_glibc_floor_to_the_builder(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    main_harness.env.setenv("INPUT_GLIBC_VERSION", "2.28")
    _plant_built_library(main_harness.root, "x86_64-unknown-linux-gnu", "libxberg_ffi.so")

    build_mod.main()

    assert main_harness.calls["build"] == [("xberg-ffi", "x86_64-unknown-linux-gnu", "2.28")]


def test_should_pass_the_glibc_floor_through_run_cargo_build_as_a_keyword(monkeypatch):
    forwarded = {}
    monkeypatch.setattr(
        build_mod,
        "build_or_fallback",
        lambda crate, target, **kwargs: forwarded.update({"crate": crate, "target": target, **kwargs}),
    )

    build_mod.run_cargo_build("xberg-ffi", "x86_64-unknown-linux-gnu", "2.28")

    assert forwarded == {"crate": "xberg-ffi", "target": "x86_64-unknown-linux-gnu", "glibc_version": "2.28"}


@pytest.mark.parametrize(
    ("target", "rid", "filename", "expected_platform"),
    [
        ("aarch64-apple-darwin", "osx-arm64", "libxberg_ffi.dylib", "macos"),
        ("x86_64-apple-darwin", "osx-x64", "libxberg_ffi.dylib", "macos"),
        ("x86_64-unknown-linux-gnu", "linux-x64", "libxberg_ffi.so", "linux"),
        ("aarch64-unknown-linux-musl", "linux-musl-arm64", "libxberg_ffi.so", "linux"),
        ("x86_64-pc-windows-msvc", "win-x64", "xberg_ffi.dll", "windows"),
    ],
)
def test_should_dispatch_to_exactly_one_vendoring_step_per_target_family(
    main_harness, target, rid, filename, expected_platform
):
    main_harness.env.setenv("INPUT_TARGET", target)
    main_harness.env.setenv("INPUT_RID", rid)
    _plant_built_library(main_harness.root, target, filename)

    build_mod.main()

    invoked = [name for name in ("macos", "linux", "windows") if main_harness.calls[name]]
    assert invoked == [expected_platform]


def test_should_hand_linux_vendoring_the_cargo_output_not_the_staged_copy(main_harness):
    """The ELF walk must run against the build product; the staged copy is the patchelf target."""
    main_harness.env.setenv("INPUT_TARGET", "x86_64-unknown-linux-gnu")
    main_harness.env.setenv("INPUT_RID", "linux-x64")
    built = _plant_built_library(main_harness.root, "x86_64-unknown-linux-gnu", "libxberg_ffi.so")

    build_mod.main()

    staging = Path("dist/csharp-natives/runtimes/linux-x64/native")
    assert main_harness.calls["linux"] == [(Path("target/x86_64-unknown-linux-gnu/release/libxberg_ffi.so"), staging)]
    assert built.is_file()


def test_should_hand_macos_vendoring_the_staged_copy_not_the_cargo_output(main_harness):
    main_harness.env.setenv("INPUT_TARGET", "aarch64-apple-darwin")
    main_harness.env.setenv("INPUT_RID", "osx-arm64")
    _plant_built_library(main_harness.root, "aarch64-apple-darwin", "libxberg_ffi.dylib")

    build_mod.main()

    staging = Path("dist/csharp-natives/runtimes/osx-arm64/native")
    assert main_harness.calls["macos"] == [(staging / "libxberg_ffi.dylib", staging)]
