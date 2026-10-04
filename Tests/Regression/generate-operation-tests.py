"""Copy production operations into controlled dependency scopes for regression tests."""
import pathlib,sys
repo=pathlib.Path(__file__).resolve().parents[2]; out=pathlib.Path(sys.argv[1])
def method(path,start):
 s=(repo/path).read_text(); p=s.index(start); b=s.index('{',p); n=1; e=b+1
 while n: n+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[p:e]
def scoped(body): return body.replace('Bundle.main.url(forResource:', 'FixtureBundle.main.url(forResource:')
parts=[r'''
import Foundation
import XCTest
@testable import Core
// Platform dependencies are controlled; the operation bodies below are copied from production.
@MainActor enum StorageFixture {
 protocol AppInfoPresentable { var uuid:String? { get }; var isSigned:Bool { get } }
 class NSManagedObject {}
 final class App:NSManagedObject,AppInfoPresentable { let uuid:String?="fixture"; let isSigned=true }
 final class Context { var deleted=false; func delete(_ app:NSManagedObject) { deleted=true } }
 final class AppInstallationManager {
  struct InstallationRequest { let appKey:String; static func appKey(for app:AppInfoPresentable)->String { app.uuid ?? "" } }
  static let shared=AppInstallationManager(); var currentRequest:InstallationRequest?; var queuedInstalls:[InstallationRequest]=[]; var retiringAppKey:String?
  var queued:Bool { get { currentRequest != nil } set { currentRequest = newValue ? .init(appKey:"fixture") : nil } }
''' ,method(pathlib.Path('Aether/Backend/Observable/AppInstallationManager.swift'),'func containsInstallation(for'),r'''
 }
 final class DownloadManager { static let shared=DownloadManager(); var active=false; func usesLibraryArtifact(_ app:AppInfoPresentable)->Bool { active } }
 final class DebugLogManager { enum Level { case notice }; static let shared=DebugLogManager(); func log(_ message:String,category:String,level:Level) {} }
 final class Storage {
  let context=Context(); var folder:URL!
  func getUuidDirectory(for app:AppInfoPresentable)->URL? { folder }
  func deleteSourceMetadata(for uuid:String?) {}; func saveContext() {}
''',method(pathlib.Path('Aether/Backend/Storage/Storage+Shared.swift'),'func deleteApp('),r'''
 }
}
extension FileManager {
 func removeFileIfNeeded(at url:URL) throws { if fileExists(atPath:url.path) { try removeItem(at:url) } }
}
enum InjectionFixture {
 struct InjectionFailure:LocalizedError { let file:String; var errorDescription:String? { file } }
 struct Options {
  enum Folder:String { case root="/", frameworks="/Frameworks/" }
  enum Path:String { case rpath="@rpath", executable="@executable_path" }
  var injectFolder:Folder = .root; var injectPath:Path = .executable
 }
 struct TestBundle {
  let executableURL:URL?
  init?(url:URL) { executableURL=url.appendingPathComponent("Main") }
 }
 enum Zsign { static var accepts=true; static func changeDylibPath(appExecutable:String,for:String,with:String)->Bool { true }; static func injectDyLib(appExecutable:String,with:String)->Bool { accepts } }
 struct Log { func info(_ message:String) {}; func warning(_ message:String) {} }
 enum Logger { static let misc=Log() }
 final class Tweak {
  let _fileManager=FileManager.default; var _injectedDylibNames:[String]=[]
  let _app:URL; var _options=Options()
  init(_ app:URL) { _app=app }
  func inject(_ file:URL) async throws { try await _handleDylib(at:file) }
  func injectFramework(_ file:URL) async throws { try await _handleDylib(framework:file) }
  func injectExtension(_ file:URL) throws { try _injectIntoExtension(extensionURL:file,dylibName:"test.dylib") }
''']
for start in ['private func _handleDylib(at','private func _handleDylib(framework:','private func _injectIntoExtension(']:
 parts.append(method(pathlib.Path('Aether/Utilities/Handlers/TweakHandler.swift'),start).replace('Bundle(url:', 'TestBundle(url:'))
