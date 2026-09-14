#!/usr/bin/env bats

setup() {
	ROOT="$BATS_TEST_TMPDIR/root"
	BIN="$ROOT/bin"
	mkdir -p "$BIN" "$ROOT/pkg" "$ROOT/target/release"
	export PATH="$BIN:$PATH" GITHUB_WORKSPACE="$ROOT" CARGO_TARGET_DIR="$ROOT/target" RUNNER_OS=Linux
	SCRIPT="$BATS_TEST_DIRNAME/../scripts/build.sh"
}
stub() {
	printf '%s\n' '#!/usr/bin/env bash' "$2" >"$BIN/$1"
	chmod +x "$BIN/$1"
}

@test "should_print_custom_profile_dry_run_and_output" {
	export INPUT_DRY_RUN=true INPUT_FFI_CRATE=my-ffi INPUT_BUILD_PROFILE=bench GITHUB_OUTPUT="$ROOT/out"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"cargo build --locked -p my-ffi --profile bench"* ]]
	[ "$(cat "$GITHUB_OUTPUT")" = "ffi-library-path=$ROOT/target/bench/libmy_ffi.so" ]
}

@test "should_return_error_when_package_directory_is_missing" {
	export INPUT_PACKAGE_DIR="$ROOT/nope"
	run bash "$SCRIPT"
	[ "$status" -eq 1 ]
	[ "$output" = "Error: package-dir '$ROOT/nope' does not exist" ]
}

@test "should_run_zig_test_when_build_file_defines_test_step" {
	printf 'const test_step = b.step("test", "test");\n' >"$ROOT/pkg/build.zig"
	touch "$ROOT/target/release/libmy_ffi.so"
	stub cargo 'exit 0'
	stub zig 'printf "%s\n" "$*" >> "'"$ROOT"'/zig.args"'
	export INPUT_PACKAGE_DIR="$ROOT/pkg" INPUT_FFI_CRATE=my-ffi GITHUB_OUTPUT="$ROOT/out"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(cat "$ROOT/zig.args")" = $'build -Dffi_path='"$ROOT"$'/target/release\nbuild test -Dffi_path='"$ROOT"$'/target/release' ]
	[ "$(cat "$GITHUB_OUTPUT")" = "ffi-library-path=$ROOT/target/release/libmy_ffi.so" ]
}
