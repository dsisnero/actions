#!/usr/bin/env bats
#
# Tests for the shared helper library itself.
#
# Every assertion helper is checked in BOTH directions. A helper that only ever passes is
# indistinguishable from one whose comparison is inverted or whose body is empty, and every suite
# in the org would inherit that. So each negative case runs the helper in a subshell and asserts
# it returned non-zero.

setup() {
	bats_load_library xberg-bats
	xberg_setup

	# The negative cases below re-source the library into a throwaway bash with a planted
	# $status/$output, which is the only way to assert an assertion helper FAILS without
	# failing the enclosing test. Resolved from the suite's own location so the file runs
	# under a plain `bats bats-lib/tests`. ~keep
	XBERG_LIB="$(cd "$BATS_TEST_DIRNAME/../xberg-bats" && pwd)/load.bash"
	[ -f "$XBERG_LIB" ] || {
		echo "helper library not found at $XBERG_LIB" >&2
		return 1
	}
}

# --- fixtures ---------------------------------------------------------------------------------

@test "xberg_setup should_create_an_empty_stub_bin_on_path_when_called" {
	[ -d "$XBERG_STUB_BIN" ]
	[ -z "$(ls -A "$XBERG_STUB_BIN")" ]
	case ":$PATH:" in *":$XBERG_STUB_BIN:"*) ;; *) return 1 ;; esac
}

