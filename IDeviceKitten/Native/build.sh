#!/bin/bash
# Build the pinned native dependency with verification-only tunnel connections.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="${AETHER_NATIVE_BUILD_DIR:-$native_dir/.build}"
revision=d32c8189c51c2789496b0768039419c3705498c3
archive_sha=882282f8b64c3908f28c2d42a556fcf92102ee982d8be3b8b5b448a02572d731
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v cargo >/dev/null || { echo 'Install Rust using https://rustup.rs, then rerun this script.' >&2; exit 1; }
mkdir -p "$work_dir"
archive="$work_dir/idevice.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl -fL "https://codeload.github.com/jkcoxson/idevice/tar.gz/$revision" -o "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$archive_sha" ]] || { echo 'Native source checksum mismatch' >&2; exit 1; }
source_dir="$work_dir/idevice-$revision"
# Extract pristine source every time so patches cannot accumulate.
if [[ -d "$source_dir" ]]; then
  rm -rf "$source_dir"
fi
tar -xzf "$archive" -C "$work_dir"
patch -d "$source_dir" -p1 < "$native_dir/verify-saved-pairing.patch"
patch -d "$source_dir" -p1 < "$native_dir/afc-large-writes.patch"
patch -d "$source_dir" -p1 < "$native_dir/afc-transfer-diagnostics.patch"
patch -d "$source_dir" -p1 < "$native_dir/tls-stream-optimization.patch"
export CARGO_TARGET_DIR="$work_dir/target"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=12.0
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios-macabi x86_64-apple-ios-macabi)
rustup target add "${targets[@]}"
cd "$source_dir"
# aes 0.8 requires this opt-in to compile its ARMv8 backend. Its
# cpufeatures detector supports Apple ARM64; Intel keeps AES-NI detection.
# Preserve caller flags, including Cargo's higher-priority encoded form.
cargo_for_target() (
  local target="$1"
  shift
  if [[ "$target" == aarch64-apple-* ]]; then
    if [[ "${CARGO_ENCODED_RUSTFLAGS+x}" == x ]]; then
      local separator=$'\x1f'
      local encoded_flags="${CARGO_ENCODED_RUSTFLAGS}"
      if [[ -n "$encoded_flags" ]]; then
        encoded_flags+="$separator"
      fi
      export CARGO_ENCODED_RUSTFLAGS="${encoded_flags}--cfg${separator}aes_armv8"
    else
      export RUSTFLAGS="${RUSTFLAGS:-} --cfg aes_armv8"
    fi
  fi
  cargo "$@"
)
host_target="$(rustc -vV | sed -n 's/^host: //p')"
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features remote_pairing,rustcrypto saved_pairing_tests
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features remote_pairing,rustcrypto verification_only_wire_tests
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features afc,remote_pairing,rustcrypto afc_large_write_tests
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features afc,remote_pairing,rustcrypto tls_stream_tests
for target in "${targets[@]}"; do
  cargo_for_target "$target" build --locked --release -p idevice-ffi --target "$target"
done
headers="$work_dir/headers"
mkdir -p "$headers"
cp ffi/idevice.h "$headers/idevice.h"
cat > "$headers/module.modulemap" <<'MAP'
module IDevice {
    header "idevice.h"
    export *
}
MAP
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libidevice_ffi.a" -output "$work_dir/idevice-ios-sim.a"
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libidevice_ffi.a" -output "$work_dir/idevice-macos.a"
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-macabi/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-ios-macabi/release/libidevice_ffi.a" -output "$work_dir/idevice-maccatalyst.a"
output="$work_dir/IDevice.xcframework"
rm -rf "$output"
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a" -headers "$headers" \
  -library "$work_dir/idevice-ios-sim.a" -headers "$headers" \
  -library "$work_dir/idevice-macos.a" -headers "$headers" \
  -library "$work_dir/idevice-maccatalyst.a" -headers "$headers" \
  -output "$output"
# Replace the completed artifact only after every architecture succeeds.
rm -rf "$native_dir/IDevice.xcframework"
mv "$output" "$native_dir/IDevice.xcframework"
