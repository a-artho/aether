"""Compile actual lifecycle methods against controlled transport/platform dependencies.
The methods under test are copied verbatim; substitutes control suspension and replies.
These checks do not claim to exercise device transports or UIKit presentation.
"""
import pathlib, sys
repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1])
def method(path, start):
    source = (repo/path).read_text()
    p = source.index(start); opening = source.index('{', p); depth = 1; end = opening+1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end += 1
    return source[p:end]
spoof = pathlib.Path('Aether/Views/Spoofing/Engine/SpoofSession.swift')
store = pathlib.Path('Aether/Views/Installed/InstalledAppsStore.swift')
cellular = pathlib.Path('Aether/Backend/Observable/CellularAssistManager.swift')
compute = pathlib.Path('Aether/Backend/Server/ServerInstaller+Compute.swift')
parts = [r'''
import Foundation
import XCTest
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
enum Status: Equatable { case idle, active, connecting, reconnecting, stopping, dropped(String)
 var isDropped: Bool { if case .dropped = self { return true }; return false }
}
struct Failure: Error { var localizedDescription: String { "failure" }; var mayHaveChangedLocation: Bool { false } }
enum Stage { case settingLocation; var label: String { "set" } }
@MainActor final class Gate {
 var pending: [Int: CheckedContinuation<Bool,Never>] = [:]; var count=0
 func wait() async -> Bool { count += 1; let n=count; return await withCheckedContinuation { pending[n]=$0 } }
 func release(_ n:Int, _ value:Bool = true) { pending.removeValue(forKey:n)!.resume(returning:value) }
}
@MainActor enum LocationEngine {
 static var events:[String]=[]; static var clearReply:CheckedContinuation<Result<Void,Failure>,Never>?
 static func clear(pairingPath:String,deviceIP:String,verifyRemotely:Bool) async -> Result<Void,Failure> {
  events.append("clear"); return await withCheckedContinuation { clearReply=$0 }
 }
 static func set(latitude:Double,longitude:Double,pairingPath:String,deviceIP:String,progress:@escaping (Stage)->Void) async -> Result<Void,Failure> {
  events.append("set"); return .success(())
 }
}
enum HeartbeatManager {
 static func activePairingFile()->String { "test" }
 static let shared = StubHeartbeat()
}
struct StubHeartbeat { let ipAddress="127.0.0.1" }
struct Keeper { func start() {} }
@MainActor final class Session {
 static let unresolvedSimulationKey="RegressionOnlySpoofState"
 let gate=Gate(); var status:Status = .active; var isBusy=false
 var stopRequested=false; var operationGeneration=0; var routeGeneration=0; var routeTask:Task<Void,Never>?
 var connectionDetail:String?; var simulated:CLLocationCoordinate2D? = .init(latitude:1,longitude:1)
 var lastSuccessfulUpdateAt:Date?; var lastError:String?; var pin:CLLocationCoordinate2D?
 let locationKeeper=Keeper()
 func _ensureDeviceReady(generation:Int? = nil) async -> Bool { await gate.wait() }
 func stopJoystick() {}; func stopResend() {}; func endBackground() {}; func beginBackground() {}
 func startResend() {}; func pushRecent(_ coordinate:CLLocationCoordinate2D) {}
 func postDropNotification(_ message:String) {}
 func invoke() async -> Bool { await apply(.init(latitude:2,longitude:2),markRecent:false) }
''', method(spoof,'func stop() async'), method(spoof,'private func apply('), r'''
}
@MainActor final class DeviceConnectionManager { static let shared=DeviceConnectionManager(); var isConnected=true }
struct AppInfo {
 var name:String { id }
 var id:String
 var CFBundleIdentifier:String? { id }; var CFBundleDisplayName:String? { id }
 var CFBundleName:String? { id }; var CFBundleShortVersionString:String? { nil }; var CFBundleVersion:String? { nil }
}
enum AppInstallationProvenance { case unknown, sideloaded }
enum AppInstallationProvenanceClassifier {
 static func needsProvisioningProfile(_ app:AppInfo) -> Bool { false }
 static func classify(_ app:AppInfo) -> AppInstallationProvenance { .unknown }
}
struct ProvisioningProfileInfo {}
@MainActor final class InstallationAppProxy {
 static let gate=Gate(); static var count=0; static var profileCount=0
 static func iconCacheRevision(for id:String) -> String { "" }
 static func getAppIconCached(for id:String,cacheVersion:String?) async throws -> Data? { nil }
 func fetchApps(applicationType:String,lightweight:Bool = false) async throws -> [AppInfo] {
  Self.count += 1; let n=Self.count
  let good=await Self.gate.wait()
  if !good { throw Failure() }
  return [AppInfo(id: "result-\(n)")]
 }
 func provisioningProfiles() async throws -> [ProvisioningProfileInfo] { Self.profileCount += 1; return [] }
}
@MainActor final class DebugLogManager {
 enum Level { case error, warning, debug }
 static let shared=DebugLogManager()
 func log(_ message:String,category:String,level:Level = .warning) {}
}
@MainActor final class Store {
	var hasLoadedApps=false; var lastLoadedAt:Date?; var verifiedApps:[AppInfo]?; var initialBrowse:Task<[AppInfo]?,Never>?
 var iconPrefetchTask:Task<Void,Never>?; var needsTrailingRefresh=false; var refreshGeneration=UUID(); var apps:[AppInfo]=[]; var isLoading=false; var errorMessage:String?
 func prefetchFirstScreenIcons() {}
 func updateApplications(with apps:[AppInfo],profiles:[ProvisioningProfileInfo]) { self.apps=apps }
''', method(store,'func load() async'), method(store,'func refreshOnForeground() async'), method(store,'func clear()'), method(store,'func refresh(force:'), r'''
}
@MainActor final class Cellular {
 enum State:Equatable { case idle, checkingSetup, waitingForDataOff, restoringData, establishingTransport }
 enum Phase:Equatable { case idle, waitingForPostInstallVerification, probing(Purpose) }
 enum Purpose { case postInstall }
 enum Command { case on, probe }
 enum Level { case warning }
 static let restoreKey="RegressionOnlyRestoreDebt"
 var helperSetupPhase:Phase = .idle; var state:State = .waitingForDataOff
 var operationID:UUID? = UUID(); var activeCommand:Command?
 var callbackRecoveryTask:Task<Void,Never>?; var isEnabled=true; var didAttemptRestore=false
 var launched:[Command]=[]
 var isBusy:Bool { state != .idle }
 func _shortcutsAvailable()->Bool { true }; func _disableForMissingShortcuts() {}
 func _log(_ message:String,level:Level) {}
 func _startShortcut(_ command:Command) { launched.append(command); operationID=UUID(); activeCommand=command }
''', method(cellular,'public func handleApplicationDidBecomeActive()'), method(cellular,'private func _clearActiveOperation()'), method(cellular,'private func _restoreMobileDataOnce('),r'''
 func normalCallback() { _clearActiveOperation(); state = .establishingTransport }
 func finish() { _clearActiveOperation(); UserDefaults.standard.removeObject(forKey:Self.restoreKey) }
}
struct LinkApp { var identifier:String?="test.app"; var name:String?; var version:String?="2" }
final class ServerInstaller {
 let app:LinkApp; let id="abc"; let port=1234; let serverMethod:Int
 init(name:String, method:Int=1) { app=LinkApp(name:name); serverMethod=method }
 func sni()->String { "127.0.0.1" }
''']
parts.append(method(pathlib.Path("Aether/Backend/Server/ServerInstaller.swift"), "func getServerMethod()"))
for start in ['var plistEndpoint:', 'var payloadEndpoint:', 'var externalServerLink:', 'var iTunesLink:', 'var iTunesLinkExternal:', 'private func _iTunesLink(', 'private func _endpoint(']:
    parts.append(method(compute, start))
