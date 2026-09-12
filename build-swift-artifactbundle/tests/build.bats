#!/usr/bin/env bats

setup() { ROOT="$BATS_TEST_TMPDIR/root"; BIN="$ROOT/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH" GITHUB_WORKSPACE="$ROOT" CARGO_TARGET_DIR="$ROOT/target" GITHUB_OUTPUT="$ROOT/out"; SCRIPT="$BATS_TEST_DIRNAME/../scripts/build.sh"; }
stub() { printf '%s\n' '#!/usr/bin/env bash' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

@test "should_describe_optional_target_skips_during_dry_run" {
  stub sed 'input=$(cat); [ "$input" = my_crate ] && { printf "MyCrate\n"; exit 0; }; /usr/bin/sed "$@" <<<"$input"'
  export INPUT_DRY_RUN=true INPUT_CRATE_NAME=my-crate INPUT_INCLUDE_MACOS_X86_64=false INPUT_INCLUDE_IOS_X86_64=false
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip x86_64-apple-darwin (include-macos-x86_64=false)"* ]]
  [[ "$output" == *"ios-sim uses arm64 only"* ]]
  [[ "$output" == *"would assemble dist/swift-artifactbundle/MyCrate.artifactbundle"* ]]
}

@test "should_return_error_when_a_target_build_does_not_produce_its_static_library" {
  stub rustup 'exit 0'
  stub cargo 'exit 0'
  stub zig 'exit 0'
  export INPUT_CRATE_NAME=my-crate INPUT_LIB_NAME=my_lib INPUT_OUTPUT_DIR="$ROOT/dist" INPUT_INCLUDE_MACOS_X86_64=false INPUT_INCLUDE_IOS_X86_64=false
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$ROOT/target/aarch64-apple-darwin/release/libmy_lib.a"* ]]
}

@test "should_assemble_disabled_optional_variants_and_write_metadata" {
  stub rustup 'exit 0'
  stub cargo 'if [ "$1" = build ] || [ "$1" = zigbuild ]; then target="${@: -1}"; mkdir -p "$CARGO_TARGET_DIR/$target/release"; touch "$CARGO_TARGET_DIR/$target/release/libmy_lib.a"; fi'
  stub zig 'exit 0'
  stub cargo-zigbuild 'target="${@: -1}"; mkdir -p "$CARGO_TARGET_DIR/$target/release"; touch "$CARGO_TARGET_DIR/$target/release/libmy_lib.a"'
  stub df 'printf "fixture 100 1 99 1%% /tmp\n"'
  stub zip 'touch "$2"'
  stub swift 'echo checksum123'
  export INPUT_CRATE_NAME=my-crate INPUT_LIB_NAME=my_lib INPUT_ARTIFACT_NAME=Kit INPUT_BINARY_TARGET_NAME=KitTarget INPUT_OUTPUT_DIR="$ROOT/dist" INPUT_INCLUDE_MACOS_X86_64=false INPUT_INCLUDE_IOS_X86_64=false
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping x86_64-apple-darwin (include-macos-x86_64=false)"* ]]
  [ "$(grep -o 'supportedTriples' "$ROOT/dist/Kit.artifactbundle/info.json" | wc -l)" -eq 5 ]
  expected=$(printf 'bundle-path=%s/dist/Kit.artifactbundle\nbundle-zip=%s/dist/Kit.artifactbundle.zip\nchecksum=checksum123' "$ROOT" "$ROOT")
  [ "$(cat "$GITHUB_OUTPUT")" = "$expected" ]
}
