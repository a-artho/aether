#!/usr/bin/env python3
"""Package a fresh app bundle and reject any remaining executable signatures."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess, tempfile
parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('--version', required=True)
args = parser.parse_args()
magics = {bytes.fromhex(s) for s in ('feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca')}
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='aether-unsigned-') as scratch:
    stage = pathlib.Path(scratch)
    app = stage / 'Payload' / 'Aether.app'
    shutil.copytree(args.app, app, symlinks=True)
    for path in list(app.rglob('_CodeSignature')):
        shutil.rmtree(path)
    for path in list(app.rglob('embedded.mobileprovision')):
        path.unlink()
    executables = []
    for path in app.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in magics:
            continue
        executables.append(path)
        signed = subprocess.run(['codesign', '-d', str(path)], capture_output=True, text=True)
        if signed.returncode == 0:
            subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
        verification = subprocess.run(['codesign', '-d', str(path)], capture_output=True, text=True)
        assert verification.returncode != 0 and 'not signed at all' in verification.stderr, str(path)
        commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
        assert 'LC_CODE_SIGNATURE' not in commands, str(path)
    assert executables, 'No Mach-O executables found'
    assert not list(app.rglob('_CodeSignature'))
    assert not list(app.rglob('embedded.mobileprovision'))
    bundles = [app, *app.glob('PlugIns/*.appex')]
    assert any(p.name == 'AetherTunnel.appex' for p in bundles), 'Missing tunnel extension'
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] == args.version, info
    package = stage / 'Aether.ipa'
    subprocess.run(['zip', '-q', '-r', '-y', str(package), 'Payload'], cwd=stage, check=True)
    subprocess.run(['unzip', '-tq', str(package)], check=True)
    shutil.copy2(package, args.output)
report = {'version': args.version, 'unsigned': True, 'executables': len(executables),
          'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}
args.output.with_suffix('.verification.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
