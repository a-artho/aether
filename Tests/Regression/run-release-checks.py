#!/usr/bin/env python3
"""Run focused release regressions against production code using macOS tools."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
def declaration(path, start):
    source = (repo / path).read_text()
    begin = source.index(start); brace = source.index('{', begin); end = brace + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[begin:end]
with tempfile.TemporaryDirectory(prefix='aether-release-tests-') as temp:
    root = pathlib.Path(temp)
    source = (repo/'AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift').read_text().replace('import SwiftUI', 'public struct Color: Codable, Hashable, Sendable {}')
    source += (repo/'AltSourceKit/Sources/AltSourceKit/Extensions/Array/Array+safe.swift').read_text()
    source += (repo/'AltSourceKit/Sources/AltSourceKit/Utilities/ASDecrypt.swift').read_text()
    source += (repo/'AltSourceKit/Sources/AltSourceKit/Utilities/Key/EsignSourceKey.swift').read_text()
    source += '\nimport CoreData\nimport CoreLocation\n'
    source += 'enum Level { case warning, error, debug }; final class DebugLogManager { static let shared = DebugLogManager(); func log(_ s: String, category: String, level: Level) {} }\n'
    source += 'final class StorageProbe { let context: NSManagedObjectContext; init(_ c: NSManagedObjectContext) {context = c}\n'
    source += declaration('Aether/Backend/Storage/Storage.swift', 'func clearContext<T:') + '\n}\n'
    source += declaration('Aether/Views/Spoofing/Engine/SpoofSession.swift', 'private func offset(').replace('private func', 'func', 1) + '\n'
    certificate = (repo/'Aether/Backend/Storage/Storage+Certificate.swift').read_text()
    condition = certificate.split('guard !cert.isDeleted, ')[1].split(' else {')[0]
    source += 'func acceptsRevocation(_ cert: NSManagedObject, context: NSManagedObjectContext) -> Bool { return !cert.isDeleted && ' + condition.replace('self.context', 'context') + ' }\n'
    callback = declaration('Aether/Backend/Observable/CellularAssistManager.swift', 'public func handleCallback(')
    block = callback[callback.index('guard let components'):callback.index('guard let rawID')]
    source += 'final class CallbackProbe { var values: [String:String]?; func _log(_ s: String, level: Level) {}\nfunc handle(_ url: URL) {\n' + block + 'self.values = values\n}\n}\n'
    packet = (repo/'AetherTunnel/PacketTunnelProvider.swift').read_text()
    begin = packet.index('// IPv4 addresses')
    finish = packet.index('\n\t\t\t\t}', begin)
    swap = packet[begin:finish]
    source += 'func swapAddresses(_ rawBuffer: UnsafeMutableRawBufferPointer) {\n' + swap + '\n}\n'
    tls = (repo/'Aether/Backend/Server/ServerInstaller+TLS.swift').read_text()
    begin = tls.index('let candidate = String(cString: hostname)')
    end = tls.index('\n\t\t\t\t\t\t\t}', begin)
    selection = tls[begin:end].replace('String(cString: hostname)', 'entry.1')
    source += 'func chooseAddress(_ entries: [(String,String)]) -> String? { var address: String?; for entry in entries { let name = entry.0;\n' + selection + '\n}; return address }\n'
    source += r'''
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
let decoder = JSONDecoder()
for artwork in ["", ",\"iconURL\":null", ",\"iconURL\":42", ",\"iconURL\":\"https://example.com/icon.png\""] {
 let json = "{\"name\":\"Fixture\",\"apps\":[{\"name\":\"App\",\"bundleIdentifier\":\"test.app\"" + artwork + "}]}"
 let repo = try decoder.decode(ASRepository.self, from: Data(json.utf8))
 check(repo.apps.count == 1, "Missing/malformed artwork must not reject catalog")
 if artwork.contains("https") { check(repo.apps[0].iconURL != nil, "Valid icon preserved") }
 else { check(repo.apps[0].iconURL == nil, "Optional icon fallback") }
}
let encrypted = ASDecrypt(input: "source[QQ==]")
check(encrypted.decrypt(key: [], keyLength: 0) == nil, "Empty key")
check(encrypted.decrypt(key: [0], keyLength: 2) == nil, "Oversized key length")
check(encrypted.decrypt(key: [0], keyLength: -1) == nil, "Negative length")
check(encrypted.decrypt(key: [0], keyLength: 1) == ["A"], "Valid decrypt unchanged")
let callback = CallbackProbe()
callback.handle(URL(string:"aether://cellular-assist?status=success&status=cancel")!)
check(callback.values == nil, "Ambiguous callback rejected")
callback.handle(URL(string:"aether://cellular-assist?status=success&phase=off")!)
check(callback.values?["status"] == "success", "Valid callback retained")
check(chooseAddress([("pdp_ip0","cell"),("en0","wifi")]) == "wifi", "Wi-Fi enumerated second")
check(chooseAddress([("en0","wifi"),("pdp_ip0","cell")]) == "wifi", "Wi-Fi enumerated first")
check(chooseAddress([("pdp_ip0","cell")]) == "cell", "Cellular fallback retained")
let mem = UnsafeMutableRawPointer.allocate(byteCount: 25, alignment: 1)
defer {mem.deallocate()}
let bytes = UnsafeMutableRawBufferPointer(start: mem.advanced(by: 1), count: 20)
for i in bytes.indices { bytes[i] = UInt8(i) }
swapAddresses(bytes)
check(Array(bytes[12..<16]) == [16,17,18,19] && Array(bytes[16..<20]) == [12,13,14,15], "Unaligned network addresses swapped")
check(bytes[11] == 11 && bytes[19] == 15, "Packet boundaries preserved")
for lat in [-90.0, -89.99999, 0, 89.99999, 90] {
 for lon in [-180.0, 179.99999, 180] {
  let next = offset(coordinate: .init(latitude:lat, longitude:lon), eastMeters:20, northMeters:20)
  check(CLLocationCoordinate2DIsValid(next), "Coordinates remain valid at poles and date line")
 }
}
let ordinary = offset(coordinate: .init(latitude:0,longitude:0), eastMeters:10,northMeters:0)
let distance = CLLocation(latitude:0,longitude:0).distance(from: CLLocation(latitude:ordinary.latitude,longitude:ordinary.longitude))
check(abs(distance - 10) < 0.1, "Ordinary joystick movement remains ten meters")
let model = NSManagedObjectModel(), entity = NSEntityDescription(), attr = NSAttributeDescription()
entity.name = "Item"; entity.managedObjectClassName = "NSManagedObject"
attr.name = "name"; attr.attributeType = .stringAttributeType; entity.properties = [attr]; model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel:model)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:directory)}
try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("store.sqlite"))
let context = NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
let object = NSManagedObject(entity:entity,insertInto:context); object.setValue("Cached",forKey:"name"); try context.save()
let request = NSFetchRequest<NSManagedObject>(entityName:"Item")
check(acceptsRevocation(object, context:context), "Existing certificate accepts callback")
let otherContext = NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType)
check(!acceptsRevocation(object, context:otherContext), "Different context rejected")
StorageProbe(context).clearContext(request:request)
check(!acceptsRevocation(object, context:context), "Deleted certificate callback rejected")
check(try context.count(for:request) == 0, "Persistent objects deleted")
check(object.isDeleted || object.managedObjectContext == nil, "Context notified of batch deletion")
print("Release Swift checks passed")
'''
    # A throwing count expression cannot be captured by the nonthrowing test autoclosure.
    source = source.replace('check(try context.count(for:request) == 0,', 'let count = try context.count(for:request)\ncheck(count == 0,')
    (root/'checks.swift').write_text(source)
    subprocess.run(['swift', str(root/'checks.swift')], check=True)
    driver = r'''
#import "MachOUtils.h"
int main(int argc, char **argv) { @autoreleasepool {
 NSString *result = strcmp(argv[1], "sdk") == 0 ? LCPatchMachOForSDK26(argv[2]) : LCPatchMachOFixupARM64eSlice(argv[2]);
 puts(result ? result.UTF8String : "OK"); return 0;
} }
'''
    (root/'driver.m').write_text(driver)
    macho = repo/'Aether/Utilities/MachO'
    subprocess.run(['xcrun','clang','-fmodules','-fobjc-arc','-framework','Foundation','-I',str(macho),str(macho/'MachOUtils.m'),str(root/'driver.m'),'-o',str(root/'patcher')], check=True)
    import struct
    def header(ncmds=1, size=24, subtype=0):
        return struct.pack('<8I',0xfeedfacf,0x0100000c,subtype,2,ncmds,size,0,0)
    command = struct.pack('<6I',0x32,24,2,0,0x190000,0)
    def invoke(data, mode='sdk'):
        path = root/'fixture.bin'; path.write_bytes(data)
        result = subprocess.check_output([str(root/'patcher'),mode,str(path)],text=True)
        return result, path.read_bytes()
    result, patched = invoke(header()+command)
    assert 'Patched' in result and struct.unpack_from('<I',patched,48)[0] == 0x1a0000
    late = header(2,32)+command+struct.pack('<2I',0x1,0)
    result, after = invoke(late); assert after == late, 'Early SDK command patched before later validation'
    invalid = [b'', b'\xca', header(size=8)+struct.pack('<2I',0x32,0), header(size=8)+struct.pack('<2I',0x32,8), struct.pack('>2I',0xcafebabe,0xffffffff)]
    for fixture in invalid:
        for mode in ('sdk','arm'):
            result, after = invoke(fixture, mode)
            assert after == fixture, 'Malformed file changed'
    for wide in (False,True):
        fat = struct.pack('>2I',0xcafebabf if wide else 0xcafebabe,1)
        arch = struct.pack('>2I2Q2I',0x0100000c,2,4096,32,0,0) if wide else struct.pack('>5I',0x0100000c,2,4096,32,0)
        fixture = fat+arch
        fixture += b'\0'*(4096-len(fixture))+header(0,0,2)
        result, patched = invoke(fixture,'arm')
        assert result.strip() == 'OK' and struct.unpack_from('<I',patched,4104)[0] == 0x80000002
        broken = fat+(struct.pack('>2I2Q2I',0x0100000c,2,999999,32,0,0) if wide else struct.pack('>5I',0x0100000c,2,999999,32,0))
        result, after = invoke(broken,'arm'); assert after == broken and result.strip() != 'OK'
    print('Mach-O release checks passed')
