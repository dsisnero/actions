#!/usr/bin/env bats

setup_file() {
	SYS_BIN="$(mktemp -d)/sysbin"
	mkdir -p "$SYS_BIN"
	export SYS_BIN
	shadow_system_path_without dotnet
	# ~keep The whole point of the mirror is that this command is missing from it, and a
	# silent leak would put every test in this file back on the host's copy without
	# failing. Assert the precondition instead of assuming it.
	[ ! -e "$SYS_BIN/dotnet" ] || { echo "mirror leaked dotnet" >&2; return 1; }
}

teardown_file() {
	rm -rf "$(dirname "$SYS_BIN")"
}

setup() {
	ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	mkdir -p "$STUB_BIN" "$TEST_ROOT/home"
	ORIGINAL_PATH="$PATH"
}

# Mirror the host's standard command directories into a private bin, minus the commands whose
# absence is the point of the test. PATH is then exactly the stub dir plus this mirror.
#
# An allow-list was tried first and was the wrong shape. What these tests need is not "the
# script may use exactly these ten utilities" -- that guesses at an implementation detail and
# breaks the moment the script reaches for one more, which is what a sibling suite hit when `tar -xzf`
# shelled out to gzip on GNU tar. What they need is "the host does not supply dotnet", with an
# otherwise realistic system underneath. Naming the excluded command states that directly.
#
# The original `PATH="$STUB_BIN:/usr/bin:/bin"` stated nothing: `ensure-dotnet.sh` decides whether to
# install by probing `command -v dotnet`, ubuntu-latest ships dotnet in /usr/bin and macOS does
# not, so the probe succeeded on CI and the script took the already-available branch instead of
# the install branch under test -- green locally, red in CI. ~keep
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

@test "should_skip_installation_when_dotnet_is_already_on_path" {
	printf '#!/usr/bin/env bash\nprintf 9.0.100\n' >"$STUB_BIN/dotnet"
	printf '#!/usr/bin/env bash\nexit 99\n' >"$STUB_BIN/curl"
	chmod +x "$STUB_BIN/dotnet" "$STUB_BIN/curl"

	run env PATH="$STUB_BIN:$ORIGINAL_PATH" HOME="$TEST_ROOT/home" \
		bash "$ACTION_DIR/scripts/ensure-dotnet.sh"

	[ "$status" -eq 0 ]
	[ "$output" = "dotnet already available: 9.0.100" ]
}

@test "should_install_lts_sdk_and_publish_dotnet_path_when_missing" {
	github_path="$TEST_ROOT/github-path"
	dotnet_template="$TEST_ROOT/dotnet-template"
	printf '#!/usr/bin/env bash\nprintf 8.0.999\n' >"$dotnet_template"
	chmod +x "$dotnet_template"
	printf '%s\n' '#!/usr/bin/env bash' \
		'for argument in "$@"; do output="$argument"; done' \
		'printf "%s\n" "#!/usr/bin/env bash" "mkdir -p \"\$HOME/.dotnet\"" "cp \"\$DOTNET_TEMPLATE\" \"\$HOME/.dotnet/dotnet\"" "chmod +x \"\$HOME/.dotnet/dotnet\"" >"$output"' >"$STUB_BIN/curl"
	chmod +x "$STUB_BIN/curl"

	run env PATH="$STUB_BIN:$SYS_BIN" HOME="$TEST_ROOT/home" GITHUB_PATH="$github_path" \
		DOTNET_TEMPLATE="$dotnet_template" \
		bash "$ACTION_DIR/scripts/ensure-dotnet.sh"

	[ "$status" -eq 0 ]
	[ "$output" = $'Installing .NET SDK...\nInstalled dotnet: 8.0.999' ]
	[ "$(cat "$github_path")" = "$TEST_ROOT/home/.dotnet" ]
	[ ! -e /tmp/dotnet-install.sh ]
}
