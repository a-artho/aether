"""Exercise the production import gate and worker with controlled file-stage doubles."""
from pathlib import Path
import sys
repo=Path(__file__).resolve().parents[2]
out=Path(sys.argv[1])
def decl(path, marker):
 s=(repo/path).read_text();a=s.index(marker);b=(s.index(') -> Task<Void, Never> {',a)+len(') -> Task<Void, Never> {') if marker=='static func handlePackageFile(' else s.index('{',a)+1);n=1
 while n:n+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
gate=decl('Aether/Utilities/FR.swift','private actor PackageProcessingGate').replace('private actor PackageProcessingGate','actor ImportProcessingGate',1)
worker=decl('Aether/Utilities/FR.swift','static func handlePackageFile(')
report=decl('Aether/Utilities/Handlers/AppFileHandler.swift','private func reportProgress(').replace('private func','func',1)
source=r'''
import Foundation
import XCTest
actor FileStageGate {
 var continuation:CheckedContinuation<Void,Never>?
 var shouldPause=true
 func pause() async {
  if shouldPause { await withCheckedContinuation { continuation=$0 } }
 }
 func isWaiting()->Bool {continuation != nil}
 func release(){shouldPause=false;continuation?.resume();continuation=nil}
}
@MainActor enum ImportFixture {
 struct Download:Sendable {let importIdentifier="import"}
 struct SourceAppProvenance:Sendable {}
 final class DebugLogManager {
  enum Level {case info,error};static let shared=DebugLogManager();let isLoggingEnabled=false
  func log(_ text:String,category:String,level:Level){}
 }
 typealias DebugLogItem=DebugLogManager
 final class UIApplication {static let shared=UIApplication();enum State:Int{case active};let applicationState=State.active}
 class AppFileHandler:@unchecked Sendable {
  static var control=FileStageGate();static var preparations=0;static var commits=0
  @MainActor init(file:URL,download:Download?,sourceProvenance:SourceAppProvenance?,transactionIdentifier:String?){}
  func recoverCommittedImport() async throws -> Bool {false}
  func prepare(copySource:Bool) async throws {await MainActor.run{Self.preparations+=1};await Self.control.pause()}
  func extract() async throws {try Task.checkCancellation()}
  func move() async throws {try Task.checkCancellation()}
  func addToDatabase() async throws {try Task.checkCancellation();await MainActor.run{Self.commits+=1}}
  func clean() async throws {}
 }
 enum FR {
  nonisolated static let packageProcessingGate=ImportProcessingGate()
 WORKER
 }
}
final class ImportExecutionTests:XCTestCase {
 @MainActor func testQueuedImportCannotAcquireExecutionBeforeGateAndCancellationSkipsIt() async throws {
  ImportFixture.AppFileHandler.control=FileStageGate();ImportFixture.AppFileHandler.preparations=0;ImportFixture.AppFileHandler.commits=0
  var executionRequests=0;var completed=0;var queuedReleases=0
  let first=ImportFixture.FR.handlePackageFile(URL(fileURLWithPath:"/first.ipa"),beginProcessing:{executionRequests+=1;return true},waitingForProcessing:{queuedReleases+=1}){_ in completed+=1}
  while !(await ImportFixture.AppFileHandler.control.isWaiting()){await Task.yield()}
  let second=ImportFixture.FR.handlePackageFile(URL(fileURLWithPath:"/second.ipa"),beginProcessing:{executionRequests+=1;return true},waitingForProcessing:{queuedReleases+=1}){_ in completed+=1}
  while queuedReleases == 0 {await Task.yield()}
  XCTAssertEqual(queuedReleases,1,"Only the waiting import releases its execution")
  XCTAssertEqual(executionRequests,1)
  second.cancel();await second.value
  XCTAssertEqual(executionRequests,1)
  await ImportFixture.AppFileHandler.control.release();await first.value
  XCTAssertEqual(completed,2);XCTAssertEqual(ImportFixture.AppFileHandler.commits,1)
 }
 @MainActor func testMissingExecutionDoesNotStartFileOperationsAndReleasesGate() async {
  ImportFixture.AppFileHandler.control=FileStageGate();await ImportFixture.AppFileHandler.control.release()
  ImportFixture.AppFileHandler.preparations=0;ImportFixture.AppFileHandler.commits=0
  var rejected=false
  let denied=ImportFixture.FR.handlePackageFile(URL(fileURLWithPath:"/denied.ipa"),beginProcessing:{false}){error in rejected=error is CancellationError}
  await denied.value
  XCTAssertTrue(rejected);XCTAssertEqual(ImportFixture.AppFileHandler.preparations,0)
  let next=ImportFixture.FR.handlePackageFile(URL(fileURLWithPath:"/next.ipa"),beginProcessing:{true}){_ in}
  await next.value
  XCTAssertEqual(ImportFixture.AppFileHandler.commits,1)
 }
}
enum ImportProgressFixture {
 @MainActor final class Download {var unpackageProgress=0.0;var backgroundProgress:Double{unpackageProgress};let id="import"}
 @MainActor final class BackgroundTaskManager {static let shared=BackgroundTaskManager();var values=[Double]();func updateProgress(for id:String,progress:Double){values.append(progress)}}
 final class Handler {
  let _download:Download?
  init(_ download:Download){_download=download}
 REPORT
 }
}
final class ImportProgressTests:XCTestCase {
 @MainActor func testLateExtractionCannotRewindCommitAndWorkerCannotPublishCompletion() async {
  let download=ImportProgressFixture.Download()
  let actual=ImportProgressFixture.Handler(download)
  await actual.reportProgress(0.95);await actual.reportProgress(0.4)
  XCTAssertEqual(download.unpackageProgress,0.95)
  await actual.reportProgress(1)
  XCTAssertEqual(download.backgroundProgress,0.99)
 }
}
'''
(out/'ImportExecutionTests.swift').write_text(source.replace('WORKER',worker).replace('REPORT',report)+'\n'+gate)
