#!/usr/bin/env bats

setup() { ROOT="$BATS_TEST_TMPDIR/root"; BIN="$ROOT/bin"; mkdir -p "$BIN" "$ROOT/ws"; export PATH="$BIN:$PATH"; SCRIPT="$BATS_TEST_DIRNAME/../scripts/build-out-of-workspace.sh"; }
stub() { printf '%s\n' '#!/usr/bin/env bash' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

@test "should_return_error_when_input_path_does_not_exist" {
  run bash "$SCRIPT" absent "$ROOT/out" "$ROOT/ws"
  [ "$status" -eq 1 ]
  [ "$output" = "Error: input not found at $ROOT/ws/absent (neither file nor dir)" ]
}

@test "should_return_error_when_package_has_no_build_manifest" {
  mkdir -p "$ROOT/ws/pkg"
  run bash "$SCRIPT" pkg "$ROOT/out" "$ROOT/ws"
  [ "$status" -eq 1 ]
  [ "$output" = "Error: $ROOT/ws/pkg has neither Cargo.toml nor pyproject.toml" ]
}

@test "should_isolate_normal_package_and_run_lockfile_then_maturin" {
  mkdir -p "$ROOT/ws/pkg"
  printf '[package]\nname = "pkg"\nversion = "1"\n' >"$ROOT/ws/pkg/Cargo.toml"
  stub cargo 'printf "%s\n" "$*" >> "'"$ROOT"'/calls"'
  stub maturin 'printf "%s\n" "$*" >> "'"$ROOT"'/calls"'
  run bash "$SCRIPT" pkg "$ROOT/out" "$ROOT/ws"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Building sdist from package: pkg"* ]]
  [ "$(cat "$ROOT/calls")" = $'generate-lockfile\nsdist --out '"$ROOT"'/out' ]
}

@test "should_build_split_layout_from_isolated_workspace" {
  mkdir -p "$ROOT/ws/python" "$ROOT/ws/crates/core"
  printf '[tool.maturin]\nmanifest-path = "../crates/core/Cargo.toml"\n' >"$ROOT/ws/python/pyproject.toml"
  printf '[package]\nname = "core"\nversion = "1"\n' >"$ROOT/ws/crates/core/Cargo.toml"
  printf '[workspace]\nresolver = "2"\n' >"$ROOT/ws/Cargo.toml"
  stub cargo 'exit 0'
  stub maturin 'printf "%s\n" "$*" > "'"$ROOT"'/maturin.args"'
  run bash "$SCRIPT" python "$ROOT/out" "$ROOT/ws"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Split layout detected; isolating $ROOT/ws/python + crate into a single-member workspace"* ]]
  [ "$(cat "$ROOT/maturin.args")" = "sdist --out $ROOT/out" ]
}
