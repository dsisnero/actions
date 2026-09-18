#!/usr/bin/env bash
set -euo pipefail

FFI_CRATE="${INPUT_FFI_CRATE:-xberg-ffi}"
PACKAGE_DIR="${INPUT_PACKAGE_DIR:-packages/crystal}"
BUILD_PROFILE="${INPUT_BUILD_PROFILE:-release}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

case "$BUILD_PROFILE" in
release)
	profile_flag="--release"
	target_subdir="release"
	;;
dev | debug)
	profile_flag=""
	target_subdir="debug"
	;;
*)
	profile_flag="--profile $BUILD_PROFILE"
	target_subdir="$BUILD_PROFILE"
	;;
esac

lib_basename="${FFI_CRATE//-/_}"

case "${RUNNER_OS:-$(uname -s)}" in
Linux) lib_filename="lib${lib_basename}.so" ;;
macOS | Darwin) lib_filename="lib${lib_basename}.dylib" ;;
Windows | MINGW* | MSYS* | CYGWIN*) lib_filename="${lib_basename}.dll" ;;
*) lib_filename="lib${lib_basename}.so" ;;
esac

workspace="${GITHUB_WORKSPACE:-$PWD}"
target_dir="${CARGO_TARGET_DIR:-$workspace/target}"
ffi_library_path="$target_dir/$target_subdir/$lib_filename"

if [[ "$DRY_RUN" == "true" ]]; then
	echo "[dry-run] cargo build --locked -p $FFI_CRATE $profile_flag"
	echo "[dry-run] cd $PACKAGE_DIR && crystal build --link-flags -L$PACKAGE_DIR/native"
	echo "[dry-run] expected ffi library: $ffi_library_path"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "ffi-library-path=$ffi_library_path" >>"$GITHUB_OUTPUT"
	fi
	exit 0
fi

if [[ ! -d "$PACKAGE_DIR" ]]; then
	echo "Error: package-dir '$PACKAGE_DIR' does not exist" >&2
	exit 1
fi

echo "=== Building cargo crate $FFI_CRATE (profile: $BUILD_PROFILE) ==="
# shellcheck disable=SC2086
cargo build --locked -p "$FFI_CRATE" $profile_flag

if [[ ! -f "$ffi_library_path" ]]; then
	echo "Warning: expected FFI library not found at $ffi_library_path" >&2
	found=$(find "$target_dir/$target_subdir" -maxdepth 1 -type f \
		\( -name "lib${lib_basename}.*" -o -name "${lib_basename}.dll" \) \
		-print -quit 2>/dev/null || true)
	if [[ -n "$found" ]]; then
		ffi_library_path="$found"
		echo "Resolved FFI library: $ffi_library_path"
	else
		echo "Error: no built FFI library found for $FFI_CRATE" >&2
		exit 1
	fi
fi

# Stage the shared library where the generated bindings expect it. Newer alef
# emits @[Link(ldflags: "-L #{__DIR__}/../native ...")] (the package's native/
# dir); older shards emit a bare "-l<name>", which the explicit --link-flags -L
# below covers. Crystal packages always ship a --release build, so we never
# stage a debug artifact.
echo "=== Staging FFI library into $PACKAGE_DIR/native ==="
mkdir -p "$PACKAGE_DIR/native"
cp "$ffi_library_path" "$PACKAGE_DIR/native/"

echo "=== Running Crystal smoke build in $PACKAGE_DIR ==="
(
	cd "$PACKAGE_DIR"
	name=$(sed -n 's/^name:[[:space:]]*//p' shard.yml 2>/dev/null | head -1)
	main=$(sed -n '/^targets:/,$p' shard.yml 2>/dev/null | sed -n 's/^[[:space:]]*main:[[:space:]]*//p' | head -1)
	if [[ -z "$main" && -n "$name" && -f "src/${name}.cr" ]]; then
		main="src/${name}.cr"
	fi
	if [[ -n "$main" ]]; then
		echo "=== Building shard target: $main ==="
		crystal build --link-flags "-L${PWD}/native" "$main"
	else
		echo "No 'targets.*.main' in shard.yml; falling back to 'shards build'"
		shards build
	fi
	if [[ -d spec ]]; then
		echo "=== Running crystal spec ==="
		shards spec
	fi
)

echo "Crystal smoke build complete"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "ffi-library-path=$ffi_library_path" >>"$GITHUB_OUTPUT"
fi