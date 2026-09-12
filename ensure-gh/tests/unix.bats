#!/usr/bin/env bats

setup() {
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	mkdir -p "$STUB_BIN"
	export TEST_ROOT STUB_BIN
}

teardown() {
	rm -rf "$TEST_ROOT"
}

make_stub() {
	local name="$1"
	shift
	printf '%s\n' "$@" >"$STUB_BIN/$name"
	chmod +x "$STUB_BIN/$name"
}

@test "unix should_exit_without_download_when_gh_is_already_available" {
	make_stub gh '#!/usr/bin/env bash' 'printf "%s\n" "gh version 2.50.0"'
	make_stub curl '#!/usr/bin/env bash' 'exit 99'

	run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$TEST_ROOT/home" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" latest

	[ "$status" -eq 0 ]
	[ "$output" = "gh already installed: $STUB_BIN/gh (gh version 2.50.0)" ]
	[ ! -e "$TEST_ROOT/home/.local/bin/gh" ]
}

@test "unix should_install_requested_linux_release_and_add_bin_directory_to_github_path" {
	local archive_root="$TEST_ROOT/archive/gh_2.50.0_linux_amd64/bin"
	mkdir -p "$archive_root"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$archive_root/gh"
	chmod +x "$archive_root/gh"
	tar -czf "$TEST_ROOT/gh.tar.gz" -C "$TEST_ROOT/archive" gh_2.50.0_linux_amd64
	make_stub uname '#!/usr/bin/env bash' \
		'if [ "$1" = "-s" ]; then printf "%s\n" Linux; else printf "%s\n" x86_64; fi'
	make_stub curl '#!/usr/bin/env bash' \
		'for ((i = 1; i <= $#; i++)); do' \
		'  if [ "${!i}" = "--output" ]; then next=$((i + 1)); /bin/cp "$GH_ARCHIVE" "${!next}"; exit 0; fi' \
		'done' \
		'exit 1'
	local home_dir="$TEST_ROOT/home"
	local github_path="$TEST_ROOT/github-path"
	: >"$github_path"

	run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$home_dir" GH_ARCHIVE="$TEST_ROOT/gh.tar.gz" GITHUB_PATH="$github_path" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" v2.50.0

	[ "$status" -eq 0 ]
	[ "$output" = $'Downloading gh v2.50.0 (linux_amd64)...\ngh v2.50.0 installed at '"$home_dir"$'/.local/bin/gh' ]
	[ -x "$home_dir/.local/bin/gh" ]
	[ "$(cat "$github_path")" = "$home_dir/.local/bin" ]
}

@test "unix should_return_error_without_download_for_unsupported_operating_system" {
	make_stub uname '#!/usr/bin/env bash' 'printf "%s\n" FreeBSD'
	make_stub curl '#!/usr/bin/env bash' 'exit 99'

	run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$TEST_ROOT/home" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" 2.50.0

	[ "$status" -eq 1 ]
	[ "$output" = "Error: unsupported OS: FreeBSD" ]
}
