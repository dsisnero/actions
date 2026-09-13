#!/usr/bin/env bats

setup() {
	ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	SYS_BIN="$TEST_ROOT/sysbin"
	mkdir -p "$STUB_BIN" "$SYS_BIN" "$TEST_ROOT/home"
	ORIGINAL_PATH="$PATH"
	expose_system_commands bash chmod cp mkdir rm sh
}

# Link the named system utilities into a private directory so a test can run the script
# against a PATH holding nothing else.
#
# Putting /usr/bin on that PATH was not isolation: `ensure-dotnet.sh` decides whether to
# install by probing `command -v dotnet`, and ubuntu-latest ships dotnet there while macOS
# does not -- so the probe succeeded and the script took the already-available branch instead
# of the install branch under test. That is why this passed locally and failed in CI. `bash`
# is on the list because the stubs this suite writes start with `#!/usr/bin/env bash` and
# `env` resolves that interpreter through PATH. ~keep
expose_system_commands() {
	local name source
	for name in "$@"; do
		source="$(command -v "$name")" || continue
		ln -sf "$source" "$SYS_BIN/$name"
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
