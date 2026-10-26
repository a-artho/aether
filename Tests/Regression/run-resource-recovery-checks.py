#!/usr/bin/env python3
"""Exercise production failure cleanup, restore-debt recovery and URL handoff routing."""
from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[2]
def d(file,start):
 s=(r/file).read_text();a=s.index(start);b=s.index('{',a)+1;n=1
 while n:n+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]+'\n'
spoof='Aether/Views/Spoofing/Engine/SpoofSession.swift';cell='Aether/Backend/Observable/CellularAssistManager.swift'
s='''import Foundation
struct Coordinate {}
struct Failure: Error {var localizedDescription:String {"failed"}}
enum Status:Equatable {case idle,active,connecting,reconnecting,stopping,dropped(String);var isDropped:Bool{if case .dropped=self{return true};return false}}
enum ApplicationState:Int {case active,background}
@MainActor final class UIApplication {static let shared=UIApplication();var applicationState=ApplicationState.active}
@MainActor enum LocationEngine {static var succeeds=false;static func clear(pairingPath:String,deviceIP:String,verifyRemotely:Bool) async->Result<Void,Failure>{succeeds ? .success(()) : .failure(Failure())}}
enum HeartbeatManager {static let shared=Heart();static func activePairingFile()->String{"fixture"}}
struct Heart{let ipAddress="fixture"}
@MainActor final class DeviceConnectionManager {
 static let shared=DeviceConnectionManager();var shouldFail=true;var releases=0
 func ensureConnected() async throws {if shouldFail{throw Failure()}}
 func handleAppBackground(){releases+=1}
 func cellularRecoveryDidFinish(){}
}
@MainActor final class Session {
 var status:Status = .active {didSet{handleStatusChange()}};var operationGeneration=0;var routeGeneration=0;var routeTask:Task<Void,Never>?
 var isBusy=false;var connectionDetail:String?;var simulated:Coordinate?=Coordinate();var lastSuccessfulUpdateAt:Date?;var lastError:String?
 static let unresolvedSimulationKey="Audit.SpoofMarker";var audioRunning=true;var stopRequested=false
 func stopJoystick(){};func stopResend(){};func endBackground(){audioRunning=false};func postDropNotification(_ s:String){}
 func updateLocationTracking(){}
'''+d(spoof,'var requiresBackgroundExecution:')+d(spoof,'private func handleStatusChange(')+d(spoof,'func stop() async')+d(spoof,'private func _ensureDeviceReady(')+'''}
@MainActor final class Cellular {
 enum Command {case off,on,probe};enum State:Equatable {case idle,failed(String),checkingSetup,restoringData,waitingForDataOff}
 enum Purpose {case postInstall};enum Phase:Equatable {case idle,waitingForPostInstallVerification,probing(Purpose)};enum Episode {case consumed}
 static let restoreBlockedKey="Audit.RestoreBlocked";static let restoreKey="Audit.RestoreDebt";static let enabledKey="Audit.CellularEnabled"
 var transportRecoveryID:UUID?;var retryTask:Task<Void,Never>?;var callbackRecoveryTask:Task<Void,Never>?;var callbackRecoveryDeadline:TimeInterval?;var operationID:UUID?;var activeCommand:Command?
 var pendingTransportFailureMessage:String?;var helperSetupPhase=Phase.idle
 var didAttemptRestore=false;var automaticRecoveryEpisode=Episode.consumed;var isEnabled=true;var state=State.idle;var restores=0
 var isBusy:Bool {if case .restoringData=state{return true};return false}
 func _clearActiveOperation(){callbackRecoveryTask?.cancel();callbackRecoveryTask=nil;operationID=nil;activeCommand=nil}
 func _presentShortcutsUnavailableAlert(message:String){};func _presentTerminalAlert(title:String,message:String){}
 func _finishHelperSetupFailure(_ message:String){_finishRuntimeFailure(message)}
 func _shortcutsAvailable()->Bool{true};func _disableForMissingShortcuts(){};func _startShortcut(_ command:Command){}
 func _log(_ message:String,level:Level = .info){};enum Level {case info,warning}
 func _restoreMobileDataOnce(force:Bool=false){guard force || !didAttemptRestore else{return};didAttemptRestore=true;restores+=1;state = .restoringData}
 func failOff(){_handleRuntimeFailure("Shortcut failed",command:.off)}
 func failOn(){_handleRuntimeFailure("Shortcut failed",command:.on)}
'''+d(cell,'private func _handleRuntimeFailure(')+d(cell,'private func _finishRuntimeFailure(')+d(cell,'private func _finishTerminalState(')+d(cell,'public func handleApplicationDidBecomeActive(')+d(cell,'public func cancelAndRestoreIfNeeded(')+'''}
@MainActor enum SpoofSession {static var existing:Session?}
@MainActor final class AppInstallationManager {static let shared=AppInstallationManager();var isInstalling=false}
@MainActor final class OnDevicePairingManager {static let shared=OnDevicePairingManager();var isActive=false}
@MainActor final class CellularAssistManager {static let shared=CellularAssistManager();var isBusy=false;var isWaitingForManualRecovery=false;var requiresTunnelConnection=false}
@MainActor final class DependencyProbe {
'''+d('Aether/Backend/Observable/DeviceConnectionManager.swift','public var hasActiveTunnelDependencies:')+'''}
@MainActor final class DownloadManager {
 static let shared=DownloadManager();var networkURLs:[URL]=[];var fileURLs:[URL]=[]
 func startDownload(from:URL,id:String) async {networkURLs.append(from)}
 func startExternalArchive(from:URL,id:String){fileURLs.append(from)}
}
@MainActor final class AppTabManager {static let shared=AppTabManager();enum Tab{case library};func closeSearch(){};func switchTo(_ tab:Tab){}}
@MainActor final class DebugLogManager {enum Level{case info,notice};static let shared=DebugLogManager();func log(_ message:String,category:String,level:Level = .info){}}
@MainActor struct Handoff {
'''+d('Aether/AetherApp.swift','private func _importExternalPackage(').replace('private func','func',1)+'''}
@MainActor final class Download {
 let id:String;let importIdentifier=UUID().uuidString;var task:URLSessionDownloadTask?
 init(transferIdentifier:String,logicalIdentifier:String,url:URL,fileName:String?){id=transferIdentifier}
}
@MainActor final class LibraryArtifactIndex {static let shared=LibraryArtifactIndex();var imports=Set<String>();func recordImport(uuid:String){imports.insert(uuid)}}
struct RecoveryStore {var hasUnrestoredArtifacts=true}
@MainActor final class RecoveryDriver {
 var _store=RecoveryStore();var downloads:[Download]=[];var _restorableTransferIDs=Set<String>();var _restoringTransferIDs=Set<String>()
 func _getDownload(transferIdentifier:String)->Download?{downloads.first{$0.id==transferIdentifier}}
'''+d('Aether/Backend/Observable/DownloadManager.swift','private func _recoverUnrecordedSystemTask(').replace('private func','func',1)+d('Aether/Backend/Observable/DownloadManager.swift','private func _getDownloadTask(').replace('private func','func',1)+'''}
@main struct Main {
 @MainActor static func main() async {
  let session=Session();await session.stop()
  check(session.status.isDropped && !session.audioRunning,"Failed spoof preflight retained audio")
  check(session.simulated != nil && session.stopRequested,"Failed Stop lost uncertain location or user intent")
  DeviceConnectionManager.shared.shouldFail=false
  let clearFailure=Session();await clearFailure.stop()
  check(clearFailure.status.isDropped && !clearFailure.audioRunning,"Failed remote clear retained audio")
  LocationEngine.succeeds=true
  let cleared=Session();await cleared.stop()
  check(cleared.status == .idle && cleared.simulated == nil && !cleared.stopRequested,"Successful Stop retained retry intent")
  LocationEngine.succeeds=false
  let cell=Cellular();UserDefaults.standard.set(true,forKey:Cellular.restoreKey);cell.failOff()
  check(UserDefaults.standard.bool(forKey:Cellular.restoreKey) && !cell.isEnabled && cell.restores==1,"Data-off failure lost restore debt or failed to restore")
  let onFailure=Cellular();onFailure.failOn();onFailure.handleApplicationDidBecomeActive()
  check(UserDefaults.standard.bool(forKey:Cellular.restoreKey) && !onFailure.isEnabled && onFailure.restores==0,"Failed restoration relaunched automatically")
  UserDefaults.standard.removeObject(forKey:Cellular.restoreBlockedKey)
  let disabled=Cellular();disabled.isEnabled=false;disabled.cancelAndRestoreIfNeeded()
  check(disabled.restores==1,"Cancellation blocked restoration when feature disabled")
  UserDefaults.standard.set(true,forKey:"Aether.spoofing.simulationMayBeActive")
  let dependencies=DependencyProbe()
  SpoofSession.existing=nil;check(!dependencies.hasActiveTunnelDependencies,"Saved marker pinned idle VPN")
  SpoofSession.existing=session;check(!dependencies.hasActiveTunnelDependencies,"Dropped session pinned VPN")
  session.status = .active;check(dependencies.hasActiveTunnelDependencies,"Active spoof no longer protects VPN")
  let handoff=Handoff(),url=URL(string:"https://fixture.test/app.ipa?token=abc")!,file=URL(fileURLWithPath:"/tmp/local.ipa")
  handoff._importExternalPackage(from:url);handoff._importExternalPackage(from:file)
  for _ in 0..<30 {await Task.yield()}
  check(DownloadManager.shared.networkURLs==[url] && DownloadManager.shared.fileURLs==[file],"HTTP handoff and file import used wrong pipelines")
  let nativeSession=URLSession(configuration:.ephemeral)
  defer{nativeSession.invalidateAndCancel()}
  let systemTask=nativeSession.downloadTask(with:url);systemTask.taskDescription="recovered-transfer"
  let recovery=RecoveryDriver();let recovered=recovery._getDownloadTask(systemTask)
  check(recovered?.task === systemTask && recovery.downloads.count==1,"Unreadable metadata orphaned system transfer")
  check(recovery._getDownloadTask(systemTask) === recovered && recovery.downloads.count==1,"Recovered transfer duplicated")
  let ordinary=RecoveryDriver();ordinary._store.hasUnrestoredArtifacts=false
  check(ordinary._getDownloadTask(systemTask)==nil,"Healthy queue adopted unknown task")
  for key in [Cellular.restoreBlockedKey,Cellular.restoreKey,Cellular.enabledKey,"Aether.spoofing.simulationMayBeActive"] {UserDefaults.standard.removeObject(forKey:key)}
  print("Resource recovery checks passed: spoof failures, live VPN ownership, cellular restore debt, HTTP/file routing")
 }
 static func check(_ condition:@autoclosure ()->Bool,_ message:String){precondition(condition(),message)}
}
'''
with tempfile.TemporaryDirectory(prefix='aether-resources-') as t:
 p=Path(t);(p/'Checks.swift').write_text(s)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
