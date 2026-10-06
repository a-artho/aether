import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
def archive(name, entries):
    with zipfile.ZipFile(root / (name + '.ipa'), 'w', zipfile.ZIP_DEFLATED) as z:
        for path, data in entries: z.writestr(path, data)
archive('valid', [('Payload/App.app/Info.plist', '<plist/>'), ('Payload/App.app/Frameworks/Test.framework/Test', 'executable'), ('Payload/App.app/PlugIns/Test.appex/Info.plist', 'extension'), ('Payload/App.app/空 白%20.txt', 'unicode')])
archive('dot-prefix', [('./Payload/App.app/Info.plist', 'valid')])
archive('too-many', [(f'Payload/App.app/{n}', '') for n in range(20001)])
with zipfile.ZipFile(root/'symlink.ipa','w') as z:
    info=zipfile.ZipInfo('Payload/link'); info.create_system=3; info.external_attr=(0o120777 << 16)
    z.writestr(info, '../escaped.txt')
