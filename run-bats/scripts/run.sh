#!/usr/bin/env bash
set -euo pipefail

error() {
	echo "::error::$*" >&2
	exit 1
}

is_within_directory() {
	local path="$1"
	local parent="$2"

	[[ "$path" == "$parent" || "$path" == "$parent/"* ]]
}

if ! command -v bats >/dev/null 2>&1; then
	error "bats is not on PATH. Run install-bats before run-bats."
fi

workspace_input="${GITHUB_WORKSPACE:-$PWD}"
if ! workspace="$(cd "$workspace_input" && pwd -P)"; then
	error "GitHub workspace does not exist: ${workspace_input}."
fi

working_directory_input="${INPUT_WORKING_DIRECTORY:-}"
if [[ -z "$working_directory_input" ]]; then
	working_directory_input="$PWD"
elif [[ "$working_directory_input" != /* ]]; then
	working_directory_input="$PWD/${working_directory_input}"
fi
if ! working_directory="$(cd "$working_directory_input" && pwd -P)"; then
	error "Working directory does not exist: ${working_directory_input}."
fi
if ! is_within_directory "$working_directory" "$workspace"; then
	error "Working directory must be inside GITHUB_WORKSPACE."
fi

test_path_input="${INPUT_PATH:-tests}"
if [[ -z "$test_path_input" ]]; then
	error "Bats test path must not be empty."
fi
if [[ "$test_path_input" == /* ]]; then
	candidate_path="$test_path_input"
else
	candidate_path="${working_directory}/${test_path_input}"
fi

if [[ ! -e "$candidate_path" ]]; then
	error "Bats test path does not exist: ${test_path_input}."
fi
if [[ -L "$candidate_path" ]]; then
	error "Bats test path must not be a symbolic link."
fi

if [[ -d "$candidate_path" ]]; then
	test_path="$(cd "$candidate_path" && pwd -P)"
else
	test_parent="$(cd "$(dirname "$candidate_path")" && pwd -P)"
	test_path="${test_parent}/$(basename "$candidate_path")"
fi

if ! is_within_directory "$test_path" "$workspace"; then
	error "Bats test path must be inside GITHUB_WORKSPACE."
fi
if ! is_within_directory "$test_path" "$working_directory"; then
	error "Bats test path must be inside the working directory."
fi

bats_args=()
if [[ -n "${INPUT_ARGS:-}" ]]; then
	while IFS= read -r argument || [[ -n "$argument" ]]; do
		if [[ -z "$argument" ]]; then
			error "args must be newline-delimited arguments without empty lines."
		fi
		bats_args+=("$argument")
	done <<<"$INPUT_ARGS"
fi

bats "${bats_args[@]}" "$test_path"
