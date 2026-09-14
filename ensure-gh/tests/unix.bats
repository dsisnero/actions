#!/usr/bin/env bats
#
# The stubs sit ahead of a mirror of the host's system bins with `gh` removed, rather than ahead
# of a hand-picked "$STUB_BIN:/usr/bin:/bin". unix.sh decides whether to download by probing
# `command -v gh`; ubuntu-latest ships gh in /usr/bin and macOS does not, so a PATH that does not
# state the absence let the probe succeed on CI and take the already-installed branch instead of
# the one under test -- green locally, red in CI. ~keep

setup_file() {
	bats_load_library xberg-bats
	# Built once per file: the mirror is read-only and identical for every test here, and
	# rebuilding a few thousand symlinks per test is pure wall-clock. ~keep
	xberg_shadow_system_path_without gh
}

setup() {
	bats_load_library xberg-bats
	xberg_setup_isolated
	export HOME="$XBERG_WORK/home"
}

@test "unix should_exit_without_download_when_gh_is_already_available" {
	xberg_stub gh 'printf "%s\n" "gh version 2.50.0"'
	xberg_stub_curl_offline

	run env PATH="$(xberg_isolated_path)" HOME="$HOME" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" latest

	xberg_assert_status 0
	xberg_assert_output "gh already installed: $XBERG_STUB_BIN/gh (gh version 2.50.0)"
	xberg_assert_file_absent "$HOME/.local/bin/gh"
}

@test "unix should_install_requested_linux_release_and_add_bin_directory_to_github_path" {
	# A genuine tarball, so the script's own `tar` handling is exercised rather than mocked --
	# that is how a GNU-tar-shells-out-to-gzip class of bug gets caught.
	local archive_root="$XBERG_WORK/archive/gh_2.50.0_linux_amd64/bin"
	mkdir -p "$archive_root"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$archive_root/gh"
	chmod +x "$archive_root/gh"
	tar -czf "$XBERG_WORK/gh.tar.gz" -C "$XBERG_WORK/archive" gh_2.50.0_linux_amd64

	xberg_stub uname 'if [ "$1" = "-s" ]; then printf "%s\n" Linux; else printf "%s\n" x86_64; fi'
	xberg_stub_curl_file "$XBERG_WORK/gh.tar.gz"

	run env PATH="$(xberg_isolated_path)" HOME="$HOME" \
		XBERG_CURL_FILE="$XBERG_CURL_FILE" GITHUB_PATH="$GITHUB_PATH" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" v2.50.0

	xberg_assert_status 0
	xberg_assert_lines \
		"Downloading gh v2.50.0 (linux_amd64)..." \
		"gh v2.50.0 installed at $HOME/.local/bin/gh"
	[ -x "$HOME/.local/bin/gh" ]
	xberg_assert_github_path "$HOME/.local/bin"
}

@test "unix should_return_error_without_download_for_unsupported_operating_system" {
	xberg_stub uname 'printf "%s\n" FreeBSD'
	xberg_stub_curl_offline

	run env PATH="$(xberg_isolated_path)" HOME="$HOME" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" 2.50.0

	xberg_assert_status 1
	xberg_assert_output "Error: unsupported OS: FreeBSD"
}

# ~keep `auth_args` is empty whenever GITHUB_TOKEN is unset, and a bare `"${auth_args[@]}"` on
# an empty array is an unbound-variable error under `set -u` before bash 4.4 -- /bin/bash on
# every macOS runner. Running the script under /bin/bash rather than the PATH bash is what makes
# this test able to fail at all: bats itself runs under whatever newer bash is first on PATH,
# where the bug does not reproduce.
@test "unix should_resolve_the_latest_tag_without_an_authorization_header_when_no_token_is_set" {
	make_stub uname '#!/usr/bin/env bash' \
		'if [ "$1" = "-s" ]; then printf "%s\n" Linux; else printf "%s\n" x86_64; fi'
	make_stub curl '#!/usr/bin/env bash' \
		'printf "%s\n" "$@" >>"$CURL_ARGV"' \
		'if [ "$1" = "--silent" ] && [ "$2" = "--fail" ]; then printf "%s\n" "  \"tag_name\": \"v2.50.0\","; exit 0; fi' \
		'exit 99'

	# `env -u NAME` is the portable spelling; GNU's `--unset=NAME` long form does not exist in
	# BSD env, so it would fail on the macOS runner this test exists to protect.
	run env -u GITHUB_TOKEN \
		PATH="$STUB_BIN:$SYS_BIN" HOME="$TEST_ROOT/home" CURL_ARGV="$TEST_ROOT/curl-argv" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" latest

	[ "$status" -ne 0 ] || true
	# The resolve step must have run and produced no Authorization header.
	[ -s "$TEST_ROOT/curl-argv" ]
	! grep -q "Authorization" "$TEST_ROOT/curl-argv"
	! printf '%s' "$output" | grep -q "unbound variable"
	! printf '%s' "$output" | grep -q "could not resolve latest gh release"
}
