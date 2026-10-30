#!/bin/bash
# Build the LTS cryptography dependency with its legacy provider built in.
set -euo pipefail
package_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="${AETHER_OPENSSL_BUILD_DIR:-$package_dir/.openssl-build}"
version=3.5.9
archive_sha=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
host_only=false
if [[ "${1:-}" == --host-only ]]; then
  host_only=true
elif [[ $# != 0 ]]; then
  echo 'Usage: build-openssl.sh [--host-only]' >&2
  exit 1
fi

# --host-only supports compile/link checks with Command Line Tools. Production
# always builds device, simulator, Mac, and Catalyst slices with full Xcode.
if ! $host_only; then
  xcodebuild -version >/dev/null
  xcrun --sdk iphoneos --show-sdk-path >/dev/null
fi
mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"
lock_dir="$work_dir/build.lock"
mkdir "$lock_dir" 2>/dev/null || { echo 'Another OpenSSL build is running.' >&2; exit 1; }
trap 'rmdir "$lock_dir"' EXIT

recipe="$(shasum -a 256 "$0" | cut -d ' ' -f 1)"
toolchain="$(xcrun clang --version)"
if ! $host_only; then
  stamp="$recipe $toolchain $(xcodebuild -version)"
  if [[ -f "$package_dir/OpenSSL.xcframework/.aether-build" ]] &&
     [[ "$(cat "$package_dir/OpenSSL.xcframework/.aether-build")" == "$stamp" ]]; then
    echo "OpenSSL $version XCFramework is current."
    exit 0
  fi
fi

archive="$work_dir/openssl-$version.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl -fL --retry 2 "https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz" -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$archive_sha" ]] || { echo 'OpenSSL source checksum mismatch.' >&2; exit 1; }
source_dir="$work_dir/openssl-$version"
rm -rf "$source_dir"
tar -xzf "$archive" -C "$work_dir"
jobs="$(sysctl -n hw.logicalcpu)"
if (( jobs > 8 )); then jobs=8; fi

build_arch() (
  local label="$1" sdk="$2" target="$3"
  shift 3
  local build_dir="$work_dir/$label"
  local prefix="$build_dir/install"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # Reconfigure from a clean build directory when the recipe/toolchain changes.
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cd "$build_dir"
  echo "Building OpenSSL $version: $label"
  export SDKROOT="$sdk_path"
  export CC="$(xcrun --sdk "$sdk" --find clang)"
  export CFLAGS="-isysroot \"$sdk_path\" $*"
  "$source_dir/Configure" "$target" no-shared no-module no-tests no-apps \
    --prefix="$prefix" --libdir=lib --openssldir="$prefix/ssl" >build.log 2>&1 || { tail -60 build.log >&2; exit 1; }
  make -j "$jobs" build_libs >>build.log 2>&1 || { tail -60 build.log >&2; exit 1; }
  make install_dev >>build.log 2>&1 || { tail -60 build.log >&2; exit 1; }
  # no-module is essential: iOS cannot load a legacy.dylib from a build machine.
  nm -g "$prefix/lib/libcrypto.a" >symbols.txt 2>/dev/null
  grep -q ' T _ossl_legacy_provider_init$' symbols.txt || { echo 'Missing built-in legacy provider.' >&2; exit 1; }
)

check_host() {
  local prefix="$work_dir/$1/install"
  xcrun --sdk macosx clang -I "$prefix/include" "$package_dir/check-openssl.c" \
    "$prefix/lib/libcrypto.a" -o "$work_dir/check-openssl"
  "$work_dir/check-openssl"
}

if $host_only; then
  arch="$(uname -m)"
  build_arch "host-$arch" macosx "darwin64-$arch-cc" -arch "$arch" -mmacosx-version-min=10.15
  check_host "host-$arch"
  echo "Host library: $work_dir/host-$arch/install/lib/libcrypto.a"
  exit 0
fi

build_arch ios-arm64 iphoneos ios64-xcrun -target arm64-apple-ios12.0
for arch in arm64 x86_64; do
  build_arch "sim-$arch" iphonesimulator "iossimulator-$arch-xcrun" -target "$arch-apple-ios12.0-simulator"
  build_arch "mac-$arch" macosx "darwin64-$arch-cc" -arch "$arch" -mmacosx-version-min=10.15
  catalyst_min_version=13.1
  if [[ "$arch" == arm64 ]]; then catalyst_min_version=14.0; fi
  build_arch "catalyst-$arch" macosx "darwin64-$arch-cc" -target "$arch-apple-ios${catalyst_min_version}-macabi"
done
check_host "mac-$(uname -m)"

slice_dir="$work_dir/slices"
rm -rf "$slice_dir"
mkdir -p "$slice_dir"
xcframework_args=()
assemble_slice() {
  local name="$1" first="$2"
  shift 2
  local directory="$slice_dir/$name"
  mkdir -p "$directory/Headers"
  cp -R "$work_dir/$first/install/include/openssl" "$directory/Headers/"
  cat >"$directory/Headers/module.modulemap" <<'MODULE'
module OpenSSL {
  umbrella "openssl"
  export *
}
MODULE
  if [[ $# == 0 ]]; then
    cp "$work_dir/$first/install/lib/libcrypto.a" "$directory/libcrypto.a"
  else
    xcrun lipo -create "$work_dir/$first/install/lib/libcrypto.a" "$work_dir/$1/install/lib/libcrypto.a" -output "$directory/libcrypto.a"
  fi
  xcframework_args+=(-library "$directory/libcrypto.a" -headers "$directory/Headers")
}
assemble_slice ios ios-arm64
assemble_slice simulator sim-arm64 sim-x86_64
assemble_slice macos mac-arm64 mac-x86_64
assemble_slice catalyst catalyst-arm64 catalyst-x86_64

output="$work_dir/OpenSSL.xcframework"
rm -rf "$output"
xcodebuild -create-xcframework "${xcframework_args[@]}" -output "$output"
cp "$source_dir/LICENSE.txt" "$output/LICENSE.txt"
printf '%s' "$stamp" >"$output/.aether-build"
rm -rf "$package_dir/OpenSSL.xcframework"
mv "$output" "$package_dir/OpenSSL.xcframework"
echo "Built OpenSSL $version LTS with built-in default and legacy providers."
