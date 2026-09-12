#!/usr/bin/env bats

setup() {
	ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	TEST_ROOT="$(mktemp -d)"
	STUB_BIN="$TEST_ROOT/bin"
	TRACE="$TEST_ROOT/brew-trace"
	mkdir -p "$STUB_BIN"
	ORIGINAL_PATH="$PATH"
	printf '%s\n' '#!/usr/bin/env bash' \
		'printf "%s\n" "$*" >>"$BREW_TRACE"' \
		'case "$1" in' \
		'--version) echo "Homebrew 5.0.0" ;;' \
		'config) echo "HOMEBREW_VERSION: 5.0.0" ;;' \
		'update|tap|trust|install) exit 0 ;;' \
		'uninstall|list) exit 1 ;;' \
		'bottle)' \
		'  printf bottle > "demo--1.2.3.arm64_sonoma.bottle.tar.gz"' \
		'  printf "{}" > "demo--1.2.3.arm64_sonoma.bottle.json" ;;' \
		'esac' >"$STUB_BIN/brew"
	printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$GH_TRACE"\n' >"$STUB_BIN/gh"
	chmod +x "$STUB_BIN/brew" "$STUB_BIN/gh"
}

teardown() {
	rm -rf "$TEST_ROOT"
}

@test "should_stage_renamed_bottle_and_manifest_when_upload_is_false" {
	out_dir="$TEST_ROOT/output"
	gh_trace="$TEST_ROOT/gh-trace"

	run env PATH="$STUB_BIN:$ORIGINAL_PATH" BREW_TRACE="$TRACE" GH_TRACE="$gh_trace" \
		TAG=v1.2.3 VERSION=1.2.3 TAP=example/tap FORMULAS=demo OUT_DIR="$out_dir" \
		GITHUB_REPO=example/project UPLOAD=false RUNNER_OS=macOS \
		bash "$ACTION_DIR/scripts/build-bottles.sh"

	[ "$status" -eq 0 ]
	[ "$(cat "$out_dir/demo-1.2.3.arm64_sonoma.bottle.tar.gz")" = "bottle" ]
	[ "$(cat "$out_dir/demo--1.2.3.arm64_sonoma.bottle.json")" = "{}" ]
	[ ! -e "$gh_trace" ]
	[ "$(cat "$TRACE")" = $'--version\nconfig\nupdate --quiet\ntap example/tap\ntrust example/tap\nuninstall --force example/tap/demo\n--repository example/tap\nlist libheif\ninstall --build-bottle --verbose example/tap/demo\nbottle --json --no-rebuild example/tap/demo' ]
	[[ "$output" == *"UPLOAD=false: staged demo-1.2.3.arm64_sonoma.bottle.tar.gz in $out_dir for caller-side upload"* ]]
}

@test "should_return_error_when_brew_produces_no_bottle_tarball" {
	printf '%s\n' '#!/usr/bin/env bash' \
		'case "$1" in --version) echo "Homebrew 5.0.0" ;; config|update|tap|trust|install) exit 0 ;; uninstall|list) exit 1 ;; esac' \
		>"$STUB_BIN/brew"
	chmod +x "$STUB_BIN/brew"

	run env PATH="$STUB_BIN:$ORIGINAL_PATH" TAG=v1 VERSION=1 TAP=example/tap FORMULAS=demo \
		OUT_DIR="$TEST_ROOT/output" GITHUB_REPO=example/project UPLOAD=false RUNNER_OS=macOS \
		bash "$ACTION_DIR/scripts/build-bottles.sh"

	[ "$status" -eq 1 ]
	[[ "$output" == *"ERROR: no bottle tarball produced for demo"* ]]
}
