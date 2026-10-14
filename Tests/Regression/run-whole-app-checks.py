#!/usr/bin/env python3
"""Exercise production restoration, search and catalog cancellation with deterministic doubles."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
def declaration(path, start):
    s = (repo/path).read_text(); a = s.index(start); b = s.index('{', a)+1; depth = 1
    while depth:
        depth += (s[b]=='{')-(s[b]=='}'); b += 1
    return s[a:b]
s = r'''
import Foundation
extension String {static func localized(_ s:String)->String {s}}
final class Download {
 enum State:Equatable {case downloading,pausing,paused,resuming,processing,failed}
 let id:String;let logicalIdentifier:String;let url=URL(string:"https://fixture.test/app")!
 var state:State = .downloading;var task:URLSessionDownloadTask?;var resumeData:Data?;var bytesDownloaded:Int64=0
 var isActive:Bool {state == .downloading || state == .resuming || state == .pausing}
 init(_ id:String){self.id=id;logicalIdentifier=id}
}
final class NetworkTask {
 enum State {case suspended,running,completed}
 var taskDescription:String?;var state:State = .suspended;var cancelled=false;var resumed=false
 var response:URLResponse?;var originalRequest:URLRequest?;var countOfBytesReceived:Int64=0;var countOfBytesExpectedToReceive:Int64=0
 init(_ id:String){taskDescription=id}
 func cancel(){cancelled=true};func resume(){resumed=true}
}
typealias URLSessionDownloadTask=NetworkTask
final class Session {var tasks:[NetworkTask]=[];func getAllTasks(_ body:@escaping ([AnyObject])->Void){body(tasks)}}
struct Store {func stagingURL(for download:Download)->URL? {nil};func pruneArtifacts(keeping downloads:[Download]){}}
@MainActor final class Driver {
 var downloads:[Download]=[];var _restorableTransferIDs=Set<String>();var _restoringTransferIDs=Set<String>()
 let _session=Session();let _store=Store();var missing=0
 func _confirmResume(_ download:Download,offset:Int64,expectedTotalBytes:Int64){}
 func _markRestartRequired(_ download:Download,message:String){download.state = .failed}
 func _restoreMissingTransfer(_ download:Download){missing+=1}
 func _recoverCommittedImport(for download:Download){}
 func _persistDownloads(){}
 func _requestResumeDataForPause(_ download:Download){}
 func _startProcessing(_ download:Download,sourceURL:URL,sourceIsStable:Bool){}
'''
for name in ['private func _getDownload(transferIdentifier:', 'private func _getDownloadTask(', 'private func _restoreSessionTasks()']:
    s += declaration('Aether/Backend/Observable/DownloadManager.swift', name).replace('private func','func',1)+'\n'
s += r'''
}
struct ASRepository:Sendable {let id:Int}
struct ObjectID {let key:String;func uriRepresentation()->URL {URL(string:key)!}}
struct AltSource {let objectID:ObjectID;let sourceURL:URL?}
actor SourceRepositoryService {
 struct Snapshot:Sendable {let revision:String;let repository:ASRepository}
 var fetches=0;var reads=0
 func cached(for url:URL) async -> Snapshot? {reads+=1;return nil}
 func fetch(from url:URL,refresh:Bool,allowEmptyCatalog:Bool) async throws -> Snapshot {
  fetches+=1;try await Task.sleep(nanoseconds:100_000_000)
  return Snapshot(revision:"one",repository:ASRepository(id:1))
 }
}
struct Log {func error(_ s:String){}}
enum Logger {static let misc=Log()}
@MainActor final class VM {
 struct SourceRequest:Sendable {let key:String;let sourceURL:URL?}
 let _repositoryService=SourceRepositoryService();var sources:[String:ASRepository]=[:]
 var _revisions:[String:String]=[:];var removedSourceKeys=Set<String>();var catalogRevision=0;var refreshErrors:[String:String]=[:]
'''
for name in ['func ensureSourcesLoaded(', 'private func _restoreCachedSources(', 'private func _fetchRequests(']:
    s += declaration('Aether/Views/Sources/SourcesViewModel.swift', name)+'\n'
s += '}\n'
s += r'''
struct AppInfo:Sendable {let id:String}
func installation_proxy_client_free(_ client:OpaquePointer?){}
final class ProbeState:@unchecked Sendable {
 let lock=NSLock();private var started=false;private var reads=0
 func begin(){lock.lock();started=true;lock.unlock()}
 func hasStarted()->Bool {lock.lock();defer{lock.unlock()};return started}
 func read(){lock.lock();reads+=1;lock.unlock()}
 func readCount()->Int {lock.lock();defer{lock.unlock()};return reads}
}
final class NativeProxy:@unchecked Sendable {
 typealias InstallationProxyClientHandle=OpaquePointer
 static let probe=ProbeState()
 func _connectInstallationProxy(client:inout OpaquePointer?) throws {
  Self.probe.begin();Thread.sleep(forTimeInterval:0.08);client=OpaquePointer(bitPattern:1)
 }
 static func readApps(client:OpaquePointer?,applicationType:String?,lightweight:Bool,bundleIdentifier:String?) throws -> [AppInfo] {
  probe.read();return [AppInfo(id:"fixture")]
 }
'''
s += declaration('IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift','public func fetchApps(').replace('public func','func',1)+'\n}\n'
s += 'struct Search {var searchText:String\n' +declaration('Aether/Views/Library/LibraryView.swift','private func matchesSearch(').replace('private func','func',1)+'\n}\n'
s += r'''
struct PairingRecordIdentity:Equatable,Sendable {let id:String}
enum State {case connected,disconnected}
enum Diagnostic {case ready,checking}
enum Level {case debug}
func CACurrentMediaTime()->Double {ProcessInfo.processInfo.systemUptime}
@MainActor final class CellularAssistManager {static let shared=CellularAssistManager();var isAutomaticRecoveryInProgress=false}
@MainActor final class ReadyDriver {
 var activeVerificationID:UUID?;var transitionGeneration:UUID?;var currentRecord:PairingRecordIdentity?
 var state:State = .disconnected;var diagnostic:Diagnostic = .checking;var lastVerifiedAt=0.0;var lastVerifiedRecord:PairingRecordIdentity?
 func _recordStillMatches(_ record:PairingRecordIdentity?)->Bool {currentRecord==record}
 func _log(_ text:String,level:Level){}
'''
s += declaration('Aether/Backend/Observable/DeviceConnectionManager.swift','private func _publishVerifiedTransport(').replace('private func','func',1)+'\n'
connection=(repo/'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
callback=connection[connection.index('let publishReadiness: @Sendable'):connection.index('\n\t\tlet verification = Task.detached',connection.index('let publishReadiness: @Sendable'))]
s += 'func callback(includeApps:Bool,verificationID:UUID,reconciliationGeneration:UUID?,checkedRecord:PairingRecordIdentity?,cellularAssistTransaction:Bool,verificationStarted:Double)->@Sendable ()->Void {\n'+callback+'\nreturn publishReadiness\n}\n}\n'

library = (repo/'Aether/Views/Library/LibraryView.swift').read_text()
prelude = library[library.index('let sections: [LibrarySection] ='):library.index('let layout = LibraryLayout')]
s += r'''
struct LibrarySearchFixture {
 enum LibrarySection {case allApps,status,imports,updates}
 var searchText="query";var showAllApps=false;var installationMethod=1;var showsDevicePlaceholder=true
 var importRows:[Int]=[];var appsWithUpdates:[Int]=[]
 func results()->(Int,Bool) {
''' + prelude + 'return (sections.count,!searchText.isEmpty && sections.isEmpty)\n}\n}\n'
s += r'''
func check(_ value:@autoclosure ()->Bool,_ message:String){precondition(value(),message)}
@main struct Checks {
 @MainActor static func main() async throws {
  let empty=LibrarySearchFixture().results()
  check(empty.0==0 && empty.1,"No-results placeholder uses the filtered section membership")
  var searched=LibrarySearchFixture();searched.importRows=[1]
  check(!searched.results().1,"Matching download suppresses no-results placeholder")
  let readiness=ReadyDriver(), verificationID=UUID(), record=PairingRecordIdentity(id:"one")
  readiness.activeVerificationID=verificationID;readiness.currentRecord=record
  readiness._publishVerifiedTransport(verificationID:UUID(),generation:nil,record:record,cellularAssistTransaction:false,startedAt:0)
  check(readiness.state == .disconnected,"Obsolete verification cannot publish Connected")
  readiness._publishVerifiedTransport(verificationID:verificationID,generation:nil,record:record,cellularAssistTransaction:false,startedAt:0)
  check(readiness.state == .connected,"Authenticated transport publishes before enumeration")
  readiness.state = .disconnected
  let callback=readiness.callback(includeApps:true,verificationID:verificationID,reconciliationGeneration:nil,checkedRecord:record,cellularAssistTransaction:false,verificationStarted:0)
  await Task.detached {callback()}.value
  for _ in 0..<20 {await Task.yield()}
  check(readiness.state == .connected,"Detached authenticated callback publishes on MainActor")
  readiness.state = .disconnected;readiness.activeVerificationID=nil
  readiness._publishVerifiedTransport(verificationID:verificationID,generation:nil,record:record,cellularAssistTransaction:false,startedAt:0)
  check(readiness.state == .disconnected,"Late readiness cannot undo a completed disconnect")
  let driver=Driver(), saved=Download("saved"), early=NetworkTask("saved")
  driver.downloads=[saved];driver._restorableTransferIDs=[saved.id];driver._restoringTransferIDs=[saved.id]
  check(driver._getDownloadTask(early) === saved && saved.task === early,"Early restored callback adopts saved attempt synchronously")
  let stale=NetworkTask("saved")
  check(driver._getDownloadTask(stale)?.task !== stale,"Stale callback cannot replace adopted task")
  let fresh=Download("fresh"), freshTask=NetworkTask("fresh")
  fresh.task=freshTask;driver.downloads.append(fresh)
  driver._session.tasks=[early,freshTask];driver._restoreSessionTasks()
  for _ in 0..<20 {await Task.yield()}
  check(early.resumed && !freshTask.resumed,"Restoration resumes only saved transfers, preserving fresh-task persistence barrier")
  saved.task=nil
  check(driver._getDownloadTask(stale)?.task == nil,"Callbacks after restoration cannot adopt an obsolete task")
  check(driver.missing==0,"Adopted task is not marked missing")
  let native=Task {try await NativeProxy().fetchApps(applicationType:"User")}
  while !NativeProxy.probe.hasStarted(){await Task.yield()}
  native.cancel()
  do {_=try await native.value;preconditionFailure("Cancelled native lookup succeeded")}catch is CancellationError {}
  check(NativeProxy.probe.readCount()==0,"Cancellation during handshake prevents native enumeration")
  let vm=VM(), sources=(0..<8).map {AltSource(objectID:ObjectID(key:"source://\($0)"),sourceURL:URL(string:"https://fixture.test/\($0)"))}
  let load=Task {await vm.ensureSourcesLoaded(sources,batchSize:1)}
  while await vm._repositoryService.fetches==0 {await Task.yield()}
  load.cancel();await load.value
  let count=await vm._repositoryService.fetches
  check(count==1,"Cancelled catalog consumer starts no further batches")
  check(vm.sources.isEmpty && vm.refreshErrors.isEmpty,"Cancellation publishes neither stale catalog nor failure")
  let reads=await vm._repositoryService.reads
  check(reads==8,"Navigation does not repeat cache-miss restoration")
  check(Search(searchText:"fixture").matchesSearch("Other","com.fixture.app"),"Library search matches bundle identifiers")
  check(!Search(searchText:"absent").matchesSearch("Fixture"),"Unmatched entries are excluded")
  print("Whole-app restore/cancellation/search checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-whole-app-') as directory:
    root=pathlib.Path(directory);(root/'Checks.swift').write_text(s)
    subprocess.run(['swiftc','-parse-as-library',str(root/'Checks.swift'),'-o',str(root/'checks')],check=True)
    subprocess.run([str(root/'checks')],check=True)
