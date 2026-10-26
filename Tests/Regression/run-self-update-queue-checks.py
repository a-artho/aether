"""Exercise production queue restoration/persistence with isolated defaults.

Only transport, artifact lookup, and the completion/next-job side effects are
substituted. The actual initializer chooses whether those side effects run.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
manager = (root / 'Aether/Backend/Observable/AppInstallationManager.swift').read_text()


def declaration(marker):
    start = manager.index(marker)
    end = manager.index('{', start) + 1
    depth = 1
    while depth:
        depth += (manager[end] == '{') - (manager[end] == '}')
        end += 1
    return manager[start:end].replace('UserDefaults.standard', 'defaults').replace('Bundle.main', 'RunningApp')


source = r'''
import Foundation
@MainActor let defaultsName="AetherSelfUpdateQueue-"+UUID().uuidString
@MainActor let defaults=UserDefaults(suiteName:defaultsName)!
@MainActor enum RunningApp {
 static var infoDictionary:[String:Any]? = [:]
 static var bundleIdentifier:String? {infoDictionary?["CFBundleIdentifier"] as? String}
}
@MainActor final class UIApplication {
 static let shared=UIApplication()
 enum State {case active,background}
 var applicationState=State.active
 static let didBecomeActiveNotification=Notification.Name("FixtureActive")
 static let didEnterBackgroundNotification=Notification.Name("FixtureBackground")
}
protocol AppInfoPresentable {
 var uuid:String? {get};var source:URL? {get};var identifier:String? {get}
 var version:String? {get};var isSigned:Bool {get}
}
struct AppSnapshot:AppInfoPresentable,Codable,Sendable {
 var uuid:String?;var source:URL?;var identifier:String?;var version:String?;var isSigned=true
}
struct Options:Codable,Sendable {let post_installAppAfterSigned:Bool}
@MainActor final class Storage {
 static let shared=Storage()
 func getAppDirectory(for app:AppSnapshot)->URL? {
  app.uuid == "removed" ? nil : URL(fileURLWithPath:"/fixture/"+(app.uuid ?? "unknown"))
 }
}
struct InstallationBackgroundError:Error {var localizedDescription:String {"Interrupted"}}
@MainActor final class InstallerStatusViewModel {
 enum Status {case idle,broken(Error),completed(Result<Void,Error>)}
 var status=Status.idle
 init(isIdevice:Bool) {}
}
@MainActor final class Execution {var hasExecution=false}
UTILITY
@MainActor final class Fixture {
REQUEST
SIGNING
STORED
 static let queueStorageKey="PendingQueue"
 var completedArtifacts=Set(defaults.stringArray(forKey:"Aether.completedInstallArtifacts") ?? [])
 var currentRequest:InstallationRequest?;var activeApp:AppSnapshot?
 var queuedInstalls:[InstallationRequest]=[]
 var viewModel:InstallerStatusViewModel?;var lastErrorMessage:String?
 var _foregroundObserver:NSObjectProtocol?;var _backgroundObserver:NSObjectProtocol?
 var execution:Execution?;var isInstalling=false;var installGeneration=UUID()
 var nextStarts=0;var completionSettlements=0;var logMessages:[String]=[]
 enum Level {case notice}
 func _startNextIfPossible() {nextStarts+=1}
 func _interruptInstallation(generation:UUID) {}
 func _finishCompletedInstall(generation:UUID) {completionSettlements+=1}
 func _log(_ text:String,category:String,level:Level) {logMessages.append(text)}
SUCCESS
PERSIST
INITIALIZER
}
@main struct Checks {
 @MainActor static func info(_ version:String,_ build:String)->[String:Any] {
  ["CFBundleIdentifier":"com.anfear.aether","CFBundleShortVersionString":version,"CFBundleVersion":build]
 }
 @MainActor static func prepare(_ attempt:SelfUpdateAttempt?,identifier:String="com.anfear.aether") throws {
  defaults.removeObject(forKey:"Aether.completedInstallArtifacts")
  let app=AppSnapshot(uuid:"signed",identifier:identifier,version:"3.0.2")
  let next=AppSnapshot(uuid:"queued",identifier:"other.app",version:"1")
  let records=[
   Fixture.StoredInstallation(app:app,method:1,serverMethod:1,installRequested:true,deleteAfterInstall:true,selfUpdateAttempt:attempt),
   Fixture.StoredInstallation(app:next,method:1,serverMethod:1,installRequested:true,deleteAfterInstall:false)]
  defaults.set(try JSONEncoder().encode(records),forKey:Fixture.queueStorageKey)
 }
 @MainActor static func persisted() throws -> [Fixture.StoredInstallation] {
  try defaults.data(forKey:Fixture.queueStorageKey).map {try JSONDecoder().decode([Fixture.StoredInstallation].self,from:$0)} ?? []
 }
 @MainActor static func main() async throws {
  defer {defaults.removePersistentDomain(forName:defaultsName)}
  let old=info("3.0.1","10"),next=info("3.0.2","11")
  let changed=SelfUpdateAttempt(runningInfo:old,targetInfo:next)!
  RunningApp.infoDictionary=next;try prepare(changed)
  let confirmed=Fixture()
  precondition(confirmed.lastErrorMessage==nil && confirmed.completionSettlements==1)
  precondition(confirmed.currentRequest?.deleteAfterInstall==true,"Verified replacement uses normal completion/auto-delete policy")
  precondition(confirmed.completedArtifacts.contains(confirmed.currentRequest!.appKey))
  precondition(try persisted().map(\.app.uuid)==["queued"],"Verified job retires from persistence without dropping the next job")

  var same=SelfUpdateAttempt(runningInfo:next,targetInfo:next)!
  same.receivedInstallationResponse=true
  try prepare(same)
  let unconfirmed=Fixture()
  for _ in 0..<100 {await Task.yield()}
  precondition(unconfirmed.currentRequest==nil && unconfirmed.activeApp==nil && unconfirmed.viewModel==nil)
  precondition(unconfirmed.lastErrorMessage==nil && unconfirmed.completionSettlements==0,
   "Unconfirmed same-build reinstalls must never run completion-driven IPA deletion")
  precondition(unconfirmed.completedArtifacts.contains("true|signed"),"Installed artifact gets Reinstall")
  precondition(unconfirmed.queuedInstalls.map(\.app.uuid)==["queued"] && unconfirmed.nextStarts==1)
  precondition(try persisted().map(\.app.uuid)==["queued"])
  precondition(unconfirmed.logMessages.contains {$0.contains("unconfirmed") && $0.contains("retained the IPA")})

  for (attempt,id,running) in [(changed,"com.anfear.aether",old),(same,"other.app",next)] {
   RunningApp.infoDictionary=running;try prepare(attempt,identifier:id)
   let interrupted=Fixture()
   precondition(interrupted.lastErrorMessage != nil && interrupted.completionSettlements==0)
   precondition(interrupted.currentRequest?.app.uuid=="signed" && interrupted.queuedInstalls.count==1)
   precondition(interrupted.completedArtifacts.isEmpty,"A different app or unchanged old build cannot inherit self-update success")
  }
  same.receivedInstallationResponse=nil;RunningApp.infoDictionary=next;try prepare(same)
  let notAccepted=Fixture()
  precondition(notAccepted.lastErrorMessage != nil,"Preparation alone cannot clear an interrupted job")
  try prepare(nil)
  let legacy=Fixture()
  precondition(legacy.currentRequest != nil && legacy.lastErrorMessage != nil,"Queues without self-update evidence retain Retry/Cancel")
  print("Self-update queue checks passed: production restoration, verified completion, same-build Reinstall, no unconfirmed auto-delete, subsequent-job persistence and unrelated/interrupted jobs")
 }
}
'''
replacements = {
    'UTILITY': (root / 'Aether/Utilities/SelfUpdateAttempt.swift').read_text(),
    'REQUEST': declaration('struct InstallationRequest:'),
    'SIGNING': declaration('struct SigningInput:'),
    'STORED': declaration('private struct StoredInstallation:').replace('private struct', 'struct', 1),
    'SUCCESS': declaration('private var hasCompletedSuccessfully:'),
    'PERSIST': declaration('private func _persistInstallQueue()'),
    'INITIALIZER': declaration('private init()').replace('private init', 'init', 1),
}
for marker, replacement in replacements.items():
    source = source.replace('\n' + marker + '\n', '\n' + replacement + '\n')
# Throwing persistence reads must finish before the nonthrowing precondition closure.
source = source.replace('precondition(try persisted().map(\\.app.uuid)==["queued"],',
                        'let confirmedRecords=try persisted(); precondition(confirmedRecords.map(\\.app.uuid)==["queued"],')
source = source.replace('precondition(try persisted().map(\\.app.uuid)==["queued"])',
                        'let unconfirmedRecords=try persisted(); precondition(unconfirmedRecords.map(\\.app.uuid)==["queued"])')
with tempfile.TemporaryDirectory(prefix='aether-self-update-queue-') as directory:
    folder = Path(directory)
    swift = folder / 'Checks.swift'
    swift.write_text(source)
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks')], check=True, timeout=15)
