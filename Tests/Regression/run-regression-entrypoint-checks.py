"""Prevent CI/local check-list drift and accidentally omitted standalone checks."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
tests = root / 'Tests/Regression'
gate = (tests / 'run-release-gate.sh').read_text()
runner = (tests / 'run.sh').read_text()
command = 'run: bash Tests/Regression/run-release-gate.sh'
for name in ('release.yml', 'regression.yml'):
    workflow = (root / '.github/workflows' / name).read_text()
    assert command in workflow, f'{name} must use the shared local/CI regression entry point'
assert 'python3 "$test_dir/run-release-checks.py"' in gate
assert 'bash "$test_dir/run.sh"' in gate
listed = re.findall(r'run-[\w-]+-checks\.py', runner)
assert len(listed) == len(set(listed)), 'Standalone checks must not run twice'
expected = {p.name for p in tests.glob('run-*-checks.py')} - {'run-release-checks.py'}
assert set(listed) == expected, f'Check-list drift: missing={expected-set(listed)}, unknown={set(listed)-expected}'
print(f'Regression entry-point checks passed: identical local/CI gate, {len(listed)} standalone checks, no omissions/duplicates')
