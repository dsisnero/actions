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

@test "free-disk-space should_issue_only_targeted_cleanup_commands_and_report_disk_usage" {
	make_stub sudo '#!/usr/bin/env bash' \
		'printf "sudo %s\n" "$*" >>"$COMMAND_LOG"' \
		'exit 0'
	make_stub docker '#!/usr/bin/env bash' \
		'printf "docker %s\n" "$*" >>"$COMMAND_LOG"' \
		'exit 0'
	make_stub df '#!/usr/bin/env bash' \
		'if [ "$1" = "-h" ]; then printf "%s\n" "DISK-HUMAN"; else printf "%s\n" "DISK-BYTES"; fi'
	local command_log="$TEST_ROOT/commands"
	local bash_env="$TEST_ROOT/bash-env"
	printf '%s\n' "GLOBIGNORE='*'" >"$bash_env"

	run env PATH="$STUB_BIN:/usr/bin:/bin" BASH_ENV="$bash_env" HOME="$TEST_ROOT/home" COMMAND_LOG="$command_log" \
		/bin/bash "$BATS_TEST_DIRNAME/../scripts/free-disk-space.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *$'=== Initial disk usage ===\nDISK-HUMAN'* ]]
	[[ "$output" == *$'=== Disk usage after cleanup ===\nDISK-HUMAN'* ]]
	[ "$(cat "$command_log")" = $'sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL\nsudo rm -rf /usr/local/share/boost /opt/microsoft /usr/local/.ghcup\nsudo apt-get remove --yes -o APT::AutoRemove::SuggestsImportant=false ^ghc- php.* powershell azure-cli google-cloud-sdk\nsudo apt-get autoremove --yes\nsudo apt-get clean\nsudo rm -rf /var/lib/apt/lists/*\ndocker container prune -f\ndocker network prune -f\ndocker volume prune -f\ndocker image prune -f\ndocker builder prune -af\nsudo journalctl --vacuum-size=50M\nsudo rm -rf '"$TEST_ROOT"$'/home/.cache/pip /tmp/pip-* /tmp/tmp*\nsudo rm -rf /opt/pipx_bin /opt/pipx\nsudo rm -rf '"$TEST_ROOT"$'/home/.cargo/registry/cache '"$TEST_ROOT"$'/home/.cargo/git/db' ]
}

@test "show-disk-space should_write_label_and_byte_disk_details_to_standard_error" {
	make_stub df '#!/usr/bin/env bash' \
		'if [ "$1" = "-h" ]; then printf "%s\n" "HUMAN"; else printf "%s\n" "HEADER" "BYTES"; fi'

	run env PATH="$STUB_BIN:/usr/bin:/bin" /bin/bash "$BATS_TEST_DIRNAME/../scripts/show-disk-space.sh" "Before build"

	[ "$status" -eq 0 ]
	[ "$output" = $'=== Before build ===\nHUMAN\nDisk info:\nBYTES' ]
}

@test "free-disk-space should_stop_before_cleanup_when_initial_disk_measurement_fails" {
	make_stub df '#!/usr/bin/env bash' 'exit 9'
	make_stub sudo '#!/usr/bin/env bash' 'exit 99'

	run env PATH="$STUB_BIN:/usr/bin:/bin" /bin/bash "$BATS_TEST_DIRNAME/../scripts/free-disk-space.sh"

	[ "$status" -eq 9 ]
	[ "$output" = "=== Initial disk usage ===" ]
}
