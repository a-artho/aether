"""Production native task ownership exercised against deterministic scheduler and network doubles.
These tests validate lifecycle and callback routing, not actual iOS execution grants or rendering.
"""
import pathlib,sys
repo=pathlib.Path(__file__).resolve().parents[2]; out=pathlib.Path(sys.argv[1])
def method(path,start):
 s=(repo/path).read_text(); p=s.index(start); b=s.index('{',p); n=1; e=b+1
 while n:n+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[p:e]
manager=(repo/'Aether/Utilities/BackgroundTaskManager.swift').read_text()
manager=manager[manager.index('@MainActor\nclass BackgroundTaskManager:'):manager.rindex('#endif')]
operation=(repo/'Aether/Utilities/AppOperationExecution.swift').read_text()
operation=operation[operation.index('@MainActor'): ]
parts=[r'''
import Foundation
import XCTest
extension String { static func localized(_ value:String, arguments:CVarArg...) -> String { String(format:value,arguments:arguments) } }
enum BackgroundFixture {
protocol ObservableObject {}
@MainActor final class BackgroundAudioManager {
 static let shared=BackgroundAudioManager(); var requesters=Set<String>(); var starts=0; var stops=0
 func start(_ id:String) { if requesters.insert(id).inserted { starts+=1 } }
 func stop(_ id:String) { if requesters.remove(id) != nil { stops+=1 } }
}

@MainActor final class DownloadCheckpointLease { func end() {} }
struct UNNotificationSound { static let `default`=Self() }
final class UNMutableNotificationContent { var title="",body="";var sound:UNNotificationSound? }
struct UNNotificationRequest { let identifier:String;let content:UNMutableNotificationContent;let trigger:String? }
@MainActor final class UNUserNotificationCenter {
 static let shared=UNUserNotificationCenter();var requests:[UNNotificationRequest]=[]
 static func current()->UNUserNotificationCenter { shared }
 func add(_ request:UNNotificationRequest) async throws { requests.append(request) }
}
struct UIBackgroundTaskIdentifier:Hashable { let raw:Int;static let invalid=Self(raw:-1) }
@MainActor final class UIApplication {
 enum State:Int { case active,inactive,background }
 static let shared=UIApplication();var applicationState:State = .active
 var fallbackAvailable=true;var sequence=0;var fallback:[UIBackgroundTaskIdentifier:()->Void]=[:]
 func beginBackgroundTask(withName:String,expirationHandler:@escaping ()->Void)->UIBackgroundTaskIdentifier {
  guard fallbackAvailable else { return .invalid };sequence+=1;let id=UIBackgroundTaskIdentifier(raw:sequence);fallback[id]=expirationHandler;return id
 }
 func endBackgroundTask(_ id:UIBackgroundTaskIdentifier) { fallback.removeValue(forKey:id) }
}
class BGTask {}
final class BGContinuedProcessingTask:BGTask {
 let identifier:String;let progress=Progress(totalUnitCount:100);var expirationHandler:(()->Void)?
 var completions:[Bool]=[];var presentations:[String]=[]
 init(_ identifier:String) { self.identifier=identifier }
 func updateTitle(_ title:String,subtitle:String) { presentations.append(subtitle) }
 func setTaskCompleted(success:Bool) { completions.append(success) }
}
struct SchedulerError:Error {}
final class BGContinuedProcessingTaskRequest {
 enum Strategy { case fail };var strategy:Strategy = .fail
 let identifier:String;init(identifier:String,title:String,subtitle:String) { self.identifier=identifier }
}
@MainActor final class BGTaskScheduler {
 static let shared=BGTaskScheduler();var reject=false;var requests:[String]=[]
 var handlers:[String:(BGTask)->Void]=[:];var cancellations:[String]=[]
 func register(forTaskWithIdentifier id:String,using:DispatchQueue,launchHandler:@escaping (BGTask)->Void)->Bool {
  precondition(handlers[id]==nil);handlers[id]=launchHandler;return true
 }
 func submit(_ request:BGContinuedProcessingTaskRequest) throws { if reject { throw SchedulerError() };requests.append(request.identifier) }
 func cancel(taskRequestWithIdentifier:String) { cancellations.append(taskRequestWithIdentifier) }
 func launch(_ id:String)->BGContinuedProcessingTask { let task=BGContinuedProcessingTask(id);handlers[id]!(task);return task }
 func launchLast()->BGContinuedProcessingTask { launch(requests.last!) }
}
@MainActor final class DebugLogManager {
 enum Level { case info,notice };static let shared=DebugLogManager()
 func log(_ message:String,category:String,level:Level = .info) {}
}
''',manager,operation,r'''
final class Download {
 enum State:Equatable { case downloading,resuming,pausing,paused,processing,failed }
 var state:State = .downloading;let id=UUID().uuidString;var task:NetworkTask?
 init() {}
 init(logicalIdentifier:String,url:URL,sourceProvenance:Provenance?) { self.sourceProvenance=sourceProvenance }
 var sourceProvenance:Provenance?;let fileName="App";let onlyArchiving=false
 var progress=0.0;var unpackageProgress=0.0
 var backgroundProgress:Double { unpackageProgress }
 var waitingForForeground=false;var interruptionForegroundGeneration:UInt64=0
 var resumeData:Data?;var stagedFileName:String?;var bytesDownloaded:Int64=0;var totalBytes:Int64=0
 var lastUIProgressUpdate=0.0;var lastPersistedProgressUpdate=0.0;var lastPersistedBytes:Int64=0;var lastBackgroundProgressUpdate=0.0;var lastBackgroundDiagnosticUpdate=0.0
}
struct Provenance { let sourceAppName:String }
typealias SourceAppProvenance=Provenance
@MainActor final class NetworkTask {
 var resumed=false,cancelled=false;var taskDescription:String?
 var pauseCallback:((Data?)->Void)?
 func resume() { resumed=true };func cancel() { cancelled=true }
 func cancel(byProducingResumeData completion:@escaping (Data?)->Void) { cancelled=true;pauseCallback=completion }
}
@MainActor final class Session { func downloadTask(withResumeData:Data)->NetworkTask { NetworkTask() } }
typealias URLSessionDownloadTask=NetworkTask
typealias URLSession=Session
struct Store { func saveResumeData(_ data:Data,for id:String) throws {};func cleanupArtifacts(for download:Download) {} }
@MainActor final class DownloadResultNotifier {
 static let shared=DownloadResultNotifier()
 func requestPermissionIfNeeded() {}
	func send(transferIdentifier: String, title: String, body: String) {
		#if !targetEnvironment(macCatalyst)
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		let request = UNNotificationRequest(identifier: "Aether.download.result.\(transferIdentifier)", content: content, trigger: nil)
		let checkpoint = DownloadCheckpointLease()
		Task {
			defer { checkpoint.end() }
			do {
				try await UNUserNotificationCenter.current().add(request)
				DebugLogManager.shared.log("Download result notification submitted id=\(transferIdentifier) title=\(title).", category: "Download", level: .info)
			} catch {
				DebugLogManager.shared.log("Download result notification failed id=\(transferIdentifier): \(error.localizedDescription)", category: "Download", level: .notice)
			}
		}
		#endif
	}
}
@MainActor final class Driver {
 var downloads:[Download]=[];var _restorableTransferIDs=Set<String>();var _restoringTransferIDs=Set<String>();let _session=Session(),_store=Store()
 var holdSave=false;var saveGate:CheckedContinuation<Void,Never>?
 func getDownload(from:URL,sourceProvenance:Provenance?)->Download? { nil }
 func _makeFreshTask(for download:Download)->NetworkTask { NetworkTask() }
 func _persistBeforeResuming(_ download:Download) async -> Bool {
  if holdSave { await withCheckedContinuation { saveGate=$0 } }
  UIApplication.shared.applicationState = .background;return true
 }
 var _foregroundGeneration:UInt64=1;var _processingTasks:[String:Task<Void,Never>]=[:];var persists=0
 func _isCurrent(_ download:Download)->Bool { downloads.contains { $0 === download } }
 func _getDownloadTask(_ task:NetworkTask)->Download? { downloads.first { $0.task === task } }
 func _persistDownloads(immediately:Bool=true) { persists+=1 };func _releaseIdleBackgroundTunnel() {}
 func _markRestartRequired(_ download:Download,message:String) { download.state = .failed;download.task=nil;_stopContinuedTask(for:download,success:false) }
 func notify(_ download:Download) { _notifyDownloadCompleted(download) }
 func notifyFailure(_ download:Download) { _notifyDownload(download,title:"Download failed",body:"Connection lost") }
 func start(_ download:Download) { downloads.append(download);_startDownloadExecution(for:download) }
 func process(_ download:Download)->Bool { download.state = .processing;return _ensureProcessingExecution(download,subtitle:"Processing") }
''']
source=pathlib.Path('Aether/Backend/Observable/DownloadManager.swift')
for start in ['func startDownload(', 'func pauseDownload(', 'func resumeDownload(', 'func restartDownload(', 'private func _requestResumeDataForPause(', 'private func _ensureOperationExecution(', 'private func _ensureProcessingExecution(', 'private func _startDownloadExecution(', 'private func _stopContinuedTask(', 'private func _notifyDownloadCompleted(', 'private func _notifyDownload(']:
 parts.append(method(source,start))