parts.append(r'''
 }
}
@MainActor enum CertificateFixture {
 static let flag="aether.didImportDefaultCertificates.v2"
 final class FixtureBundle {
  static let main=FixtureBundle(); var assets:URL?
  func url(forResource:String,withExtension:String?)->URL? { assets }
 }
 struct Cert { let isDefault=true; let password:String; let key:URL; let provision:URL }
 final class Storage {
  enum FileKind { case certificate, provision }
  static let shared=Storage(); var certificates:[Cert]=[]
  func getAllCertificates()->[Cert] { certificates }
  func getFile(_ type:FileKind,from cert:Cert)->URL? { type == .certificate ? cert.key : cert.provision }
 }
 final class DebugLogManager {
  enum Level { case error }; static let shared=DebugLogManager(); var errors=0
  func log(_ message:String,category:String,level:Level) { errors+=1 }
 }
 enum FR {
  static var pending:[(String,()->Void,(Error?)->Void)]=[]
  static func handleCertificateFiles(p12URL:URL,provisionURL:URL,p12Password:String,certificateName:String,isDefault:Bool,completion:@escaping (Error?)->Void) {
   pending.append((certificateName,{ Storage.shared.certificates.append(Cert(password:p12Password,key:p12URL,provision:provisionURL)) },completion))
  }
  static func finish(success:Bool) {
   let request=pending.removeFirst(); if success { request.1(); request.2(nil) } else { request.2(NSError(domain:"Fixture",code:1)) }
  }
 }
 final class Delegate {
  func start() { _addDefaultCertificates() }
''')
parts.append(scoped(method(pathlib.Path('Aether/AetherApp.swift'),'private func _addDefaultCertificates()')))
parts.append(r'''
 }
}
final class OperationRegressionTests:XCTestCase {
 func folder() throws -> URL {
  let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
  addTeardownBlock { try? FileManager.default.removeItem(at:path) }; return path
 }
 @MainActor func testDeletionRetainsQueuedAndActiveUpdateFilesIncludingRollback() throws {
  let storage=StorageFixture.Storage(),app=StorageFixture.App()
  storage.folder=try folder(); let data=storage.folder.appendingPathComponent("app")
  try Data("owned".utf8).write(to:data)
  StorageFixture.AppInstallationManager.shared.queued=true
  XCTAssertFalse(storage.deleteApp(for:app)); XCTAssertFalse(storage.context.deleted)
  XCTAssertFalse(storage.deleteApp(for:app,ownedSigningTransaction:true)); XCTAssertTrue(FileManager.default.fileExists(atPath:data.path))
  StorageFixture.AppInstallationManager.shared.queued=false; StorageFixture.AppInstallationManager.shared.retiringAppKey="fixture"
  XCTAssertFalse(storage.deleteApp(for:app)); XCTAssertTrue(FileManager.default.fileExists(atPath:data.path))
  StorageFixture.AppInstallationManager.shared.retiringAppKey=nil; StorageFixture.DownloadManager.shared.active=true
  XCTAssertFalse(storage.deleteApp(for:app)); XCTAssertTrue(FileManager.default.fileExists(atPath:data.path))
  StorageFixture.DownloadManager.shared.active=false
  XCTAssertTrue(storage.deleteApp(for:app)); XCTAssertTrue(storage.context.deleted); XCTAssertFalse(FileManager.default.fileExists(atPath:data.path))
 }
 func testInjectionFailurePropagatesAndInputCanBeRetried() async throws {
  let root=try folder(),app=root.appendingPathComponent("App.app"),source=root.appendingPathComponent("test.dylib")
  try FileManager.default.createDirectory(at:app,withIntermediateDirectories:false)
  try Data("tweak".utf8).write(to:source)
  let handler=InjectionFixture.Tweak(app)
  InjectionFixture.Zsign.accepts=false
  do { try await handler.inject(source); XCTFail("Injection failure was ignored") } catch {}
  XCTAssertTrue(handler._injectedDylibNames.isEmpty); XCTAssertEqual(try Data(contentsOf:source),Data("tweak".utf8))
  do { try await handler.injectFramework(app); XCTFail("Framework injection failure was ignored") } catch {}
  XCTAssertThrowsError(try handler.injectExtension(app))
  InjectionFixture.Zsign.accepts=true; try await handler.inject(source)
  XCTAssertEqual(handler._injectedDylibNames,["test.dylib"]); XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
  try await handler.injectFramework(app); try handler.injectExtension(app)
 }
 @MainActor func testCertificateMigrationWaitsRetriesAndAvoidsDuplicates() async throws {
  let root=try folder()
  for name in ["A","B"] {
   let folder=root.appendingPathComponent(name,isDirectory:true)
   try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   for file in ["cert.p12","cert.mobileprovision","cert.txt"] { try Data((name+file).utf8).write(to:folder.appendingPathComponent(file)) }
  }
  CertificateFixture.FixtureBundle.main.assets=root; CertificateFixture.Storage.shared.certificates=[]
  CertificateFixture.DebugLogManager.shared.errors=0
  UserDefaults.standard.removeObject(forKey:CertificateFixture.flag)
  // Older builds could have marked migration complete before either import.
  UserDefaults.standard.set(true,forKey:"aether.didImportDefaultCertificates")
  let delegate=CertificateFixture.Delegate(); delegate.start()
  while CertificateFixture.FR.pending.isEmpty { await Task.yield() }
  XCTAssertFalse(UserDefaults.standard.bool(forKey:CertificateFixture.flag))
  CertificateFixture.FR.finish(success:true)
  while CertificateFixture.FR.pending.isEmpty { await Task.yield() }
  XCTAssertFalse(UserDefaults.standard.bool(forKey:CertificateFixture.flag))
  CertificateFixture.FR.finish(success:false)
  while CertificateFixture.DebugLogManager.shared.errors==0 { await Task.yield() }
  XCTAssertFalse(UserDefaults.standard.bool(forKey:CertificateFixture.flag)); XCTAssertEqual(CertificateFixture.Storage.shared.certificates.count,1)
  delegate.start()
  while CertificateFixture.FR.pending.isEmpty { await Task.yield() }
  CertificateFixture.FR.finish(success:true)
  while !UserDefaults.standard.bool(forKey:CertificateFixture.flag) { await Task.yield() }
  XCTAssertEqual(CertificateFixture.Storage.shared.certificates.count,2)
  delegate.start(); for _ in 0..<20 { await Task.yield() }
  XCTAssertTrue(CertificateFixture.FR.pending.isEmpty)
  UserDefaults.standard.removeObject(forKey:CertificateFixture.flag); UserDefaults.standard.removeObject(forKey:"aether.didImportDefaultCertificates")
 }
}
''')

