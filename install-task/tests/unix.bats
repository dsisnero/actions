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

@test "unix should_normalize_pinned_version_and_install_task_with_downloaded_installer" {
	make_stub curl '#!/usr/bin/env bash' \
		'for ((i = 1; i <= $#; i++)); do' \
		'  if [ "${!i}" = "--output" ]; then next=$((i + 1)); installer="${!next}"; fi' \
		'done' \
		'printf "%s\n" "#!/bin/sh" "mkdir -p \"\$2\"" "printf \"%s\\n\" \"#!/bin/sh\" \"exit 0\" >\"\$2/task\"" "chmod +x \"\$2/task\"" >"$installer"'
	local install_dir="$TEST_ROOT/install"
	local github_path="$TEST_ROOT/github-path"
	mkdir -p "$TEST_ROOT/runner"
	: >"$github_path"

	run env PATH="$STUB_BIN:/usr/bin:/bin" GITHUB_TOKEN="test-token" RUNNER_TEMP="$TEST_ROOT/runner" GITHUB_PATH="$github_path" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" 3.51.1 "$install_dir"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Installing Task v3.51.1 (attempt 1/6)..."* ]]
	[[ "$output" == *"Task is ready at $install_dir/task"* ]]
	[ "$("$install_dir/task" --version)" = "" ]
	[ "$(cat "$github_path")" = "$install_dir" ]
}

@test "unix should_use_github_release_when_taskfile_installer_download_fails" {
	mkdir -p "$TEST_ROOT/archive"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_ROOT/archive/task"
	chmod +x "$TEST_ROOT/archive/task"
	tar -czf "$TEST_ROOT/task.tar.gz" -C "$TEST_ROOT/archive" task
	make_stub uname '#!/usr/bin/env bash' \
		'if [ "$1" = "-s" ]; then printf "%s\n" Linux; else printf "%s\n" x86_64; fi'
	make_stub curl '#!/usr/bin/env bash' \
		'if [[ "$*" == *"taskfile.dev/install.sh"* ]]; then exit 1; fi' \
		'for ((i = 1; i <= $#; i++)); do' \
		'  if [ "${!i}" = "--output" ]; then next=$((i + 1)); /bin/cp "$TASK_ARCHIVE" "${!next}"; exit 0; fi' \
		'done' \
		'exit 1'
	local install_dir="$TEST_ROOT/install"
	mkdir -p "$TEST_ROOT/runner"

	run env PATH="$STUB_BIN:/usr/bin:/bin" GITHUB_TOKEN="test-token" RUNNER_TEMP="$TEST_ROOT/runner" TASK_ARCHIVE="$TEST_ROOT/task.tar.gz" \
		GITHUB_PATH="$TEST_ROOT/github-path" /bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" v3.51.1 "$install_dir"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Attempting direct download from GitHub releases..."* ]]
	[[ "$output" == *"GitHub release download successful"* ]]
	[ -x "$install_dir/task" ]
}

@test "unix should_return_error_after_all_attempts_when_no_installer_or_supported_release_exists" {
	make_stub curl '#!/usr/bin/env bash' 'exit 1'
	make_stub uname '#!/usr/bin/env bash' 'printf "%s\n" FreeBSD'
	make_stub sleep '#!/usr/bin/env bash' 'exit 0'
	mkdir -p "$TEST_ROOT/runner"

	run env PATH="$STUB_BIN:/usr/bin:/bin" GITHUB_TOKEN="test-token" RUNNER_TEMP="$TEST_ROOT/runner" \
		GITHUB_PATH="$TEST_ROOT/github-path" /bin/bash "$BATS_TEST_DIRNAME/../scripts/unix.sh" 3.51.1 "$TEST_ROOT/install"

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unsupported OS"* ]]
	[[ "$output" == *"Error: Failed to install Task after 6 attempts"* ]]
}
