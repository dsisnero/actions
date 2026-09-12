#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="bats-core/bats-core"
readonly API_BASE_URL="https://api.github.com/repos/${REPOSITORY}/releases"

error() {
	echo "::error::$*" >&2
	exit 1
}

normalize_version() {
	local requested_version="$1"

	if [[ "$requested_version" == "latest" ]]; then
		printf '%s\n' "latest"
		return
	fi

	if [[ ! "$requested_version" =~ ^v?[0-9]+(\.[0-9]+){1,2}([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
		error "Invalid Bats version '${requested_version}'. Use 'latest' or a version such as '1.11.1' or 'v1.11.1'."
	fi

	printf 'v%s\n' "${requested_version#v}"
}

fetch_release_metadata() {
	local release_url="$1"
	local metadata_file="$2"
	local auth_args=()

	if [[ -n "${CURL_AUTH_HEADER:-}" ]]; then
		auth_args=(--header "$CURL_AUTH_HEADER")
	fi

	if ! curl \
		--proto '=https' \
		--tlsv1.2 \
		--fail \
		--silent \
		--show-error \
		--connect-timeout 10 \
		--max-time 30 \
		--header "Accept: application/vnd.github+json" \
		--header "X-GitHub-Api-Version: 2022-11-28" \
		"${auth_args[@]}" \
		--output "$metadata_file" \
		"$release_url"; then
		error "Could not retrieve Bats release metadata from GitHub."
	fi
}

read_release_tag() {
	local metadata_file="$1"

	python3 - "$metadata_file" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)

tag = metadata.get("tag_name")
if not isinstance(tag, str):
    raise ValueError("release metadata has no tag_name")

print(tag)
PY
}

release_has_source_archive() {
	local metadata_file="$1"
	local release_tag="$2"

	python3 - "$metadata_file" "$release_tag" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)

assets = metadata.get("assets")
if not isinstance(assets, list):
    raise ValueError("release metadata has no assets list")

if metadata.get("tag_name") != sys.argv[2]:
    raise ValueError("release tag does not match")

tarball_url = metadata.get("tarball_url")
expected_url = f"https://api.github.com/repos/bats-core/bats-core/tarball/{sys.argv[2]}"
if tarball_url != expected_url:
    raise ValueError("release metadata has an unexpected source archive URL")
PY
}

validate_tag() {
	local tag="$1"

	[[ "$tag" =~ ^v[0-9]+(\.[0-9]+){1,2}([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

validate_archive() {
	local archive="$1"
	local expected_root="$2"
	local archive_entry
	local found_bats=false

	while IFS= read -r archive_entry; do
		archive_entry="${archive_entry#./}"
		[[ -n "$archive_entry" ]] || continue

		case "$archive_entry" in
		/* | ../* | */../* | */..)
			error "Downloaded Bats archive contains an unsafe path."
			;;
		esac

		if [[ "$archive_entry" != "$expected_root" && "$archive_entry" != "$expected_root/"* ]]; then
			error "Downloaded Bats archive has an unexpected top-level path."
		fi

		if [[ "$archive_entry" == "${expected_root}/bin/bats" ]]; then
			found_bats=true
		fi
	done < <(tar -tzf "$archive")

	if ! tar -tvzf "$archive" |
		awk 'substr($0, 1, 1) !~ /[-d]/ { invalid = 1 } END { exit !invalid }'; then
		error "Downloaded Bats archive contains unsupported link or special-file entries."
	fi

	if [[ "$found_bats" != true ]]; then
		error "Downloaded Bats archive does not contain bin/bats."
	fi
}

download_source_archive() {
	local release_tag="$1"
	local archive="$2"

	if ! curl \
		--proto '=https' \
		--proto-redir '=https' \
		--tlsv1.2 \
		--fail \
		--silent \
		--show-error \
		--location \
		--connect-timeout 10 \
		--max-time 120 \
		--retry 3 \
		--retry-delay 2 \
		--output "$archive" \
		"https://github.com/${REPOSITORY}/archive/refs/tags/${release_tag}.tar.gz"; then
		error "Could not download the official Bats source archive for ${release_tag}."
	fi
}

requested_version="${INPUT_VERSION:-latest}"
install_dir="${INPUT_INSTALL_DIR:-}"
release_tag="$(normalize_version "$requested_version")"

case "$(uname -s)" in
Linux | Darwin) ;;
*) error "Unsupported operating system: $(uname -s). install-bats supports Linux and macOS only." ;;
esac

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
	error "install-bats requires curl, tar, and python3 on PATH."
fi

install_root="${install_dir:-${RUNNER_TEMP:-${HOME}/.local}/bats}"
mkdir -p "$install_root"

stage_dir="${install_root}/.install-bats-${RANDOM}-${RANDOM}"
if ! (umask 077 && mkdir "$stage_dir"); then
	error "Could not create a private staging directory in ${install_root}."
fi
trap 'rm -rf "$stage_dir"' EXIT

CURL_AUTH_HEADER=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	if [[ "$GITHUB_TOKEN" == *$'\r'* || "$GITHUB_TOKEN" == *$'\n'* ]]; then
		error "GITHUB_TOKEN must not contain carriage returns or newlines."
	fi
	CURL_AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
fi

metadata_file="${stage_dir}/release.json"
if [[ "$release_tag" == "latest" ]]; then
	fetch_release_metadata "${API_BASE_URL}/latest" "$metadata_file"
else
	fetch_release_metadata "${API_BASE_URL}/tags/${release_tag}" "$metadata_file"
fi

if ! resolved_tag="$(read_release_tag "$metadata_file")" || ! validate_tag "$resolved_tag"; then
	error "GitHub returned an invalid Bats release tag."
fi
if [[ "$release_tag" != "latest" && "$resolved_tag" != "$release_tag" ]]; then
	error "GitHub returned ${resolved_tag}, not the requested Bats release ${release_tag}."
fi

asset_version="${resolved_tag#v}"
asset_name="bats-core-${asset_version}.tar.gz"
if ! release_has_source_archive "$metadata_file" "$resolved_tag"; then
	error "Bats release ${resolved_tag} has invalid source archive metadata."
fi

release_dir="${install_root}/bats-core-${asset_version}"
bats_bin="${release_dir}/bin/bats"
if [[ -x "$bats_bin" ]]; then
	echo "Using existing Bats ${resolved_tag} at ${bats_bin}"
else
	archive="${stage_dir}/${asset_name}"
	download_source_archive "$resolved_tag" "$archive"
	validate_archive "$archive" "bats-core-${asset_version}"

	if ! tar -xzf "$archive" -C "$stage_dir"; then
		error "Could not safely extract the downloaded Bats archive."
	fi

	extracted_dir="${stage_dir}/bats-core-${asset_version}"
	if [[ ! -x "${extracted_dir}/bin/bats" ]]; then
		error "Extracted Bats archive did not provide an executable bin/bats."
	fi
	if [[ -e "$release_dir" ]]; then
		error "Installation directory already exists but does not contain an executable Bats binary: ${release_dir}."
	fi
	mv "$extracted_dir" "$release_dir"
fi

if [[ ! -x "$bats_bin" ]]; then
	error "Bats binary is missing or not executable at ${bats_bin}."
fi

"$bats_bin" --version

if [[ -z "${GITHUB_PATH:-}" ]]; then
	error "GITHUB_PATH is not set; install-bats must run in a GitHub Actions job."
fi
printf '%s\n' "${release_dir}/bin" >>"$GITHUB_PATH"
