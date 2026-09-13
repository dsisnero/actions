#!/usr/bin/env bats

# ~keep Built once per file: the mirrors are read-only and identical for every test here, and
# rebuilding a few thousand symlinks per test is pure wall-clock.
setup_file() {
	SYS_ROOT="$(mktemp -d)"
	SYS_BIN="$SYS_ROOT/sysbin"
	SYS_BIN_WITHOUT_PYTHON3="$SYS_ROOT/sysbin-no-python3"
	export SYS_ROOT SYS_BIN SYS_BIN_WITHOUT_PYTHON3
	shadow_system_path_without "$SYS_BIN" curl
	shadow_system_path_without "$SYS_BIN_WITHOUT_PYTHON3" curl python3
	# ~keep The whole point of the mirrors is that these commands are missing from them, and a
	# silent leak would put the affected tests back on the host's copies without failing.
	# python3 is asserted present because install.sh parses release metadata with the real
	# interpreter -- a mirror without it would turn every metadata test into a dependency-check
	# test that still passed. Assert the preconditions instead of assuming them.
	[ ! -e "$SYS_BIN/curl" ] || {
		echo "mirror leaked curl" >&2
		return 1
	}
	[ -x "$SYS_BIN/python3" ] || {
		echo "mirror is missing python3" >&2
		return 1
	}
	[ ! -e "$SYS_BIN_WITHOUT_PYTHON3/python3" ] || {
		echo "mirror leaked python3" >&2
		return 1
	}
}

teardown_file() {
	rm -rf "$SYS_ROOT"
}

setup() {
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	INSTALL_DIR="$TEST_ROOT/install"
	GITHUB_PATH_FILE="$TEST_ROOT/github-path"
	CURL_LOG="$TEST_ROOT/curl.log"
	SCRIPT="$BATS_TEST_DIRNAME/../scripts/install.sh"
	mkdir -p "$STUB_BIN" "$INSTALL_DIR"
	: >"$GITHUB_PATH_FILE"
	: >"$CURL_LOG"
	export TEST_ROOT STUB_BIN INSTALL_DIR GITHUB_PATH_FILE CURL_LOG SCRIPT
}

teardown() {
	rm -rf "$TEST_ROOT"
}

# Mirror the host's standard command directories into a private bin, minus the commands whose
# absence is the point of the test. PATH is then exactly the stub dir plus this mirror.
#
# An allow-list was tried first and was the wrong shape. What these tests need is not "the
# script may use exactly these ten utilities" -- that guesses at an implementation detail and
# breaks the moment the script reaches for one more, which is how `tar -xzf` shelling out to
# gzip on GNU tar but not BSD tar slipped through a sibling suite. What they need is "the host
# does not supply curl", with an otherwise realistic system underneath. Naming the excluded
# command states that directly.
#
# The original `PATH="$STUB_BIN:/usr/bin:/bin"` stated nothing: `install.sh` decides whether to
# abort by probing `command -v curl`, and ubuntu-latest ships tools in /usr/bin that macOS does
# not, so the probe outcome differed per runner and the branch under test never ran -- green
# locally, red in CI. The destination is a parameter because this file needs two mirrors that
# differ only in which command is absent. ~keep
shadow_system_path_without() {
	local destination="$1"
	shift
	local excluded=" $* " directory source name
	mkdir -p "$destination"
	for directory in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
		[ -d "$directory" ] || continue
		for source in "$directory"/*; do
			[ -x "$source" ] || continue
			name="${source##*/}"
			case "$excluded" in *" $name "*) continue ;; esac
			[ -e "$destination/$name" ] || ln -s "$source" "$destination/$name"
		done
	done
}

make_stub() {
	local name="$1"
	shift
	printf '%s\n' "$@" >"$STUB_BIN/$name"
	chmod +x "$STUB_BIN/$name"
}

