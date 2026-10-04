#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aether-regression.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Core" "$scratch/Tests/RegressionTests"
cp "$test_dir/Package.swift" "$scratch/Package.swift"
cp "$repo_root/Aether/Utilities/Handlers/SafeIPAArchive.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Utilities/ServerInstallMonitor.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Extensions/FileManager+clone.swift" "$scratch/Sources/Core/"
cp "$repo_root/Aether/Utilities/TaskCancellationRelay.swift" "$scratch/Sources/Core/"
cp "$test_dir/RegressionTests.swift" "$scratch/Tests/RegressionTests/"
python3 "$test_dir/generate-operation-tests.py" "$scratch/Tests/RegressionTests"
python3 "$test_dir/generate-lifecycle-tests.py" "$scratch/Tests/RegressionTests"
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
swift test --package-path "$scratch"