parts.append(r'''
}
final class LifecycleRegressionTests:XCTestCase {
 @MainActor func testStopMakesSuspendedSetStale() async {
  LocationEngine.events=[]; LocationEngine.clearReply=nil
  let session=Session(), oldSet=Task { await session.invoke() }
  while session.gate.count < 1 { await Task.yield() }
  let stop=Task { await session.stop() }
  while session.gate.count < 2 { await Task.yield() }
  session.gate.release(2)
  while LocationEngine.clearReply == nil { await Task.yield() }
  session.gate.release(1)
  let applied=await oldSet.value; XCTAssertFalse(applied)
  LocationEngine.clearReply!.resume(returning:.success(())); await stop.value
  XCTAssertEqual(LocationEngine.events,["clear"]); XCTAssertEqual(session.status,.idle)
  UserDefaults.standard.removeObject(forKey:Session.unresolvedSimulationKey)
 }
 @MainActor func testNormalSetStillSucceedsAndPreflightFailureReleasesBusy() async {
  LocationEngine.events=[]
  let session=Session(), set=Task { await session.invoke() }
  while session.gate.count < 1 { await Task.yield() }
  session.gate.release(1); let result=await set.value
  XCTAssertTrue(result); XCTAssertEqual(session.status,.active); XCTAssertFalse(session.isBusy)
  let failed=Task { await session.invoke() }
  while session.gate.count < 2 { await Task.yield() }
  session.gate.release(2,false); let failedResult=await failed.value
  XCTAssertFalse(failedResult); XCTAssertFalse(session.isBusy)
  UserDefaults.standard.removeObject(forKey:Session.unresolvedSimulationKey)
 }
 @MainActor func testClearDoesNotLetOldRefreshOverwriteNewResultOrLoading() async {
  DeviceConnectionManager.shared.isConnected=true
  let store=Store(), first=Task { await store.refresh() }
  while InstallationAppProxy.gate.count < 1 { await Task.yield() }
  store.clear()
  let second=Task { await store.refresh() }
  while InstallationAppProxy.gate.count < 2 { await Task.yield() }
  InstallationAppProxy.gate.release(1); await first.value
  XCTAssertTrue(store.isLoading); XCTAssertTrue(store.apps.isEmpty)
  InstallationAppProxy.gate.release(2); await second.value
  XCTAssertEqual(store.apps.map(\.id),["result-2"]); XCTAssertFalse(store.isLoading)
 }
 @MainActor func testConcurrentRefreshRequestsCoalesceIntoOneTrailingFetch() async {
  let initial=InstallationAppProxy.gate.count
  DeviceConnectionManager.shared.isConnected=true
  let store=Store(), first=Task { await store.refresh() }
  while InstallationAppProxy.gate.count <= initial { await Task.yield() }
  await store.refresh(force:true); await store.refresh(force:true)
  InstallationAppProxy.gate.release(initial+1); await first.value
  while InstallationAppProxy.gate.count < initial+2 { await Task.yield() }
  InstallationAppProxy.gate.release(initial+2)
  while store.isLoading { await Task.yield() }
  XCTAssertEqual(store.apps.map(\.id),["result-\(initial+2)"])
  XCTAssertEqual(InstallationAppProxy.gate.count,initial+2)
 }
 @MainActor func testOrdinaryOverlappingRefreshesDoNotRepeatTheFetch() async {
  let initial=InstallationAppProxy.gate.count, profiles=InstallationAppProxy.profileCount
  DeviceConnectionManager.shared.isConnected=true
  let store=Store(), task=Task { await store.refresh() }
  while InstallationAppProxy.gate.count <= initial { await Task.yield() }
  await store.refresh(); await store.refresh()
  InstallationAppProxy.gate.release(initial+1); await task.value
  for _ in 0..<10 { await Task.yield() }
  XCTAssertEqual(InstallationAppProxy.gate.count,initial+1)
  XCTAssertEqual(InstallationAppProxy.profileCount,profiles)
  XCTAssertFalse(store.isLoading)
 }
 @MainActor func testLaunchLoadIsReusedUntilDisconnectEvenForAnEmptyList() async {
  let initial=InstallationAppProxy.gate.count
  DeviceConnectionManager.shared.isConnected=true
  let store=Store(), launch=Task { await store.load() }
  while InstallationAppProxy.gate.count <= initial { await Task.yield() }
  await store.load()
  InstallationAppProxy.gate.release(initial+1); await launch.value
  XCTAssertTrue(store.hasLoadedApps)
  store.apps=[]
  await store.load()
  XCTAssertEqual(InstallationAppProxy.gate.count,initial+1)
  store.clear()
  XCTAssertFalse(store.hasLoadedApps)
  let reconnect=Task { await store.load() }
  while InstallationAppProxy.gate.count <= initial+1 { await Task.yield() }
  InstallationAppProxy.gate.release(initial+2); await reconnect.value
  XCTAssertEqual(store.apps.map(\.id),["result-\(initial+2)"])
 }
 @MainActor func testForegroundRefreshRechecksCachedAppsAndSkipsDisconnectedDevice() async {
  let initial=InstallationAppProxy.gate.count
  let store=Store();store.hasLoadedApps=true;store.apps=[AppInfo(id:"old")]
  DeviceConnectionManager.shared.isConnected=false
  await store.refreshOnForeground();XCTAssertEqual(InstallationAppProxy.gate.count,initial)
  DeviceConnectionManager.shared.isConnected=true
  let task=Task { await store.refreshOnForeground() }
  while InstallationAppProxy.gate.count <= initial { await Task.yield() }
  await store.refreshOnForeground()
  InstallationAppProxy.gate.release(initial+1);await task.value
  XCTAssertEqual(store.apps.map(\.id),["result-\(initial+1)"])
  XCTAssertEqual(InstallationAppProxy.gate.count,initial+1)
 }
 @MainActor func testDisconnectedRefreshCannotPublishAnOldReply() async {
  let initial=InstallationAppProxy.gate.count
  DeviceConnectionManager.shared.isConnected=true
  let store=Store(), task=Task { await store.refresh() }
  while InstallationAppProxy.gate.count <= initial { await Task.yield() }
  DeviceConnectionManager.shared.isConnected=false
  await store.refresh()
  InstallationAppProxy.gate.release(initial+1); await task.value
  XCTAssertTrue(store.apps.isEmpty); XCTAssertNil(store.errorMessage); XCTAssertFalse(store.isLoading)
  DeviceConnectionManager.shared.isConnected=true
 }
 @MainActor func testLostShortcutCallbackRestoresButNormalAndStaleCallbacksDoNot() async throws {
  for normal in [false,true] {
   let cell=Cellular(); UserDefaults.standard.set(true,forKey:Cellular.restoreKey)
   cell.handleApplicationDidBecomeActive()
   let recovery=cell.callbackRecoveryTask
   if normal { cell.normalCallback() }
   await recovery?.value
   XCTAssertEqual(cell.launched.count, normal ? 0 : 1)
   if !normal { XCTAssertEqual(cell.state,.restoringData) }
   cell.finish()
  }
  let cell=Cellular(); UserDefaults.standard.set(true,forKey:Cellular.restoreKey)
  cell.handleApplicationDidBecomeActive(); let recovery=cell.callbackRecoveryTask; cell.operationID=UUID()
  await recovery?.value
  XCTAssertTrue(cell.launched.isEmpty); cell.finish()
 }
 func testManifestQueriesRoundTripReservedCharactersWithoutInjection() throws {
  for name in ["Name &version=999", "C++ / # % ? café 🐱", "Normal App"] {
   let server=ServerInstaller(name:name)
   XCTAssertTrue(server.iTunesLinkExternal.hasPrefix("itms-services://?"))
   let outer=try XCTUnwrap(URLComponents(string:server.iTunesLinkExternal))
   XCTAssertEqual(outer.queryItems?.count,2)
   let inner=try XCTUnwrap(outer.queryItems?.first { $0.name=="url" }?.value)
   let decoded=try XCTUnwrap(URLComponents(string:inner))
   XCTAssertEqual(decoded.queryItems?.count,4)
   XCTAssertEqual(decoded.queryItems?.first { $0.name=="name" }?.value,name)
   XCTAssertEqual(decoded.queryItems?.first { $0.name=="version" }?.value,"2")
   XCTAssertEqual(decoded.queryItems?.first { $0.name=="fetchurl" }?.value,server.payloadEndpoint.absoluteString)
   XCTAssertFalse(decoded.percentEncodedQuery!.contains("+"))
  }
  XCTAssertEqual(ServerInstaller(name:"App",method:2).payloadEndpoint.scheme,"https")
 }
}
''')
(out/'LifecycleRegressionTests.swift').write_text('\n'.join(parts))
