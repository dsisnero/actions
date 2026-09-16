#!/usr/bin/env bats

setup() {
	SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	export PATH="$BIN:$PATH"
	export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
	: >"$GITHUB_PATH"
}

stub() {
	printf '%s\n' '#!/usr/bin/env bash' 'set -eu' "$2" >"$BIN/$1"
	chmod +x "$BIN/$1"
}

@test "should_skip_clang_format_install_when_requested_version_is_present" {
	stub clang-format 'echo "clang-format version 18.1.8"'
	export CLANG_FORMAT_VERSION=18.1.8
	run "$SCRIPT_DIR/clang-format.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "clang-format 18.1.8 already installed." ]
	[ ! -s "$GITHUB_PATH" ]
}

@test "should_return_error_when_clang_format_version_is_empty" {
	run env -u CLANG_FORMAT_VERSION "$SCRIPT_DIR/clang-format.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "$SCRIPT_DIR/clang-format.sh: line 8: CLANG_FORMAT_VERSION: clang-format version required" ]
}

@test "should_install_only_requested_linux_tools" {
	stub sudo '"$@"'
	stub apt-get 'printf "%s\n" "$*" >>"$CALLS"'
	export CALLS="$BATS_TEST_TMPDIR/apt-calls"
	export INSTALL_CLANG_FORMAT=false INSTALL_CPPCHECK=false INSTALL_SHELLCHECK=true INSTALL_SHFMT=false
	run "$SCRIPT_DIR/linux.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(cat "$CALLS")" = $'update -qq\ninstall -y --no-install-recommends shellcheck' ]
}

@test "should_report_brew_cppcheck_version_when_requested_on_macos" {
	stub brew 'if [[ "$1" == "install" ]]; then printf "%s\n" "$*" >>"$BREW_CALLS"; fi'
	stub cppcheck 'echo "Cppcheck 2.20.0"'
	export BREW_CALLS="$BATS_TEST_TMPDIR/brew-calls"
	export INSTALL_CLANG_FORMAT=false INSTALL_CPPCHECK=true INSTALL_SHELLCHECK=false INSTALL_SHFMT=false CPPCHECK_VERSION=2.20.0
	run "$SCRIPT_DIR/macos.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "Cppcheck 2.20.0" ]
	[ "$(cat "$BREW_CALLS")" = "install cppcheck" ]
}

@test "should_skip_shfmt_install_when_requested_version_is_present" {
	stub shfmt 'echo "3.14.1"'
	export SHFMT_VERSION=3.14.1
	run "$SCRIPT_DIR/shfmt.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "shfmt 3.14.1 already installed." ]
	[ ! -s "$GITHUB_PATH" ]
}

@test "should_accept_a_v_prefixed_shfmt_version_report" {
	stub shfmt 'echo "v3.14.1"'
	export SHFMT_VERSION=3.14.1
	run "$SCRIPT_DIR/shfmt.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "shfmt 3.14.1 already installed." ]
}

@test "should_return_error_when_shfmt_version_is_empty" {
	run env -u SHFMT_VERSION "$SCRIPT_DIR/shfmt.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "$SCRIPT_DIR/shfmt.sh: line 10: SHFMT_VERSION: shfmt version required" ]
}

@test "should_install_shfmt_from_linux_script_when_requested" {
	stub shfmt 'echo "3.14.1"'
	export INSTALL_CLANG_FORMAT=false INSTALL_CPPCHECK=false INSTALL_SHELLCHECK=false
	export INSTALL_SHFMT=true SHFMT_VERSION=3.14.1
	run "$SCRIPT_DIR/linux.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "shfmt 3.14.1 already installed." ]
}

@test "should_not_install_shfmt_from_linux_script_when_disabled" {
	export INSTALL_CLANG_FORMAT=false INSTALL_CPPCHECK=false INSTALL_SHELLCHECK=false
	export INSTALL_SHFMT=false
	run "$SCRIPT_DIR/linux.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}
