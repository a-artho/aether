"""Exercise production gate, progress delivery and staging recovery with platform doubles."""
import pathlib,sys
repo=pathlib.Path(__file__).resolve().parents[2]
out=pathlib.Path(sys.argv[1])
fr=(repo/'Aether/Utilities/FR.swift').read_text()
gate=fr[fr.index('private actor PackageProcessingGate'):fr.index('\n@MainActor\nenum FR')].replace('private actor','actor',1)
proxy=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift').read_text()
publisher=proxy[proxy.index('private final class UploadProgressPublisher'):proxy.index('\npublic class InstallationProxy')].replace('private final class','final class',1)
store=(repo/'Aether/Backend/Observable/DownloadStore.swift').read_text()
store=store[store.index('struct StoredDownload:'):]
store=store.replace('private var rootURL: URL {\n\t\tfileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]\n\t\t\t.appendingPathComponent("AetherDownloads", isDirectory: true)\n\t}', 'let rootURL: URL\n init(rootURL: URL) { self.rootURL = rootURL }')
def declaration(start):
 text=(repo/'Aether/Backend/Observable/AppInstallationManager.swift').read_text()
 p=text.index(start); b=text.index('{',p); e=b+1; n=1
 while n: n+=(text[e]=='{')-(text[e]=='}');e+=1
 return text[p:e].replace('private struct','struct',1)
