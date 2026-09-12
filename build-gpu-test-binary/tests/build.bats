#!/usr/bin/env bats

setup() { ROOT="$BATS_TEST_TMPDIR/root"; BIN="$ROOT/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH" GITHUB_OUTPUT="$ROOT/out"; SCRIPT="$BATS_TEST_DIRNAME/../scripts/build.sh"; }
stub() { printf '%s\n' '#!/usr/bin/env bash' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

@test "should_return_shell_error_when_package_is_missing" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INPUT_PACKAGE is required"* ]]
}

@test "should_return_cargo_exit_code_and_stderr_when_compilation_fails" {
  stub cargo 'echo compiler-failed >&2; exit 23'
  export INPUT_PACKAGE=crate INPUT_TEST_NAME=gpu
  run bash "$SCRIPT"
  [ "$status" -eq 23 ]
  [[ "$output" == *"cargo test --locked -p crate --test gpu --no-run --message-format=json failed (exit 23)"* ]]
  [[ "$output" == *"compiler-failed"* ]]
}

@test "should_stage_json_executable_and_pass_feature_argument" {
  touch "$ROOT/source-bin"; chmod +x "$ROOT/source-bin"
  stub cargo 'printf "{\"executable\":\"%s/source-bin\"}\n" "'"$ROOT"'"; printf "%s\n" "$*" >"'"$ROOT"'/cargo.args"'
  stub jq 'sed -n "s/.*\"executable\":\"\\([^\"]*\\)\".*/\\1/p"'
  stub readlink 'if [ "$1" = -f ]; then printf "%s\n" "$2"; fi'
  export INPUT_PACKAGE=crate INPUT_TEST_NAME=gpu INPUT_FEATURES=cuda INPUT_OUTPUT_NAME="$ROOT/staged"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = $'Test binary: '"$ROOT"$'/source-bin\nStaged: '"$ROOT"$'/staged' ]
  [ "$(cat "$ROOT/cargo.args")" = "test --locked -p crate --features cuda --test gpu --no-run --message-format=json" ]
  [ "$(cat "$GITHUB_OUTPUT")" = "binary-path=$ROOT/staged" ]
}