# Serves both curl call sites in install.sh from files chosen by the caller: METADATA_JSON is
# the release API body, ARCHIVE_FILE the source tarball. Leaving either unset makes that call
# fail the way `curl --fail` does, which is the only way to reach the download-failure
# branches. Every invocation is appended to CURL_LOG so a test can assert the URL and headers
# the script actually sent. ~keep
make_curl_stub() {
	make_stub curl '#!/usr/bin/env bash' \
		'url=""' \
		'output=""' \
		'previous=""' \
		'for argument in "$@"; do' \
		'  if [ "$previous" = "--output" ]; then output="$argument"; fi' \
		'  case "$argument" in https://*) url="$argument" ;; esac' \
		'  previous="$argument"' \
		'done' \
		'printf "%s\n" "$@" >>"${CURL_LOG:-/dev/null}"' \
		'case "$url" in' \
		'*api.github.com*)' \
		'  [ -n "${METADATA_JSON:-}" ] || exit 22' \
		'  cat "$METADATA_JSON" >"$output"' \
		'  ;;' \
		'*)' \
		'  [ -n "${ARCHIVE_FILE:-}" ] || exit 22' \
		'  cat "$ARCHIVE_FILE" >"$output"' \
		'  ;;' \
		'esac'
}

write_metadata() {
	local tag="$1"
	local tarball_url="${2:-https://api.github.com/repos/bats-core/bats-core/tarball/${tag}}"
	printf '{"tag_name":"%s","assets":[],"tarball_url":"%s"}\n' "$tag" "$tarball_url" \
		>"$TEST_ROOT/release.json"
	printf '%s\n' "$TEST_ROOT/release.json"
}

# Mirrors the layout of a real bats-core source tarball, symlinked test fixture included.
# Upstream ships ten such symlinks (test/fixtures/parallel, test/fixtures/suite), so keeping one
# here means every happy-path test also proves validate_archive admits in-tree links rather than
# banning links outright. ~keep
make_source_archive() {
	local version="$1"
	local include_bin_bats="${2:-true}"
	local root="$TEST_ROOT/src/bats-core-${version}"

	rm -rf "$TEST_ROOT/src"
	mkdir -p "$root/libexec/bats-core" "$root/test/fixtures"
	printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'Bats ${version}'" >"$root/libexec/bats-core/bats"
	chmod +x "$root/libexec/bats-core/bats"
	if [ "$include_bin_bats" = true ]; then
		mkdir -p "$root/bin"
		printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'Bats ${version}'" >"$root/bin/bats"
		chmod +x "$root/bin/bats"
	fi
	printf '%s\n' '@test "upstream" { true; }' >"$root/test/fixtures/parallel1.bats"
	ln -s parallel1.bats "$root/test/fixtures/parallel2.bats"

	tar -czf "$TEST_ROOT/source.tar.gz" -C "$TEST_ROOT/src" "bats-core-${version}"
	printf '%s\n' "$TEST_ROOT/source.tar.gz"
}

install_existing_bats() {
	local version="$1"
	mkdir -p "$INSTALL_DIR/bats-core-${version}/bin"
	printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'Bats ${version}'" \
		>"$INSTALL_DIR/bats-core-${version}/bin/bats"
	chmod +x "$INSTALL_DIR/bats-core-${version}/bin/bats"
}

@test "install should_return_error_when_requested_version_is_not_a_bats_version" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="nightly" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Invalid Bats version 'nightly'. Use 'latest' or a version such as '1.11.1' or 'v1.11.1'." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_requested_version_has_no_minor_component" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Invalid Bats version '1'. Use 'latest' or a version such as '1.11.1' or 'v1.11.1'." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_requested_version_contains_a_path_separator" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3/../../etc" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Invalid Bats version '1.2.3/../../etc'. Use 'latest' or a version such as '1.11.1' or 'v1.11.1'." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_operating_system_is_unsupported" {
	make_curl_stub
	make_stub uname '#!/usr/bin/env bash' 'printf "%s\n" FreeBSD'

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Unsupported operating system: FreeBSD. install-bats supports Linux and macOS only." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_curl_is_missing_from_path" {
	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_PATH="$GITHUB_PATH_FILE" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::install-bats requires curl, tar, and python3 on PATH." ]
}

