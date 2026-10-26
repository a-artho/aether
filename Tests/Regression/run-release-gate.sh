#!/bin/bash
# This is the shared local/GitHub release regression entry point. It never builds
# or publishes a release and can be run without a connected device.
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$test_dir/../.."
python3 "$test_dir/run-release-checks.py"
bash "$test_dir/run.sh"
