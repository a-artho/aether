import pathlib, struct, sys, zipfile
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
def archive(name, entries):
    with zipfile.ZipFile(root / (name + '.ipa'), 'w', zipfile.ZIP_DEFLATED) as z:
        for path, data in entries: z.writestr(path, data)
archive('valid', [('Payload/App.app/Info.plist', '<plist/>'), ('Payload/App.app/Frameworks/Test.framework/Test', 'executable'), ('Payload/App.app/PlugIns/Test.appex/Info.plist', 'extension'), ('Payload/App.app/空 白%20.txt', 'unicode')])
archive('dot-prefix', [('./Payload/App.app/Info.plist', 'valid')])
for name, path in [('traversal','../escaped.txt'), ('backslash','..\\escaped.txt'), ('absolute','/tmp/escaped.txt'), ('drive','C:/escaped.txt'), ('nested','Payload/../../escaped.txt')]:
    archive(name, [('Payload/App.app/Info.plist','valid'), (path,'bad')])
archive('duplicate', [('Payload/App.app/File','a'), ('Payload/App.app/File','b')])
archive('case-distinct', [('Payload/App.app/File','a'), ('Payload/App.app/file','b')])
archive('parent-conflict', [('Payload/App.app','file'), ('Payload/App.app/Info.plist','child')])
archive('too-many', [(f'Payload/App.app/{n}', '') for n in range(20001)])
archive('symlink', [(zipfile.ZipInfo('Payload/link'), '../escaped.txt')])
with zipfile.ZipFile(root/'symlink.ipa','w') as z:
    info=zipfile.ZipInfo('Payload/link'); info.create_system=3; info.external_attr=(0o120777 << 16)
    z.writestr(info, '../escaped.txt')
archive('crc', [('Payload/App.app/Info.plist','checksum')])
data=bytearray((root/'crc.ipa').read_bytes()); c=data.index(b'PK\x01\x02'); struct.pack_into('<I',data,c+16,0x12345678); (root/'crc.ipa').write_bytes(data)
archive('oversize', [('Payload/App.app/Info.plist','small')])
data=bytearray((root/'oversize.ipa').read_bytes()); c=data.index(b'PK\x01\x02'); struct.pack_into('<I',data,c+24,0xfffffffe)
# Five entries each claiming almost 4 GiB exceed the aggregate ceiling.
archive('oversize', [(f'Payload/App.app/{n}','small') for n in range(5)])
data=bytearray((root/'oversize.ipa').read_bytes()); cursor=0
while True:
    try: c=data.index(b'PK\x01\x02', cursor)
    except ValueError: break
    struct.pack_into('<I',data,c+24,0xfffffffe); cursor=c+4
(root/'oversize.ipa').write_bytes(data)
(root/'truncated.ipa').write_bytes((root/'valid.ipa').read_bytes()[:-30])

for name in ['encrypted-tail','invalid-local-tail']:
    archive(name, [('Payload/App.app/Info.plist','valid'), ('Payload/App.app/resource','trailing')])
    data=bytearray((root/(name+'.ipa')).read_bytes())
    first=data.index(b'PK\x03\x04'); local=data.index(b'PK\x03\x04',first+4)
    first=data.index(b'PK\x01\x02'); central=data.index(b'PK\x01\x02',first+4)
    if name == 'encrypted-tail':
        for offset in [local+6,central+8]:
            flags=struct.unpack_from('<H',data,offset)[0]; struct.pack_into('<H',data,offset,flags|1)
    else: data[local:local+4]=b'BAD!'
    (root/(name+'.ipa')).write_bytes(data)

# Explicit ZIP64 footer with small valid entries (ZIP64 is not just large files).
data=bytearray((root/'valid.ipa').read_bytes()); e=data.rindex(b'PK\x05\x06')
count=struct.unpack_from('<H',data,e+10)[0]; size,offset=struct.unpack_from('<II',data,e+12)
record=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,count,count,size,offset)
locator=struct.pack('<IIQI',0x07064b50,0,e,1)
struct.pack_into('<HHII',data,e+8,0xffff,0xffff,0xffffffff,0xffffffff)
(root/'zip64.ipa').write_bytes(data[:e]+record+locator+data[e:])
