#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aether-regression.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Core" "$scratch/Tests/RegressionTests"
cp "$test_dir/Package.swift" "$scratch/Package.swift"
cp "$repo_root/Aether/Utilities/ServerInstallProgress.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Extensions/FileManager+clone.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Utilities/TaskCancellationRelay.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Utilities/Handlers/BundlePackageWriter.swift" "$scratch/Sources/Core/"
cp "$test_dir/PackagingTests.swift" "$scratch/Tests/RegressionTests/"
cp "$test_dir/RegressionTests.swift" "$scratch/Tests/RegressionTests/"
python3 "$test_dir/generate-operation-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-lifecycle-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-icon-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-tunnel-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-ui-state-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-background-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-correction-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-audit-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-fixtures.py" "$scratch/Tests/RegressionTests/Fixtures"
if [[ -n "${AETHER_ZIPFOUNDATION_CHECKOUT:-}" ]]; then
  python3 - "$scratch/Package.swift" "$AETHER_ZIPFOUNDATION_CHECKOUT" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text()
s=s.replace('.package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20")', '.package(path: '+json.dumps(sys.argv[2])+')')
s=s.replace('package: "ZIPFoundation"', 'package: '+json.dumps(pathlib.Path(sys.argv[2]).name))
p.write_text(s)
PY
fi
if [[ -n "${AETHER_ZIP_CHECKOUT:-}" ]]; then
  python3 - "$scratch/Package.swift" "$AETHER_ZIP_CHECKOUT" <<'PYZIP'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text()
s=s.replace('.package(url: "https://github.com/marmelroy/Zip", exact: "2.1.2")', '.package(path: '+json.dumps(sys.argv[2])+')')
s=s.replace('package: "Zip"', 'package: '+json.dumps(pathlib.Path(sys.argv[2]).name))
p.write_text(s)
PYZIP
fi
swift test --package-path "$scratch"
for check in run-audit-fix-checks.py run-efficiency-checks.py run-device-loading-checks.py run-installed-loading-checks.py run-whole-app-checks.py run-foreground-recovery-checks.py run-signing-identity-checks.py; do
  python3 "$test_dir/$check"
done
