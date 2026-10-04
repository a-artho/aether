#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
simulator="${1:?Pass a booted iOS Simulator UUID}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aether-platform.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/PlatformCheck.app"
python3 - "$scratch/PlatformCheck.app/Info.plist" <<'PY'
import pathlib,plistlib,sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.aether.audit.platformcheck','CFBundleExecutable':'PlatformCheck','CFBundleName':'PlatformCheck','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1],'UILaunchScreen':{},'MinimumOSVersion':'26.0'}))
PY
extensions="$repo_root/NimbleKit/Sources/NimbleExtensions"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios26.0-simulator" -sdk "$sdk" \
 "$test_dir/PlatformRunner.swift" \
 "$extensions/UIApplication/UIApplication+installedState.swift" \
 "$extensions/UIApplication/UIApplication+open_private.swift" \
 "$extensions/UIAlertController/UIAlertController+Alerts.swift" \
 "$extensions/UIAlertController/UIApplication+topController.swift" \
 "$extensions/UIApplication/UIApplication+suspend.swift" \
 "$extensions/String/String+localized.swift" -o "$scratch/PlatformCheck.app/PlatformCheck"
codesign --force --sign - "$scratch/PlatformCheck.app"
xcrun simctl install "$simulator" "$scratch/PlatformCheck.app"
xcrun simctl launch --console "$simulator" com.aether.audit.platformcheck
xcrun simctl uninstall "$simulator" com.aether.audit.platformcheck
