#!/usr/bin/env bats

# ~keep Built once per file: the mirror is read-only and identical for every test here, and
# rebuilding a few thousand symlinks per test is pure wall-clock.
setup_file() {
	SYS_BIN="$(mktemp -d)/sysbin"
	mkdir -p "$SYS_BIN"
	export SYS_BIN
	shadow_system_path_without gh
	# ~keep The whole point of the mirror is that this command is missing from it, and a
	# silent leak would put every test in this file back on the host's copy without
	# failing. Assert the precondition instead of assuming it.
	[ ! -e "$SYS_BIN/gh" ] || { echo "mirror leaked gh" >&2; return 1; }
}

teardown_file() {
	rm -rf "$(dirname "$SYS_BIN")"
}

setup() {
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	mkdir -p "$STUB_BIN"
	export TEST_ROOT STUB_BIN
}

# Mirror the host's standard command directories into a private bin, minus the commands whose
# absence is the point of the test. PATH is then exactly the stub dir plus this mirror.
#
# An allow-list was tried first and was the wrong shape. What these tests need is not "the
# script may use exactly these ten utilities" -- that guesses at an implementation detail and
# breaks the moment the script reaches for one more, which is how `tar -xzf` shelling out to
# gzip on GNU tar slipped through. What they need is "the host does not supply gh", with an
# otherwise realistic system underneath. Naming the excluded command states that directly.
#
# The original `PATH="$STUB_BIN:/usr/bin:/bin"` stated nothing: `unix.sh` decides whether to
# download by probing `command -v gh`, ubuntu-latest ships gh in /usr/bin and macOS does not,
# so the probe succeeded on CI and the script took the already-installed branch instead of the
# one under test -- green locally, red in CI. ~keep
shadow_system_path_without() {
	local excluded=" $* " directory source name
	for directory in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
		[ -d "$directory" ] || continue
		for source in "$directory"/*; do
			[ -x "$source" ] || continue
			name="${source##*/}"
			case "$excluded" in *" $name "*) continue ;; esac
			[ -e "$SYS_BIN/$name" ] || ln -s "$source" "$SYS_BIN/$name"
		done
	done
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

	run env PATH="$STUB_BIN:$SYS_BIN" HOME="$TEST_ROOT/home" \
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

	run env PATH="$STUB_BIN:$SYS_BIN" HOME="$home_dir" GH_ARCHIVE="$TEST_ROOT/gh.tar.gz" GITHUB_PATH="$github_path" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" v2.50.0

	[ "$status" -eq 0 ]
	[ "$output" = $'Downloading gh v2.50.0 (linux_amd64)...\ngh v2.50.0 installed at '"$home_dir"$'/.local/bin/gh' ]
	[ -x "$home_dir/.local/bin/gh" ]
	[ "$(cat "$github_path")" = "$home_dir/.local/bin" ]
}

@test "unix should_return_error_without_download_for_unsupported_operating_system" {
	make_stub uname '#!/usr/bin/env bash' 'printf "%s\n" FreeBSD'
	make_stub curl '#!/usr/bin/env bash' 'exit 99'

	run env PATH="$STUB_BIN:$SYS_BIN" HOME="$TEST_ROOT/home" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" 2.50.0

	[ "$status" -eq 1 ]
	[ "$output" = "Error: unsupported OS: FreeBSD" ]
}