queue_models=(repo/'Aether/Utilities/SelfUpdateAttempt.swift').read_text()+'''
enum QueuePersistenceFixture {
 struct AppSnapshot: Codable { let uuid: String }
 struct Options: Codable, Sendable { let post_installAppAfterSigned: Bool }
'''+declaration('struct SigningInput:')+'\n'+declaration('private struct StoredInstallation:')+'\n}\n'
fixture=r'''
struct SourceAppProvenance: Codable, Sendable {}
final class Download {
 enum FailureAction: String, Codable, Sendable { case resume, restart, retryProcessing }
 enum State: Equatable { case downloading, pausing, paused, resuming, processing, failed(String, FailureAction) }
 let id: String, logicalIdentifier: String, url: URL, importIdentifier: String
 let fileName: String
 let onlyArchiving:Bool
 var sourceProvenance: SourceAppProvenance?, state: State, stagedFileName: String?
 var waitingForForeground=false, resumeData: Data?, bytesDownloaded: Int64=0, totalBytes: Int64=0, progress=0.0
 init(transferIdentifier: String="transfer", logicalIdentifier: String="logical", url: URL=URL(string:"https://example.com/app.ipa")!, onlyArchiving:Bool=false, sourceIsStable:Bool=false, sourceProvenance: SourceAppProvenance?=nil, state: State = .downloading, fileName: String="App.ipa", stagedFileName: String?=nil, importIdentifier: String="import") {
  self.onlyArchiving=onlyArchiving; id=transferIdentifier; self.logicalIdentifier=logicalIdentifier; self.url=url; self.sourceProvenance=sourceProvenance; self.state=state; self.fileName=fileName; self.stagedFileName=stagedFileName; self.importIdentifier=importIdentifier
 }
}
final class CorrectionTests: XCTestCase {
 func testCancelledGateWaiterCompletesBeforeOwnerReleases() async throws {
  let gate=PackageProcessingGate(); try await gate.acquire()
  let cancelled=expectation(description:"cancelled waiter returned")
  let waiter=Task {
   do { try await gate.acquire(); await gate.release(); XCTFail("Cancelled waiter acquired gate") }
   catch { XCTAssertTrue(error is CancellationError); cancelled.fulfill() }
  }
  try await Task.sleep(nanoseconds:20_000_000); waiter.cancel()
  await fulfillment(of:[cancelled],timeout:1)
  await gate.release(); await waiter.value
  try await gate.acquire(); await gate.release()
 }
 func testGateCancellationAfterOwnershipTransferDoesNotStrandNextWaiter() async throws {
  let gate=PackageProcessingGate(); try await gate.acquire()
  let waiter=Task {
   do { try await gate.acquire(); defer { Task { await gate.release() } }; try Task.checkCancellation() }
   catch {}
  }
  try await Task.sleep(nanoseconds:20_000_000)
  await gate.release(); waiter.cancel(); await waiter.value
  let acquired=expectation(description:"next waiter acquired")
  let next=Task { try await gate.acquire(); acquired.fulfill(); await gate.release() }
  await fulfillment(of:[acquired],timeout:1); try await next.value
 }
 @MainActor func testProgressBurstCoalescesAndClosedDeliveryCannotOverwriteTerminalState() async {
  var values:[Double]=[]
  let publisher=UploadProgressPublisher { values.append($0) }
  for n in 1...1000 { publisher.submit(Double(n)/1000) }
  XCTAssertTrue(values.isEmpty)
  publisher.finish()
  XCTAssertEqual(values,[1])
  publisher.submit(0.2)
  await Task.yield(); XCTAssertEqual(values,[1])
  let cancelled=UploadProgressPublisher { values.append($0) }
  cancelled.submit(0.5); cancelled.cancel()
  await Task.yield(); XCTAssertEqual(values,[1])
 }
 func testQueuedSigningRestoresOptionsAndSignOnlyIntent() throws {
  let input=QueuePersistenceFixture.SigningInput(options:.init(post_installAppAfterSigned:false),iconData:Data([1,2]),certificateUUID:"certificate")
  let original=QueuePersistenceFixture.StoredInstallation(app:.init(uuid:"imported"),method:0,serverMethod:1,signing:input,installRequested:false)
  let restored=try JSONDecoder().decode(QueuePersistenceFixture.StoredInstallation.self,from:JSONEncoder().encode(original))
  XCTAssertEqual(restored.installRequested,false)
  XCTAssertEqual(restored.signing?.options.post_installAppAfterSigned,false)
  XCTAssertEqual(restored.signing?.iconData,Data([1,2]));XCTAssertEqual(restored.signing?.certificateUUID,"certificate")
 }
 @MainActor func testMovedIPARecoversBeforePruningWithoutNewMetadataCommit() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store=DownloadStore(rootURL:root), download=Download()
  try store.save(records:[StoredDownload(download:download)])
  let ipa=try store.makeStagingURL(for:download,suggestedFilename:"app.ipa")
  try Data("completed archive".utf8).write(to:ipa)
  let unrelated=try store.makeStagingURL(for:Download(transferIdentifier:"different"),suggestedFilename:"app.ipa")
  try Data().write(to:unrelated)
  let restored=store.loadDownloads(); store.pruneArtifacts(keeping:restored)
  XCTAssertEqual(restored.first?.state,.processing)
  XCTAssertEqual(restored.first?.stagedFileName,ipa.lastPathComponent)
  XCTAssertTrue(FileManager.default.fileExists(atPath:ipa.path))
  XCTAssertFalse(FileManager.default.fileExists(atPath:unrelated.path))
 }

 @MainActor func testManualImportStagedInputSurvivesRelaunchAndPruning() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store=DownloadStore(rootURL:root), download=Download(onlyArchiving:true,state:.processing)
  try store.save(records:[StoredDownload(download:download)])
  let ipa=try store.makeStagingURL(for:download,suggestedFilename:"manual.ipa")
  try Data("manual archive".utf8).write(to:ipa)
  let restored=store.loadDownloads();store.pruneArtifacts(keeping:restored)
  XCTAssertEqual(restored.first?.onlyArchiving,true)
  XCTAssertEqual(restored.first?.state,.processing)
  XCTAssertEqual(restored.first?.stagedFileName,ipa.lastPathComponent)
  XCTAssertTrue(FileManager.default.fileExists(atPath:ipa.path))
  store.cleanupArtifacts(for:restored[0])
  XCTAssertFalse(FileManager.default.fileExists(atPath:ipa.path))
 }
 @MainActor func testRecoveryDoesNotAdoptSymlinkOrOverridePausedIntent() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store=DownloadStore(rootURL:root), download=Download()
  try store.save(records:[StoredDownload(download:download)])
  let ipa=try store.makeStagingURL(for:download,suggestedFilename:"app.ipa")
  let external=root.appendingPathComponent("external"); try Data().write(to:external)
  try FileManager.default.createSymbolicLink(at:ipa,withDestinationURL:external)
  XCTAssertNil(store.loadDownloads().first?.stagedFileName)
  try FileManager.default.removeItem(at:ipa); try Data().write(to:ipa)
  download.state = .paused; try store.save(records:[StoredDownload(download:download)])
  XCTAssertEqual(store.loadDownloads().first?.state,.paused)
  XCTAssertNil(store.loadDownloads().first?.stagedFileName)
 }
}
'''
(out/'CorrectionTests.swift').write_text('import Foundation\nimport CryptoKit\nimport XCTest\n'+gate+publisher+store+queue_models+fixture)