@test "install should_return_error_when_python3_is_missing_from_path" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN_WITHOUT_PYTHON3" INPUT_VERSION="1.2.3" \
		INPUT_INSTALL_DIR="$INSTALL_DIR" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::install-bats requires curl, tar, and python3 on PATH." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_github_token_contains_a_newline" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN=$'good\nbad' GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::GITHUB_TOKEN must not contain carriage returns or newlines." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_return_error_when_github_token_contains_a_carriage_return" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN=$'good\rbad' GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::GITHUB_TOKEN must not contain carriage returns or newlines." ]
	[ ! -s "$CURL_LOG" ]
}

@test "install should_request_the_tagged_release_endpoint_with_a_bearer_token_when_version_is_pinned" {
	make_curl_stub
	install_existing_bats 1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[[ "$(cat "$CURL_LOG")" == *"https://api.github.com/repos/bats-core/bats-core/releases/tags/v1.2.3"* ]]
	[[ "$(cat "$CURL_LOG")" == *"Authorization: Bearer secret-token"* ]]
}

@test "install should_request_the_latest_release_endpoint_when_version_is_latest" {
	make_curl_stub
	install_existing_bats 1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="latest" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[[ "$(cat "$CURL_LOG")" == *"https://api.github.com/repos/bats-core/bats-core/releases/latest"* ]]
}

# ~keep Deliberately run under /bin/bash, which is 3.2 on a macOS runner: expanding an empty
# array under `set -u` aborts before 4.4, and an unset GITHUB_TOKEN -- reachable through
# `github-token: ""` -- is exactly what leaves auth_args empty.
@test "install should_omit_the_authorization_header_when_no_github_token_is_set" {
	make_curl_stub
	install_existing_bats 1.2.3

	run env -u GITHUB_TOKEN PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" \
		INPUT_INSTALL_DIR="$INSTALL_DIR" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$(grep -c 'Authorization' "$CURL_LOG")" -eq 0 ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$INSTALL_DIR/bats-core-1.2.3/bin" ]
}

# ~keep `"$bats_bin" --version` failing is a `set -e` abort, not a call to error(), so nothing
# chooses the exit status explicitly -- this is the one path where the status comes from the
# failing command itself and has to survive the EXIT cleanup trap.
@test "install should_exit_non_zero_when_set_e_aborts_before_the_cleanup_trap" {
	make_curl_stub
	mkdir -p "$INSTALL_DIR/bats-core-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 3' >"$INSTALL_DIR/bats-core-1.2.3/bin/bats"
	chmod +x "$INSTALL_DIR/bats-core-1.2.3/bin/bats"

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 3 ]
	[ ! -s "$GITHUB_PATH_FILE" ]
}

@test "install should_return_error_when_release_metadata_request_fails" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Could not retrieve Bats release metadata from GitHub." ]
}

@test "install should_return_error_when_release_metadata_has_no_tag_name" {
	make_curl_stub
	printf '%s\n' '{"assets":[]}' >"$TEST_ROOT/release.json"

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="latest" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$TEST_ROOT/release.json" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::GitHub returned an invalid Bats release tag." ]
}

@test "install should_return_error_when_release_tag_is_not_a_version" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="latest" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata nightly)" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::GitHub returned an invalid Bats release tag." ]
}

@test "install should_return_error_when_github_resolves_a_different_tag_than_requested" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="v1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.4)" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::GitHub returned v1.2.4, not the requested Bats release v1.2.3." ]
}

@test "install should_return_error_when_tarball_url_is_not_the_official_repository" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3 https://api.github.com/repos/attacker/bats-core/tarball/v1.2.3)" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Bats release v1.2.3 has invalid source archive metadata." ]
}

@test "install should_return_error_when_release_metadata_has_no_assets_list" {
	make_curl_stub
	printf '%s\n' \
		'{"tag_name":"v1.2.3","tarball_url":"https://api.github.com/repos/bats-core/bats-core/tarball/v1.2.3"}' \
		>"$TEST_ROOT/release.json"

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$TEST_ROOT/release.json" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Bats release v1.2.3 has invalid source archive metadata." ]
}

@test "install should_reuse_the_existing_release_without_downloading_an_archive" {
	make_curl_stub
	install_existing_bats 1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$output" = $'Using existing Bats v1.2.3 at '"$INSTALL_DIR"$'/bats-core-1.2.3/bin/bats\nBats 1.2.3' ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$INSTALL_DIR/bats-core-1.2.3/bin" ]
	[ "$(grep -c 'archive/refs/tags' "$CURL_LOG")" -eq 0 ]
}