parts.append(r"""
enum LaunchFixture {
 typealias AppServiceHandle=OpaquePointer
 struct LaunchResponseC {}
 struct IDeviceSwiftError:Error { init(_ error:Bool) {}; init(message:String) {} }
 enum IDeviceConnectionError:Error { case appServiceConnectionFailed(String) }
 final class HeartbeatManager:@unchecked Sendable {
  static let shared=HeartbeatManager(); var isRsd=true; var fails=true
  static func hasPairingFile()->Bool { true }
  func withRSDServiceConnection(_ action:(OpaquePointer?,OpaquePointer?)->Bool?) throws {
   if fails { throw IDeviceSwiftError(message:"Unavailable") }; _=action(nil,nil)
  }
 }
 static func app_service_connect_rsd(_ adapter:OpaquePointer?,_ handshake:OpaquePointer?,_ app:inout OpaquePointer?)->Bool? { app=OpaquePointer(bitPattern:1); return nil }
 static func app_service_free(_ app:OpaquePointer) {}
 static func app_service_launch_app(_ app:OpaquePointer,_ id:UnsafePointer<CChar>,_ arg:OpaquePointer?,_ a:Int,_ b:Int,_ c:Int,_ x:OpaquePointer?,_ response:inout UnsafeMutablePointer<LaunchResponseC>?)->Bool? { nil }
 static func app_service_free_launch_response(_ response:UnsafeMutablePointer<LaunchResponseC>) {}
 final class UIApplication {
  static let shared=UIApplication(); var opened:[URL]=[]; var accepts=true
  func canOpenURL(_ url:URL)->Bool { true }
  func open(_ url:URL,options:[String:String],completionHandler:(Bool)->Void) { opened.append(url); completionHandler(accepts) }
 }
""")
parts.append(method(pathlib.Path('IDeviceKitten/Sources/IDeviceSwift/Lifecycle/AppLifecycleService.swift'),'public static func launchApp('))
parts.append(r"""
}
final class LaunchRegressionTests:XCTestCase {
 func testTransportFailureFallsBackButSuccessfulTransportDoesNot() async throws {
  LaunchFixture.HeartbeatManager.shared.fails=true
  LaunchFixture.UIApplication.shared.opened=[]; LaunchFixture.UIApplication.shared.accepts=true
  let result=try await LaunchFixture.launchApp(bundleIdentifier:"fixture",urlSchemes:["example"])
  XCTAssertTrue(result); XCTAssertEqual(LaunchFixture.UIApplication.shared.opened.map(\.scheme),["example"])
  LaunchFixture.HeartbeatManager.shared.fails=false; LaunchFixture.UIApplication.shared.opened=[]
  let native=try await LaunchFixture.launchApp(bundleIdentifier:"fixture",urlSchemes:["example"])
  XCTAssertTrue(native); XCTAssertTrue(LaunchFixture.UIApplication.shared.opened.isEmpty)
  LaunchFixture.HeartbeatManager.shared.fails=true; LaunchFixture.UIApplication.shared.accepts=false
  do { _=try await LaunchFixture.launchApp(bundleIdentifier:"fixture",urlSchemes:["example"]); XCTFail("Both paths failed") } catch {}
 }
}
""")

