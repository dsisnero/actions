#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/unix.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
  mkdir -p "$RUNNER_TEMP"; : >"$GITHUB_PATH"
}

stub() {
  printf '%s\n' '#!/usr/bin/env bash' 'set -eu' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

@test "should_install_resolved_zig_archive_and_publish_executable_directory" {
  stub uname '[[ "$1" == "-s" ]] && echo Linux || echo x86_64'
  stub python3 'printf "%s\n" "https://example.test/zig.tar.xz" "0.14.0"'
  stub curl 'while [[ "$1" != "--output" ]]; do shift; done; touch "$2"'
  stub tar 'while [[ "$1" != "-C" ]]; do shift; done; mkdir -p "$2/zig-0.14.0"; printf "%s\n" "#!/usr/bin/env bash" "echo 0.14.0" >"$2/zig-0.14.0/zig"; chmod +x "$2/zig-0.14.0/zig"'
  run "$SCRIPT" 0.14.0
  [ "$status" -eq 0 ]
  [ "$output" = $'Resolved Zig 0.14.0 -> 0.14.0\nDownloading https://example.test/zig.tar.xz\n0.14.0' ]
  [ "$(cat "$GITHUB_PATH")" = "$RUNNER_TEMP/zig/zig-0.14.0" ]
}

@test "should_return_error_when_operating_system_is_unsupported" {
  stub uname 'echo Plan9'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "Unsupported OS: Plan9" ]
}