s=(repo/source).read_text();start=s.index('\tfunc urlSession(',s.index('\t\tdidWriteData')-100);end=s.index('\n\tfunc urlSession(',start+5)
parts.append(s[start:end])
parts.append(r'''
}
}
final class BackgroundOwnershipTests:XCTestCase {
 typealias UIApplication=BackgroundFixture.UIApplication
 typealias BGTaskScheduler=BackgroundFixture.BGTaskScheduler
 typealias BackgroundTaskManager=BackgroundFixture.BackgroundTaskManager
 typealias Download=BackgroundFixture.Download
 typealias Driver=BackgroundFixture.Driver
 @MainActor func reset() { UIApplication.shared.applicationState = .active;UIApplication.shared.fallbackAvailable=true;BGTaskScheduler.shared.reject=false }
 @MainActor func settle() async { for _ in 0..<8 { try? await Task.sleep(nanoseconds:1_000_000) } }
 @MainActor func testQuickLockDuringPersistenceLeavesNetworkIndependent() async {
  reset();let driver=Driver(),before=BGTaskScheduler.shared.requests.count
  let d=await driver.startDownload(from:URL(string:"https://example.com/App.ipa")!)
  XCTAssertEqual(BGTaskScheduler.shared.requests.count,before);XCTAssertTrue(d.task!.resumed)
  XCTAssertFalse(BackgroundTaskManager.shared.hasExecution(for:d.id))
  XCTAssertTrue(driver.process(d));XCTAssertEqual(BGTaskScheduler.shared.requests.count,before)
  XCTAssertTrue(BackgroundTaskManager.shared.hasExecution(for:d.id))
  BackgroundTaskManager.shared.stopTask(for:d.id,success:true)
 }
 @MainActor func testBackgroundBytesUpdateWithoutNativeGrant() {
  reset();let driver=Driver(),d=Download(),network=BackgroundFixture.NetworkTask();d.task=network;driver.start(d)
  UIApplication.shared.applicationState = .background
  driver.urlSession(driver._session,downloadTask:network,didWriteData:100,totalBytesWritten:500,totalBytesExpectedToWrite:1000)
  XCTAssertEqual(d.bytesDownloaded,500);XCTAssertEqual(d.progress,0.5)
  XCTAssertFalse(BackgroundTaskManager.shared.hasExecution(for:d.id));XCTAssertFalse(network.cancelled)
 }
 @MainActor func testUnrelatedGrantExpirationDoesNotPauseNetwork() async {
  reset();let driver=Driver(),d=Download(),network=BackgroundFixture.NetworkTask();d.task=network;driver.start(d)
  let manager=BackgroundTaskManager(),token=UUID().uuidString
  XCTAssertTrue(manager.startWork(for:token,title:"Other",subtitle:"Processing",progress:0,onExpiration:{}))
  let native=BGTaskScheduler.shared.launchLast();UIApplication.shared.applicationState = .background
  native.expirationHandler?();await settle()
  XCTAssertFalse(network.cancelled);XCTAssertEqual(d.state,.downloading)
 }
 @MainActor func testCompletionNotificationSubmitsWhileBackgrounded() async {
  reset();let driver=Driver(),d=Download();UIApplication.shared.applicationState = .background
  let center=BackgroundFixture.UNUserNotificationCenter.current(),before=center.requests.count
  driver.notify(d);await settle()
  XCTAssertEqual(center.requests.count,before+1)
  XCTAssertEqual(center.requests.last?.identifier,"Aether.download.result.\(d.id)")
  XCTAssertEqual(center.requests.last?.content.title,"Download complete")
  XCTAssertTrue(center.requests.last!.content.body.contains("finish importing"))
 }
 @MainActor func testFailureNotificationUsesSameResultIdentity() async {
  reset();let driver=Driver(),d=Download();UIApplication.shared.applicationState = .background
  let center=BackgroundFixture.UNUserNotificationCenter.current()
  driver.notifyFailure(d);await settle()
  XCTAssertEqual(center.requests.last?.identifier,"Aether.download.result.\(d.id)")
  XCTAssertEqual(center.requests.last?.content.title,"Download failed")
  XCTAssertEqual(center.requests.last?.content.body,"Connection lost")
 }
 @MainActor func testProcessingGrantReportsOnlyImportProgress() {
  reset();let driver=Driver(),d=Download();d.progress=1;driver.start(d)
  XCTAssertTrue(driver.process(d));let native=BGTaskScheduler.shared.launchLast()
  XCTAssertEqual(native.progress.fractionCompleted,0)
  d.unpackageProgress=0.5
  BackgroundTaskManager.shared.updateProgress(for:d.id,progress:d.backgroundProgress)
  XCTAssertEqual(native.progress.fractionCompleted,0.5)
  BackgroundTaskManager.shared.stopTask(for:d.id,success:true)
 }
 @MainActor func testNativeExpirationDefersProcessingAndKeepsRecoverableState() async {
  reset();let driver=Driver(),d=Download();driver.start(d);XCTAssertTrue(driver.process(d));let native=BGTaskScheduler.shared.launchLast()
  UIApplication.shared.applicationState = .background
  native.expirationHandler?();await settle()
  XCTAssertEqual(d.state,.processing);XCTAssertTrue(d.waitingForForeground);XCTAssertEqual(native.completions,[false])
 }
 @MainActor func testRemovedDownloadDoesNotResumeAfterPersistence() async {
  reset();let driver=Driver();driver.holdSave=true
  let start=Task { await driver.startDownload(from:URL(string:"https://example.com/App.ipa")!) }
  while driver.saveGate == nil { await settle() }
  let d=driver.downloads[0],network=d.task!;driver.downloads.removeAll()
  BackgroundTaskManager.shared.stopTask(for:d.id,success:false);driver.saveGate!.resume();_=await start.value
  XCTAssertFalse(network.resumed);XCTAssertTrue(network.cancelled)
 }
 @MainActor func testPauseBeforePersistenceCannotStartNetworkLater() async {
  reset();let driver=Driver();driver.holdSave=true
  let start=Task { await driver.startDownload(from:URL(string:"https://example.com/App.ipa")!) }
  while driver.saveGate == nil { await settle() }
  let d=driver.downloads[0],network=d.task!;driver.pauseDownload(d)
  network.pauseCallback?(nil);await settle();driver.saveGate!.resume();_=await start.value
  XCTAssertEqual(d.state,.paused);XCTAssertFalse(network.resumed)
 }
 @MainActor func testCancelledResumeCannotStartAfterDiskAwait() async {
  reset();let driver=Driver(),d=Download();d.state = .paused;d.resumeData=Data([1]);driver.downloads=[d];driver.holdSave=true
  let resume=Task { await driver.resumeDownload(d) }
  while driver.saveGate == nil { await settle() }
  let network=d.task!;driver.pauseDownload(d);driver.saveGate!.resume();await resume.value
  XCTAssertTrue(network.cancelled);XCTAssertFalse(network.resumed)
  BackgroundTaskManager.shared.stopTask(for:d.id,success:false)
 }
 @MainActor func testSigningInstallAndNextQueuedJobUseOneGrant() {
  reset();let operation=BackgroundFixture.AppOperationExecution()
  let initial=BGTaskScheduler.shared.requests.count
  operation.updateQueue(pendingJobs:1)
  XCTAssertTrue(operation.beginJob(title:"First",signing:true,onExpiration:{}))
  let task=BGTaskScheduler.shared.launchLast()
  operation.updateSigning(progress:1)
  XCTAssertEqual(task.progress.fractionCompleted,0.3,accuracy:0.00001)
  UIApplication.shared.applicationState = .background
  operation.updateInstallation(subtitle:"Packaging",progress:0.2)
  operation.updateQueue(pendingJobs:2)
  XCTAssertEqual(task.progress.fractionCompleted,0.22,accuracy:0.00001)
  operation.completeJob()
  operation.updateInstallation(subtitle:"Completed",progress:1) // delayed first-job publisher
  XCTAssertEqual(task.progress.fractionCompleted,0.5,accuracy:0.00001)
  operation.updateQueue(pendingJobs:1)
  XCTAssertTrue(operation.beginJob(title:"Second",signing:false,onExpiration:{}))
  operation.updateInstallation(subtitle:"Installing",progress:1)
  operation.completeJob();operation.finish(success:true)
  XCTAssertEqual(BGTaskScheduler.shared.requests.count,initial+1)
  XCTAssertEqual(task.completions,[true]);XCTAssertFalse(operation.hasExecution)
 }
 @MainActor func testQueueExpirationStopsAudioAndCannotRestartInBackground() async {
  reset();let operation=BackgroundFixture.AppOperationExecution();var expirations=0
  XCTAssertTrue(operation.beginJob(title:"Server",signing:false,onExpiration:{expirations+=1}))
  let task=BGTaskScheduler.shared.launchLast()
  operation.startServerAudio();operation.startServerAudio()
  XCTAssertEqual(BackgroundFixture.BackgroundAudioManager.shared.requesters.count,1)
  UIApplication.shared.applicationState = .background
  task.expirationHandler?();await settle()
  XCTAssertEqual(expirations,1);XCTAssertTrue(operation.isFinished)
  XCTAssertEqual(task.presentations.last,"Open Aether to resume")
  XCTAssertTrue(BackgroundFixture.BackgroundAudioManager.shared.requesters.isEmpty)
  XCTAssertFalse(operation.beginJob(title:"Next",signing:false,onExpiration:{}))
  XCTAssertEqual(task.completions,[false])
 }
 @MainActor func testQueueCancellingOneServerAudioPhaseDoesNotStopOtherRequesters() {
  reset();let audio=BackgroundFixture.BackgroundAudioManager.shared;audio.start("unrelated")
  let operation=BackgroundFixture.AppOperationExecution()
  XCTAssertTrue(operation.beginJob(title:"Server",signing:false,onExpiration:{}))
  operation.startServerAudio();operation.stopServerAudio()
  XCTAssertEqual(audio.requesters,["unrelated"])
  operation.finish(success:false);operation.finish(success:true)
  XCTAssertEqual(audio.requesters,["unrelated"]);audio.stop("unrelated")
 }
 @MainActor func testSigningOnlyUsesWholeProgressAndTerminalCompletionIsIdempotent() {
  reset();let operation=BackgroundFixture.AppOperationExecution()
  XCTAssertTrue(operation.beginJob(title:"Sign only",signing:true,installsAfterSigning:false,onExpiration:{}))
  let task=BGTaskScheduler.shared.launchLast()
  operation.updateSigning(progress:0.7)
  XCTAssertEqual(task.progress.fractionCompleted,0.7,accuracy:0.00001)
  operation.completeJob();operation.completeJob();operation.finish(success:true);operation.finish(success:false)
  XCTAssertEqual(task.completions,[true])
 }
 @MainActor func testLateLaunchCannotStealRetryProgressOrCompletion() {
  reset();let manager=BackgroundTaskManager(),token=UUID().uuidString
  XCTAssertTrue(manager.startWork(for:token,title:"First",subtitle:"Downloading",progress:0.1,onExpiration:{}))
  let oldID=BGTaskScheduler.shared.requests.last!;manager.stopTask(for:token,success:false)
  XCTAssertTrue(manager.startWork(for:token,title:"Retry",subtitle:"Downloading",progress:0.8,onExpiration:{}))
  let newID=BGTaskScheduler.shared.requests.last!;XCTAssertNotEqual(oldID,newID)
  let old=BGTaskScheduler.shared.launch(oldID);XCTAssertEqual(old.completions,[false])
  let current=BGTaskScheduler.shared.launch(newID);XCTAssertEqual(current.progress.fractionCompleted,0.8)
  manager.stopTask(for:token,success:true);XCTAssertEqual(current.completions,[true]);XCTAssertEqual(old.completions,[false])
 }
 @MainActor func testOldPauseCallbackCannotOverwriteNewTask() async {
  reset();let driver=Driver(),d=Download(),old=BackgroundFixture.NetworkTask();d.task=old;driver.start(d)
  driver.pauseDownload(d);let replacement=BackgroundFixture.NetworkTask();d.task=replacement
  old.pauseCallback?(Data([9]));await settle()
  XCTAssertTrue(d.task === replacement);XCTAssertNil(d.resumeData)
  BackgroundTaskManager.shared.stopTask(for:d.id,success:false)
 }
 @MainActor func testOldExpirationDoesNotInterruptRetry() async {
  reset();let manager=BackgroundTaskManager(),token=UUID().uuidString;var interruptions=0
  XCTAssertTrue(manager.startWork(for:token,title:"Old",subtitle:"Downloading",progress:0,onExpiration:{ interruptions+=1 }))
  let old=BGTaskScheduler.shared.launchLast();manager.stopTask(for:token,success:false)
  XCTAssertTrue(manager.startWork(for:token,title:"New",subtitle:"Downloading",progress:0,onExpiration:{ interruptions+=1 }))
  let current=BGTaskScheduler.shared.launchLast();old.expirationHandler?();await settle()
  XCTAssertEqual(interruptions,0);XCTAssertTrue(current.completions.isEmpty)
  manager.stopTask(for:token,success:true)
 }
 @MainActor func testCompletionBeforeLaunchFinishesLateTaskSuccessfully() {
  reset();let manager=BackgroundTaskManager(),token=UUID().uuidString
  XCTAssertTrue(manager.startWork(for:token,title:"App",subtitle:"Downloading",progress:0.9,onExpiration:{}))
  let id=BGTaskScheduler.shared.requests.last!;manager.stopTask(for:token,success:true)
  XCTAssertEqual(BGTaskScheduler.shared.launch(id).completions,[true])
 }
 @MainActor func testSmallProgressChangesRemainMeasurable() {
  reset();let manager=BackgroundTaskManager(),token=UUID().uuidString
  XCTAssertTrue(manager.startWork(for:token,title:"App",subtitle:"Downloading",progress:0,onExpiration:{}))
  let task=BGTaskScheduler.shared.launchLast();manager.updateProgress(for:token,progress:0.0007)
  XCTAssertEqual(task.progress.completedUnitCount,700);manager.stopTask(for:token,success:true)
 }
 @MainActor func testSchedulerDenialDoesNotAffectDownload() {
  reset();BGTaskScheduler.shared.reject=true;let driver=Driver(),d=Download(),network=BackgroundFixture.NetworkTask();d.task=network
  let before=BGTaskScheduler.shared.requests.count;driver.start(d)
  XCTAssertFalse(BackgroundTaskManager.shared.hasExecution(for:d.id))
  XCTAssertEqual(BGTaskScheduler.shared.requests.count,before)
  XCTAssertFalse(network.cancelled);XCTAssertEqual(d.state,.downloading)
 }
 @MainActor func testBackgroundRecoveryDoesNotSubmitNewUserRequest() {
  reset();UIApplication.shared.applicationState = .background
  let before=BGTaskScheduler.shared.requests.count,d=Download(),driver=Driver();driver.start(d);XCTAssertTrue(driver.process(d))
  XCTAssertEqual(BGTaskScheduler.shared.requests.count,before);XCTAssertTrue(BackgroundTaskManager.shared.hasExecution(for:d.id))
  BackgroundTaskManager.shared.stopTask(for:d.id,success:true)
 }
}
''')
signer=pathlib.Path('Aether/Utilities/Handlers/ZsignHandler.swift')
parts += [r'''
// Early native failures return false before invoking completion (e.g. unreadable key).
// Exercise the actual Swift methods so these failures cannot be committed as signed.
enum SigningFixture {
 struct Certificate { let provisionURL=URL(fileURLWithPath:"/profile");let certificateURL=URL(fileURLWithPath:"/key");let password="test" }
 struct Options { let appEntitlementsFile:URL?=nil;let removeProvisioning=false }
 enum SigningFileHandlerError:Error { case missingCertifcate,signFailed }
 enum Zsign {
  static var returnValue=false;static var invokeCallback=false
  static func sign(appPath:String,provisionPath:String="",p12Path:String="",p12Password:String="",entitlementsPath:String,adhoc:Bool=false,removeProvision:Bool,progress:((Double)->Void)?=nil,completion:((Bool)->Void)?)->Bool {
   if invokeCallback { completion?(returnValue) };return returnValue
  }
 }
 final class Handler {
  let _appUrl=URL(fileURLWithPath:"/App.app"),_options=Options();var _certificate:Certificate? = Certificate();var hadError:Error?
''',method(signer,'func sign(progress:'),method(signer,'func adhocSign() async throws'),r'''
 }
}
final class SigningReturnTests:XCTestCase {
 func testNativeFailureWithoutCompletionIsPropagated() async {
  SigningFixture.Zsign.returnValue=false;SigningFixture.Zsign.invokeCallback=false
  let handler=SigningFixture.Handler()
  do { try await handler.sign();XCTFail("Early failure must stop signing") } catch {}
  do { try await handler.adhocSign();XCTFail("Early failure must stop signing") } catch {}
 }
 func testSuccessfulNativeSigningStillCompletes() async throws {
  SigningFixture.Zsign.returnValue=true;SigningFixture.Zsign.invokeCallback=true
  let handler=SigningFixture.Handler();try await handler.sign();try await handler.adhocSign();XCTAssertNil(handler.hadError)
 }
}
''']
stored=(repo/'Aether/Backend/Observable/DownloadStore.swift').read_text()
stored=stored[stored.index('struct StoredDownload:'):stored.index('final class DownloadStore')]
parts += [r'''
enum DownloadMigrationFixture {
 struct SourceAppProvenance:Codable,Sendable {}
 final class Download {
  enum FailureAction:String,Codable,Sendable { case resume,restart,retryProcessing }
  enum State:Equatable { case downloading,pausing,paused,resuming,processing,failed(String,FailureAction) }
  let logicalIdentifier="app-v2",id="transfer",importIdentifier="import",url=URL(string:"https://example.com/app.ipa")!,fileName="App.ipa"
  let sourceProvenance:SourceAppProvenance?=nil,stagedFileName:String?="staged.ipa"
  var waitingForForeground=false,bytesDownloaded:Int64=1024,totalBytes:Int64=2048,progress=0.5
  var state:State = .processing
 }
''',stored,r'''
}
final class DownloadMigrationTests:XCTestCase {
 @MainActor func testRetiredUpdateIntentDoesNotLoseDownloadStateAndIsNotSavedAgain() throws {
  let initial=DownloadMigrationFixture.StoredDownload(download:DownloadMigrationFixture.Download())
  let encoded=try JSONEncoder().encode(initial)
  for status in ["downloading","paused","processing","failed"] {
   var object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
   object["status"]=status
   object["automaticUpdate"]=["bundleIdentifier":"example.app","signedUUID":"old-signed","installationEnqueued":false]
   let legacy=try JSONSerialization.data(withJSONObject:object)
   let migrated=try JSONDecoder().decode(DownloadMigrationFixture.StoredDownload.self,from:legacy)
   XCTAssertEqual(migrated.transferIdentifier,"transfer");XCTAssertEqual(migrated.importIdentifier,"import")
   XCTAssertEqual(migrated.stagedFileName,"staged.ipa");XCTAssertEqual(migrated.bytesDownloaded,1024)
   XCTAssertEqual(migrated.status.rawValue,status)
   if status=="failed" { XCTAssertEqual(migrated.state(hasResumeData:true),.failed("Download Failed",.retryProcessing)) }
   let saved=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(migrated)) as? [String:Any])
   XCTAssertNil(saved["automaticUpdate"])
  }
 }
}
''']
(out/'BackgroundOwnershipTests.swift').write_text('\n'.join(parts))