parts.append(r"""
extension String { static func localized(_ value:String)->String { value } }
enum TLSFixture {
 struct Pool { init(numberOfThreads:Int) {} }
 struct Configuration {
  enum Address { case hostname(String,port:Int) }
  var tlsConfiguration:Int?; var hostname=""; var tcpNoDelay=false; var address:Address = .hostname("",port:0); var port=0
 }
 final class HTTP { let server=HTTPServer() }; final class HTTPServer { var configuration=Configuration() }
 final class Routes { var defaultMaxBodySize=""; var caseInsensitive=false }
 final class Application {
  static var shutdowns=0
  var threadPool=Pool(numberOfThreads:1); let http=HTTP(); let routes=Routes()
  init(_ env:Int) {}; func shutdown() { Self.shutdowns+=1 }
 }
 final class Server {
  static let env=1; let serverMethod:Int; let commonName:String?; let certificate:Int?; var parseFails=false
  init(_ method:Int,_ name:String?,_ certificate:Int?) { serverMethod=method; commonName=name; self.certificate=certificate }
  func tls() throws -> Int? { if parseFails { throw NSError(domain:"Parse",code:1) }; return certificate }
  func readCommonName()->String? { commonName }; func sni()->String { commonName ?? "127.0.0.1" }
""")
parts.append(method(pathlib.Path('Aether/Backend/Server/ServerInstaller.swift'),'func getServerMethod()'))
parts.append(method(pathlib.Path('Aether/Backend/Server/ServerInstaller+TLS.swift'),'func setupApp(port:'))
parts.append(r"""
 }
}
final class TLSRegressionTests:XCTestCase {
 func testFullyLocalFailsClosedAndSemiLocalPreservesHTTP() throws {
  for fixture in [(nil as String?,nil as Int?), ("local.test",nil), ("",1)] {
   TLSFixture.Application.shutdowns=0
   XCTAssertThrowsError(try TLSFixture.Server(0,fixture.0,fixture.1).setupApp(port:1234))
   XCTAssertEqual(TLSFixture.Application.shutdowns,1)
  }
  TLSFixture.Application.shutdowns=0
  let parse=TLSFixture.Server(0,"local.test",1); parse.parseFails=true
  XCTAssertThrowsError(try parse.setupApp(port:1234)); XCTAssertEqual(TLSFixture.Application.shutdowns,1)
  let secure=try TLSFixture.Server(0,"local.test",1).setupApp(port:1234)
  XCTAssertEqual(secure.http.server.configuration.tlsConfiguration,1)
  XCTAssertEqual(secure.http.server.configuration.port,1234); secure.shutdown()
  let plain=try TLSFixture.Server(1,nil,nil).setupApp(port:1234)
  XCTAssertNil(plain.http.server.configuration.tlsConfiguration); plain.shutdown()
 }
}
""")

