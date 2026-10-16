"""Exercise production icon caching and client reuse with deterministic native doubles."""
import pathlib,sys
repo=pathlib.Path(__file__).resolve().parents[2]
source=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift').read_text()
source=source[source.index('extension InstallationAppProxy {\n\tprivate static let iconCache'):]
for old,new in [('InstallationAppProxy','IconProxy'),('HeartbeatManager','IconHeartbeat'),('UIImage','IconImage'),('UIApplication','IconApplication'),('IDeviceConnectionError','IconConnectionError'),('IDeviceSwiftError','IconError')]:
 source=source.replace(old,new)
start=source.index('private let directory = ');end=source.index('\n\tprivate var identityStamp',start)
source=source[:start]+'private let directory = iconTestDirectory'+source[end:]
head=r'''
import Foundation
import CryptoKit
import XCTest
private let iconTestDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("icon-tests-"+UUID().uuidString)
private final class IconImage:NSObject {
 struct Pixels { let bytesPerRow=4; let height=1 }
 var cgImage:Pixels? { Pixels() }
 init?(data:Data) { if data.isEmpty { return nil }; super.init() }
 func preparingThumbnail(of size:CGSize)->IconImage? { self }
}
private enum IconApplication { static let didEnterBackgroundNotification=Notification.Name("IconTestBackground"); static let didReceiveMemoryWarningNotification=Notification.Name("IconTestMemory") }
private final class IconProxy {}
private enum IconConnectionError:Error { case tcpProviderUnavailable }
private struct IconError:Error { init(_ pointer:UnsafeMutablePointer<Int>) { pointer.deallocate() }; init(message:String) {} }
private final class IconHeartbeat {
 static let shared=IconHeartbeat()
 static var pairingPath=""
 static func activePairingFile() -> String { pairingPath }
 var ipAddress="10.7.0.1"; var isRsd=true; var rsdGeneration:UInt64=0
 var serviceConnectionGeneration:UInt64 { rsdGeneration }
 var provider:OpaquePointer? { OpaquePointer(bitPattern:1) }
 func withRSDServiceConnection(_ connect:(OpaquePointer,OpaquePointer)->UnsafeMutablePointer<Int>?) throws {
  if let error=connect(OpaquePointer(bitPattern:1)!,OpaquePointer(bitPattern:2)!) { throw IconError(error) }
 }
}
private enum IconNative { static var opened=0; static var freed=0; static var fetched=0; static var fail=false }
private func springboard_services_connect_rsd(_ a:OpaquePointer,_ h:OpaquePointer,_ client:inout OpaquePointer?) -> UnsafeMutablePointer<Int>? {
 IconNative.opened += 1; client=OpaquePointer(UnsafeMutableRawPointer.allocate(byteCount:8,alignment:8)); return nil
}
private func springboard_services_connect(_ p:OpaquePointer,_ client:inout OpaquePointer?) -> UnsafeMutablePointer<Int>? { springboard_services_connect_rsd(p,p,&client) }
private func springboard_services_get_icon(_ client:OpaquePointer?,_ id:String,_ bytes:inout UnsafeMutableRawPointer?,_ length:inout Int) -> UnsafeMutablePointer<Int>? {
 IconNative.fetched += 1
 if IconNative.fail { IconNative.fail=false; let error=UnsafeMutablePointer<Int>.allocate(capacity:1);error.initialize(to:1);return error }
 length=4;bytes=UnsafeMutableRawPointer.allocate(byteCount:4,alignment:1);bytes!.initializeMemory(as:UInt8.self,repeating:1,count:4);return nil
}
private func springboard_services_free(_ client:OpaquePointer) { IconNative.freed += 1;UnsafeMutableRawPointer(client).deallocate() }
private func idevice_data_free(_ bytes:UnsafeMutablePointer<UInt8>,_ length:UInt) { bytes.deallocate() }
'''
tests=r'''
final class IconOptimizationTests:XCTestCase {
 func testReuseResetFailureAndIdleRelease() async throws {
  let opened=IconNative.opened, freed=IconNative.freed
  let connection=InstalledIconConnection()
  _=try await connection.iconData(for:"first",scope:"device")
  _=try await connection.iconData(for:"second",scope:"device")
  XCTAssertEqual(IconNative.opened,opened+1)
  IconHeartbeat.shared.rsdGeneration += 1
  _=try await connection.iconData(for:"third",scope:"device")
  XCTAssertEqual(IconNative.opened,opened+2);XCTAssertEqual(IconNative.freed,freed+1)
  IconNative.fail=true
  do { _=try await connection.iconData(for:"failure",scope:"device");XCTFail("Expected failure") } catch {}
  XCTAssertEqual(IconNative.freed,freed+2)
  _=try await connection.iconData(for:"retry",scope:"device")
  XCTAssertEqual(IconNative.opened,opened+3)
  try await Task.sleep(nanoseconds:2_200_000_000)
  XCTAssertEqual(IconNative.freed,freed+3)
 }
 func testBackgroundReleasesTheIconConnection() async throws {
  let freed=IconNative.freed
  let connection=InstalledIconConnection()
  _=try await connection.iconData(for:"background",scope:"device")
  NotificationCenter.default.post(name:IconApplication.didEnterBackgroundNotification,object:nil)
  try await Task.sleep(nanoseconds:50_000_000)
  XCTAssertEqual(IconNative.freed,freed+1)
 }
 func testDiskCacheSurvivesInstanceAndSeparatesKeys() throws {
  defer { try? FileManager.default.removeItem(at:iconTestDirectory) }
  let first=InstalledIconDiskCache()
  first.store(Data([1,2,3]),for:"device|app|1")
  let reopened=InstalledIconDiskCache()
  XCTAssertNotNil(reopened.image(for:"device|app|1"))
  XCTAssertNil(reopened.image(for:"device|app|2"))
  XCTAssertNil(reopened.image(for:"other-device|app|1"))
  let files=try FileManager.default.contentsOfDirectory(at:iconTestDirectory,includingPropertiesForKeys:nil)
  try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-31*86400)],ofItemAtPath:files[0].path)
  XCTAssertNil(reopened.image(for:"device|app|1"))
 }
 func testFirstFrameMemoryLookupIsScopedAndDoesNotFetch() async throws {
  let id="memory-"+UUID().uuidString
  IconProxy.setIconDeviceScope(pairingDigest:Data([42]),endpoint:"test")
  let count=IconNative.fetched
  XCTAssertNil(IconProxy.appIconInMemory(for:id,cacheVersion:"1"))
  XCTAssertEqual(IconNative.fetched,count)
  let image=try await IconProxy.getAppIconCached(for:id,cacheVersion:"1")
  XCTAssertNotNil(image)
  XCTAssertTrue(IconProxy.appIconInMemory(for:id,cacheVersion:"1") === image)
  let after=IconNative.fetched
  XCTAssertNil(IconProxy.appIconInMemory(for:id,cacheVersion:"2"))
  IconProxy.invalidateAppIcon(for:id)
  XCTAssertNil(IconProxy.appIconInMemory(for:id,cacheVersion:"1"))
  IconProxy.setIconDeviceScope(pairingDigest:Data([43]),endpoint:"test")
  XCTAssertNil(IconProxy.appIconInMemory(for:id,cacheVersion:"1"))
  XCTAssertEqual(IconNative.fetched,after,"Memory misses must not trigger device work")
  IconProxy.setIconDeviceScope(pairingDigest:nil,endpoint:"test")
  XCTAssertNil(IconProxy.appIconInMemory(for:id,cacheVersion:"1"))
  UserDefaults.standard.removeObject(forKey:"InstalledIconRevision."+id)
  // Retire this test's shared icon connection before later tests count native closes.
  NotificationCenter.default.post(name:IconApplication.didEnterBackgroundNotification,object:nil)
  try await Task.sleep(nanoseconds:50_000_000)
 }
 func testPairingAndEndpointScopeAndInstallInvalidation() throws {
  let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:file) }
  try Data([1]).write(to:file);IconHeartbeat.pairingPath=file.path
  let disk=InstalledIconDiskCache(), original=disk.deviceScope()
  IconHeartbeat.shared.ipAddress="other";XCTAssertNotEqual(disk.deviceScope(),original)
  IconHeartbeat.shared.ipAddress="10.7.0.1"
  try Data([2,3]).write(to:file);XCTAssertNotEqual(disk.deviceScope(),original)
  let id="icon-test-"+UUID().uuidString
  defer { UserDefaults.standard.removeObject(forKey:"InstalledIconRevision."+id) }
  let revision=IconProxy.iconCacheRevision(for:id)
  IconProxy.invalidateAppIcon(for:id);XCTAssertNotEqual(IconProxy.iconCacheRevision(for:id),revision)
 }
}
'''
# The real NSData protection option is available only on iOS.
source=source.replace(', .completeFileProtectionUntilFirstUserAuthentication','')
pathlib.Path(sys.argv[1],'IconOptimizationTests.swift').write_text(head+source+tests)