@test "xberg_setup_github_env should_truncate_all_four_workflow_files_when_called_twice" {
	printf 'stale\n' >"$GITHUB_OUTPUT"
	printf 'stale\n' >"$GITHUB_ENV"
	printf 'stale\n' >"$GITHUB_PATH"
	printf 'stale\n' >"$GITHUB_STEP_SUMMARY"

	xberg_setup_github_env

	[ ! -s "$GITHUB_OUTPUT" ]
	[ ! -s "$GITHUB_ENV" ]
	[ ! -s "$GITHUB_PATH" ]
	[ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "xberg_setup should_not_create_the_trace_file_before_any_stub_runs" {
	# A trace that exists up front cannot distinguish "never called" from "wrote nothing".
	[ ! -e "$XBERG_TRACE" ]
}

@test "xberg_setup_isolated should_leave_path_untouched_when_called" {
	local before="$PATH"
	xberg_setup_isolated
	[ "$PATH" = "$before" ]
}

# --- stubs ------------------------------------------------------------------------------------

@test "xberg_stub should_place_an_executable_earlier_on_path_than_the_real_command" {
	xberg_stub git 'printf "stubbed-git\n"'
	run git anything
	xberg_assert_status 0
	xberg_assert_output "stubbed-git"
}

@test "xberg_stub should_not_impose_errexit_on_the_stub_body_when_a_test_is_false" {
	# `[ a = b ]` is intentionally false. Under `set -e` the stub would die there and never
	# reach its exit line, which is why the library does not inject errexit.
	xberg_stub probe \
		'[ a = b ]' \
		'printf "reached the end\n"' \
		'exit 0'
	run probe
	xberg_assert_status 0
	xberg_assert_output "reached the end"
}

@test "xberg_stub_exit should_return_the_requested_status_when_invoked" {
	xberg_stub_exit flaky 42
	run flaky
	xberg_assert_status 42
}

@test "xberg_stub_trace should_record_each_invocation_in_order_when_several_commands_run" {
	xberg_stub_trace docker
	xberg_stub_trace gh

	docker run --rm image:tag
	gh release create v1.0.0
	docker stop abc123

	xberg_assert_trace \
		"docker run --rm image:tag" \
		"gh release create v1.0.0" \
		"docker stop abc123"
}

@test "xberg_stub_trace should_use_the_supplied_label_when_one_is_given" {
	xberg_stub_trace python3 python
	python3 -m build
	xberg_assert_trace "python -m build"
}

@test "xberg_stub_curl_offline should_fail_with_status_99_when_the_path_reaches_the_network" {
	xberg_stub_curl_offline
	run curl --fail https://example.invalid
	xberg_assert_status 99
	xberg_assert_output_contains "curl must not run"
}

@test "xberg_stub_curl_body should_write_the_body_to_the_output_target_when_one_is_given" {
	xberg_stub_curl_body '{"tag_name":"v1.2.3"}'
	run curl --fail --output "$XBERG_WORK/release.json" https://example.invalid
	xberg_assert_status 0
	xberg_assert_file "$XBERG_WORK/release.json" '{"tag_name":"v1.2.3"}'
}

@test "xberg_stub_curl_body should_write_the_body_to_stdout_when_no_output_target_is_given" {
	xberg_stub_curl_body 'plain body'
	run curl --fail https://example.invalid
	xberg_assert_status 0
	xberg_assert_output "plain body"
}

@test "xberg_stub_curl_file should_deliver_a_real_archive_that_tar_can_extract" {
	# The fixture is a genuine tarball, so the caller's `tar` handling runs for real rather
	# than being mocked away.
	mkdir -p "$XBERG_WORK/payload/bin"
	printf '#!/bin/sh\nexit 0\n' >"$XBERG_WORK/payload/bin/tool"
	chmod +x "$XBERG_WORK/payload/bin/tool"
	tar -czf "$XBERG_WORK/tool.tar.gz" -C "$XBERG_WORK/payload" bin
	xberg_stub_curl_file "$XBERG_WORK/tool.tar.gz"

	run curl --fail -o "$XBERG_WORK/downloaded.tar.gz" https://example.invalid
	xberg_assert_status 0

	mkdir -p "$XBERG_WORK/extracted"
	tar -xzf "$XBERG_WORK/downloaded.tar.gz" -C "$XBERG_WORK/extracted"
	[ -x "$XBERG_WORK/extracted/bin/tool" ]
}

# --- host isolation ---------------------------------------------------------------------------

@test "xberg_capture_real should_export_the_absolute_path_of_a_real_command_when_it_exists" {
	xberg_capture_real sed
	[ -n "$XBERG_REAL_SED" ]
	[ -x "$XBERG_REAL_SED" ]
}

@test "xberg_capture_real should_fail_when_the_named_command_is_not_on_path" {
	run xberg_capture_real definitely-not-a-real-command
	[ "$status" -ne 0 ]
}

@test "xberg_shadow_system_path_without should_exclude_the_named_command_but_keep_the_rest" {
	xberg_shadow_system_path_without sed
	[ ! -e "$XBERG_SYS_BIN/sed" ]
	[ -e "$XBERG_SYS_BIN/cat" ]
}

@test "xberg_shadow_system_path_without should_fail_when_the_mirror_is_too_small_to_be_real" {
	# Guards the case where the mirror comes out empty and every test then passes because the
	# script found none of the utilities it needs -- right answer, wrong reason.
	# Exported because the library reads it as an environment knob, and `run` forks. ~keep
	export XBERG_SYS_BIN_MINIMUM=999999
	run xberg_shadow_system_path_without sed
	[ "$status" -ne 0 ]
	[[ "$output" == *"mirrored only"* ]]
}

@test "xberg_shadow_system_path_without should_fail_when_no_command_is_named" {
	run xberg_shadow_system_path_without
	[ "$status" -ne 0 ]
}

@test "xberg_isolated_path should_put_stubs_ahead_of_the_system_mirror_when_both_exist" {
	xberg_shadow_system_path_without sed
	[ "$(xberg_isolated_path)" = "$XBERG_STUB_BIN:$XBERG_SYS_BIN" ]
}

# --- assertions, both directions ---------------------------------------------------------------

@test "xberg_assert_status should_fail_when_the_status_differs" {
	run true
	xberg_assert_status 0
	run bash -c 'status=1; source "$1"; xberg_assert_status 0' _ "$XBERG_LIB"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_output should_fail_when_the_output_differs" {
	run printf 'exact'
	xberg_assert_output "exact"
	run bash -c 'output=actual; source "$1"; xberg_assert_output expected' _ "$XBERG_LIB"
	[ "$status" -ne 0 ]
	[[ "$output" == *"--- expected ---"* ]]
}

@test "xberg_assert_lines should_join_with_newlines_and_fail_when_a_line_differs" {
	run printf 'first\nsecond'
	xberg_assert_lines "first" "second"
	run bash -c 'output=$'"'"'first\nWRONG'"'"'; source "$1"; xberg_assert_lines first second' _ "$XBERG_LIB"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_output_contains should_fail_when_the_substring_is_absent" {
	run printf 'a haystack here'
	xberg_assert_output_contains "haystack"
	run bash -c 'output="a haystack here"; source "$1"; xberg_assert_output_contains needle' _ "$XBERG_LIB"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_no_output should_fail_when_something_was_printed" {
	run true
	xberg_assert_no_output
	run bash -c 'output=noisy; source "$1"; xberg_assert_no_output' _ "$XBERG_LIB"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_file should_fail_when_the_file_is_missing_or_differs" {
	printf 'contents' >"$XBERG_WORK/present"
	xberg_assert_file "$XBERG_WORK/present" "contents"

	run xberg_assert_file "$XBERG_WORK/absent" "contents"
	[ "$status" -ne 0 ]

	run xberg_assert_file "$XBERG_WORK/present" "different"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_file_absent should_fail_when_the_file_exists" {
	xberg_assert_file_absent "$XBERG_WORK/never-created"
	printf 'oops' >"$XBERG_WORK/created"
	run xberg_assert_file_absent "$XBERG_WORK/created"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_github_output should_compare_the_github_output_file_byte_for_byte" {
	printf 'version=1.2.3' >"$GITHUB_OUTPUT"
	xberg_assert_github_output "version=1.2.3"
	run xberg_assert_github_output "version=9.9.9"
	[ "$status" -ne 0 ]
}

@test "xberg_assert_github_env should_compare_a_heredoc_delimited_multiline_write" {
	printf 'PATHS<<__DELIM__\na\nb\n__DELIM__' >"$GITHUB_ENV"
	xberg_assert_github_env "$(printf 'PATHS<<__DELIM__\na\nb\n__DELIM__')"
}

@test "xberg_assert_trace_empty should_fail_when_a_traced_command_ran" {
	xberg_stub_trace docker
	xberg_assert_trace_empty
	docker ps
	run xberg_assert_trace_empty
	[ "$status" -ne 0 ]
}