parts.append(r"""
@MainActor enum DownloadDeletionFixture {
 final class Download { let id="fixture"; var task:Task<Void,Never>?; let importIdentifier="import-fixture"; var backgroundTaskTransferred=false }
 final class DownloadActivityManager { enum Status { case cancelled }; static let shared=DownloadActivityManager(); func finish(_ download:Download,status:Status) {} }
 enum AppFileHandler { static var removed:[String]=[]; static func removeImportTransaction(transactionIdentifier:String) async { removed.append(transactionIdentifier) } }
 struct Store { func cleanupArtifacts(for download:Download) {} }
 final class Manager {
  var downloads:[Download]=[]; var _processingTasks:[String:Task<Void,Never>]=[:]; let _store=Store(); var stopped=0
  func _isCurrent(_ download:Download)->Bool { downloads.contains { $0 === download } }
  func _stopContinuedTask(for download:Download,success:Bool) { stopped+=1 }
  func _persistDownloads() {}; func _releaseIdleBackgroundTunnel() {}
""")
parts.append(method(pathlib.Path('Aether/Backend/Observable/DownloadManager.swift'),'func deleteDownload('))
parts.append(r"""
 }
}
final class DownloadDeletionRegressionTests:XCTestCase {
 @MainActor func testDeletionWaitsForWorkerAndPreservesTransferredLease() async {
  for transferred in [false,true] {
   let manager=DownloadDeletionFixture.Manager(),download=DownloadDeletionFixture.Download(),gate=Gate()
   DownloadDeletionFixture.AppFileHandler.removed=[]
   download.backgroundTaskTransferred=transferred; manager.downloads=[download]
   let worker=Task { _=await gate.wait() }
   while gate.count==0 { await Task.yield() }
   manager._processingTasks[download.id]=worker
   manager.deleteDownload(download)
   XCTAssertTrue(worker.isCancelled); XCTAssertTrue(manager.downloads.isEmpty)
   XCTAssertEqual(manager.stopped,transferred ? 0 : 1)
   for _ in 0..<20 { await Task.yield() }
   XCTAssertTrue(DownloadDeletionFixture.AppFileHandler.removed.isEmpty)
   gate.release(1); await worker.value
   while DownloadDeletionFixture.AppFileHandler.removed.isEmpty { await Task.yield() }
   XCTAssertEqual(DownloadDeletionFixture.AppFileHandler.removed,[download.importIdentifier])
  }
 }
}
""")
(out/'OperationRegressionTests.swift').write_text('\n'.join(parts))