@test "install should_download_extract_and_publish_the_release_bin_directory_to_github_path" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$(make_source_archive 1.2.3)" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$output" = "Bats 1.2.3" ]
	[ -x "$INSTALL_DIR/bats-core-1.2.3/bin/bats" ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$INSTALL_DIR/bats-core-1.2.3/bin" ]
	[[ "$(cat "$CURL_LOG")" == *"https://github.com/bats-core/bats-core/archive/refs/tags/v1.2.3.tar.gz"* ]]
}

@test "install should_install_under_runner_temp_when_no_install_dir_is_given" {
	make_curl_stub
	local runner_temp="$TEST_ROOT/runner"
	mkdir -p "$runner_temp"

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" RUNNER_TEMP="$runner_temp" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$(make_source_archive 1.2.3)" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$runner_temp/bats/bats-core-1.2.3/bin" ]
}

@test "install should_return_error_when_the_source_archive_download_fails" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Could not download the official Bats source archive for v1.2.3." ]
}

@test "install should_return_error_when_the_archive_has_an_unexpected_top_level_directory" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/evil/attacker-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/evil/attacker-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/evil/attacker-1.2.3/bin/bats"
	tar -czf "$TEST_ROOT/evil.tar.gz" -C "$TEST_ROOT/evil" attacker-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/evil.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[[ "$output" == *"::error::Downloaded Bats archive has an unexpected top-level path."* ]]
	[ ! -e "$INSTALL_DIR/bats-core-1.2.3" ]
}

@test "install should_return_error_when_the_archive_contains_a_parent_directory_traversal" {
	make_curl_stub
	python3 - "$TEST_ROOT/traversal.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    for name in ("bats-core-1.2.3/bin/bats", "bats-core-1.2.3/../escape.sh"):
        entry = tarfile.TarInfo(name)
        entry.size = 0
        entry.mode = 0o755
        archive.addfile(entry, io.BytesIO(b""))
PY

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/traversal.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[[ "$output" == *"::error::Downloaded Bats archive contains an unsafe path."* ]]
	[ ! -e "$TEST_ROOT/escape.sh" ]
	[ ! -e "$INSTALL_DIR/escape.sh" ]
}

@test "install should_return_error_when_the_archive_does_not_contain_bin_bats" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$(make_source_archive 1.2.3 false)" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Downloaded Bats archive does not contain bin/bats." ]
	[ ! -e "$INSTALL_DIR/bats-core-1.2.3" ]
}

# ~keep An archive of nothing but regular files and directories is the ordinary case and must
# install. It is asserted separately from the happy-path tests because those go through
# make_source_archive, which deliberately ships a symlink.
@test "install should_accept_a_source_archive_that_contains_no_symlinks" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/clean/bats-core-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/clean/bats-core-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/clean/bats-core-1.2.3/bin/bats"
	tar -czf "$TEST_ROOT/clean.tar.gz" -C "$TEST_ROOT/clean" bats-core-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/clean.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$INSTALL_DIR/bats-core-1.2.3/bin" ]
}

# ~keep The guard exists to stop extraction-time path traversal, not to ban symlinks: upstream
# bats-core ships ten of them under test/fixtures/, so a blanket rejection would reject every
# real release. These two cases are the line between them.
@test "install should_accept_a_source_archive_whose_symlinks_stay_inside_the_archive" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/intree/bats-core-1.2.3/bin" "$TEST_ROOT/intree/bats-core-1.2.3/test/fixtures"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/intree/bats-core-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/intree/bats-core-1.2.3/bin/bats"
	printf '%s\n' '@test "upstream" { true; }' >"$TEST_ROOT/intree/bats-core-1.2.3/test/fixtures/one.bats"
	ln -s one.bats "$TEST_ROOT/intree/bats-core-1.2.3/test/fixtures/two.bats"
	ln -s ../fixtures/one.bats "$TEST_ROOT/intree/bats-core-1.2.3/test/fixtures/three.bats"
	tar -czf "$TEST_ROOT/intree.tar.gz" -C "$TEST_ROOT/intree" bats-core-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/intree.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 0 ]
	[ "$(cat "$GITHUB_PATH_FILE")" = "$INSTALL_DIR/bats-core-1.2.3/bin" ]
}

