#!/usr/bin/env python3
"""Run local production-code tunnel harnesses; no app build, device, or simulator."""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

SUITES = (
    ('callbacks', 'run-tunnel-callback-checks.py'),
    ('connection-lifecycle', 'run-tunnel-lifecycle-checks.py'),
    ('foreground-races', 'run-foreground-recovery-checks.py'),
    ('refresh-verification', 'run-refresh-verification-checks.py'),
    ('cellular-lifecycle', 'run-cellular-lifecycle-checks.py'),
    ('cellular-verification-and-placeholders', 'run-cellular-verification-checks.py'),
    ('idle-vpn-stop', 'run-idle-tunnel-stop-checks.py'),
    ('resource-recovery', 'run-resource-recovery-checks.py'),
    ('library-startup', 'run-library-startup-checks.py'),
    ('installed-loading', 'run-installed-loading-checks.py'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repeat', type=int, default=3, help='Fresh-process passes per suite (default: 3)')
    parser.add_argument('--timeout', type=float, default=90, help='Watchdog seconds per suite, including compilation')
    parser.add_argument('--output', type=Path, help='New directory for logs and JSON summary; defaults outside the repo')
    args = parser.parse_args()
    if args.repeat < 1 or args.timeout <= 0:
        parser.error('repeat and timeout must be positive')
    if args.output:
        output = args.output.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix='aether-tunnel-flow-'))
    root = Path(__file__).resolve().parents[2]
    records = []
    report = {'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'repeat': args.repeat, 'timeout_seconds': args.timeout, 'results': records,
              'scope': 'Local production-method harnesses with platform substitutes; not physical-device validation'}
    try:
        report['commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        report['working_tree'] = subprocess.check_output(['git', 'status', '--short'], cwd=root, text=True)
    except (OSError, subprocess.CalledProcessError):
        pass
    def save():
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    save()
    print('Logs: ' + str(output), flush=True)
    for iteration in range(1, args.repeat + 1):
        for name, script in SUITES:
            log = output / f'{iteration:02d}-{name}.log'
            began = time.monotonic()
            with log.open('w') as handle:
                process = subprocess.Popen([sys.executable, str(root / 'Tests/Regression' / script)],
                                           cwd=root, stdout=handle, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    code = process.wait(timeout=args.timeout)
                    status = 'passed' if code == 0 else 'failed'
                except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    status = 'timed-out' if isinstance(error, subprocess.TimeoutExpired) else 'interrupted'
                    code = process.returncode
            records.append({'pass': iteration, 'suite': name, 'status': status,
                            'seconds': round(time.monotonic() - began, 3),
                            'exit_code': code, 'log': str(log)})
            save()
            print(f'{iteration}/{args.repeat} {name}: {status}', flush=True)
            if status == 'interrupted':
                return 130
    failures = sum(item['status'] != 'passed' for item in records)
    print(f'{len(records) - failures}/{len(records)} passed. Report: {output / "summary.json"}')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
