#!/bin/bash
# Build the pinned native dependency with verification-only tunnel connections.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="${AETHER_NATIVE_BUILD_DIR:-$native_dir/.build}"
revision=d32c8189c51c2789496b0768039419c3705498c3
archive_sha=882282f8b64c3908f28c2d42a556fcf92102ee982d8be3b8b5b448a02572d731
if [[ "${AETHER_NATIVE_TEST_ONLY:-0}" != 1 ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
command -v cargo >/dev/null || { echo 'Install Rust using https://rustup.rs, then rerun this script.' >&2; exit 1; }
mkdir -p "$work_dir"
# These old experiments conflict with packet-boundary preservation and dynamic
# discovery. Fail explicitly rather than silently producing a different build.
if [[ "${AETHER_NATIVE_BATCH_IP_PACKETS:-0}" == 1 || "${AETHER_NATIVE_MSS_8K:-0}" == 1 ]]; then
  echo 'IP packet batching and fixed 8 KiB MSS experiments were removed. Local network tunnels now use validated packet-size probing.' >&2
  exit 1
fi
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
patch -d "$source_dir" -p1 < "$native_dir/afc-upload-progress.patch"
patch -d "$source_dir" -p1 < "$native_dir/self-install-handoff.patch"
patch -d "$source_dir" -p1 < "$native_dir/rsd-connection-timeout.patch"
# Pin the transitive TCP stack too: preserve cancellation fixes and apply our
# owned-buffer/packet-construction changes without an unreviewed idevice upgrade.
jktcp_revision=7df57dc59b47ec72fb5dc251fbe9344b0647246b
jktcp_archive="$work_dir/jktcp.tar.gz"
if [[ ! -f "$jktcp_archive" ]]; then
  curl -fL "https://codeload.github.com/jkcoxson/jktcp/tar.gz/$jktcp_revision" -o "$jktcp_archive"
fi
[[ "$(shasum -a 256 "$jktcp_archive" | cut -d ' ' -f 1)" == 14f617b10466954cc7a6b4f42090df2eaff4637a9b641c24ec3a1cb95718571d ]] || { echo 'TCP source checksum mismatch' >&2; exit 1; }
mkdir -p "$source_dir/aether-jktcp"
tar -xzf "$jktcp_archive" -C "$source_dir/aether-jktcp" --strip-components=1
patch -d "$source_dir/aether-jktcp" -p1 < "$native_dir/jktcp-transport-optimization.patch"
patch -d "$source_dir" -p1 < "$native_dir/local-transport-optimization.patch"
export CARGO_TARGET_DIR="$work_dir/target"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=12.0
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
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
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features afc,remote_pairing,rustcrypto,tunnel_tcp_stack aether_dynamic_tunnel_tests
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features installation_proxy,rustcrypto self_install_handoff_tests
cargo_for_target "$host_target" test --locked -p idevice --no-default-features --features rsd,rustcrypto rsd_connection_timeout_tests
# Exercise the stack without pcap (production network configuration) and with
# pcap (the full FFI feature set). Manual privileged TUN tests remain ignored.
cargo_for_target "$host_target" test --manifest-path "$source_dir/aether-jktcp/Cargo.toml" --locked --no-default-features
cargo_for_target "$host_target" test --manifest-path "$source_dir/aether-jktcp/Cargo.toml" --locked
ffi_features=full,rustcrypto
native_features=""
if [[ "${AETHER_NATIVE_LARGE_SEND_WINDOW:-0}" == 1 ]]; then
  ffi_features+=,aether-large-send-window
  native_features="${native_features:+${native_features},}aether-large-send-window"
fi
cargo_for_target "$host_target" test --locked -p idevice-ffi --no-default-features --features "$ffi_features" aether_afc_ffi_tests
cargo_for_target "$host_target" test --locked -p idevice-ffi --no-default-features --features "$ffi_features" aether_logging_tests
if [[ "${AETHER_NATIVE_TEST_ONLY:-0}" == 1 ]]; then
  echo 'Native transport tests passed; framework packaging skipped.'
  exit 0
fi
targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios-macabi x86_64-apple-ios-macabi)
if [[ "${AETHER_NATIVE_IOS_ONLY:-0}" == 1 ]]; then
  targets=(aarch64-apple-ios)
fi
rustup target add "${targets[@]}"
for target in "${targets[@]}"; do
  cargo_for_target "$target" build --locked --release -p idevice-ffi --target "$target" --features "$native_features"
done
headers="$work_dir/headers"
rm -rf "$headers"
mkdir -p "$headers/IDevice"
cp ffi/idevice.h "$headers/IDevice/idevice.h"
cat > "$headers/IDevice/module.modulemap" <<'MAP'
module IDevice {
    header "idevice.h"
    export *
}
MAP
output="$work_dir/IDevice.xcframework"
rm -rf "$output"
if [[ "${AETHER_NATIVE_IOS_ONLY:-0}" == 1 ]]; then
  xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a" -headers "$headers" \
    -output "$output"
else
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libidevice_ffi.a" -output "$work_dir/idevice-ios-sim.a"
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libidevice_ffi.a" -output "$work_dir/idevice-macos.a"
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-macabi/release/libidevice_ffi.a" "$CARGO_TARGET_DIR/x86_64-apple-ios-macabi/release/libidevice_ffi.a" -output "$work_dir/idevice-maccatalyst.a"
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a" -headers "$headers" \
  -library "$work_dir/idevice-ios-sim.a" -headers "$headers" \
  -library "$work_dir/idevice-macos.a" -headers "$headers" \
  -library "$work_dir/idevice-maccatalyst.a" -headers "$headers" \
  -output "$output"
fi
# Replace the completed artifact only after every architecture succeeds.
rm -rf "$native_dir/IDevice.xcframework"
mv "$output" "$native_dir/IDevice.xcframework"