@test "install should_return_error_when_a_symlink_target_climbs_out_of_the_archive" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/escape/bats-core-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/escape/bats-core-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/escape/bats-core-1.2.3/bin/bats"
	ln -s ../../../../etc/passwd "$TEST_ROOT/escape/bats-core-1.2.3/bin/escape"
	tar -czf "$TEST_ROOT/escape.tar.gz" -C "$TEST_ROOT/escape" bats-core-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/escape.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Downloaded Bats archive links outside itself: 'bats-core-1.2.3/bin/escape' -> '../../../../etc/passwd'." ]
	[ ! -e "$INSTALL_DIR/bats-core-1.2.3" ]
}

@test "install should_return_error_when_a_symlink_target_is_absolute" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/absolute/bats-core-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/absolute/bats-core-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/absolute/bats-core-1.2.3/bin/bats"
	ln -s /etc/passwd "$TEST_ROOT/absolute/bats-core-1.2.3/bin/escape"
	tar -czf "$TEST_ROOT/absolute.tar.gz" -C "$TEST_ROOT/absolute" bats-core-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/absolute.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Downloaded Bats archive links outside itself: 'bats-core-1.2.3/bin/escape' -> '/etc/passwd'." ]
	[ ! -e "$INSTALL_DIR/bats-core-1.2.3" ]
}

@test "install should_return_error_when_the_archive_contains_a_special_file" {
	make_curl_stub
	mkdir -p "$TEST_ROOT/special/bats-core-1.2.3/bin"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/special/bats-core-1.2.3/bin/bats"
	chmod +x "$TEST_ROOT/special/bats-core-1.2.3/bin/bats"
	mkfifo "$TEST_ROOT/special/bats-core-1.2.3/pipe"
	tar -czf "$TEST_ROOT/special.tar.gz" -C "$TEST_ROOT/special" bats-core-1.2.3

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$TEST_ROOT/special.tar.gz" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Downloaded Bats archive contains an unsupported special-file entry: 'bats-core-1.2.3/pipe'." ]
	[ ! -e "$INSTALL_DIR/bats-core-1.2.3" ]
}

@test "install should_return_error_when_the_release_directory_exists_without_an_executable_bats" {
	make_curl_stub
	mkdir -p "$INSTALL_DIR/bats-core-1.2.3/bin"
	printf '%s\n' 'not executable' >"$INSTALL_DIR/bats-core-1.2.3/bin/bats"

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" ARCHIVE_FILE="$(make_source_archive 1.2.3)" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$output" = "::error::Installation directory already exists but does not contain an executable Bats binary: ${INSTALL_DIR}/bats-core-1.2.3." ]
	[ "$(cat "$INSTALL_DIR/bats-core-1.2.3/bin/bats")" = "not executable" ]
}

@test "install should_return_error_when_github_path_is_not_set" {
	make_curl_stub
	install_existing_bats 1.2.3

	run env -u GITHUB_PATH PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" \
		INPUT_INSTALL_DIR="$INSTALL_DIR" GITHUB_TOKEN="secret-token" CURL_LOG="$CURL_LOG" \
		METADATA_JSON="$(write_metadata v1.2.3)" /bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "${lines[2]}" = "::error::GITHUB_PATH is not set; install-bats must run in a GitHub Actions job." ]
}

@test "install should_remove_the_staging_directory_when_the_run_fails" {
	make_curl_stub

	run env PATH="$STUB_BIN:$SYS_BIN" INPUT_VERSION="1.2.3" INPUT_INSTALL_DIR="$INSTALL_DIR" \
		GITHUB_TOKEN="secret-token" GITHUB_PATH="$GITHUB_PATH_FILE" CURL_LOG="$CURL_LOG" \
		/bin/bash "$SCRIPT"

	[ "$status" -eq 1 ]
	[ "$(find "$INSTALL_DIR" -maxdepth 1 -name '.install-bats-*' | wc -l | tr -d ' ')" = "0" ]
}
