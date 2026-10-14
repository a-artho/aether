"""Exercise production selection, queue and icon publication with controlled dependencies."""
import pathlib, sys
repo = pathlib.Path(__file__).resolve().parents[2]

def method(path, signature):
    source = (repo / path).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func').replace('private var', 'var') + '\n'

manager = 'Aether/Backend/Observable/AppInstallationManager.swift'
icon = method('Aether/Views/Library/LibraryView.swift', 'private func loadIcon() async')
icon = icon.replace('InstallationAppProxy', 'UIIconProxy').replace('withAnimation(.easeIn(duration: 0.15))', 'do')
source = r'''
import Foundation
import XCTest
@MainActor private final class PendingFixture {
 struct Request {}
 enum Failure:Error { case failed }
 enum Status { case signing,installing,broken,completed(Result<Void,Failure>) }
 final class Model { var status:Status = .installing }
 var currentRequest:Request?;var queuedInstalls:[Request]=[];var viewModel:Model?=Model()
 var retirementTask:Task<Void,Never>?;var iDevicePreflightTask:Task<Void,Never>?;var installTask:Task<Void,Never>?
 var activeApp:String?
''' + method(manager, 'var isInstalling:') + method(manager, 'private var hasCompletedSuccessfully:') + method(manager, 'var hasPendingInstalls:') + r'''
}
@MainActor private enum UIIconProxy {
 static var replies:[String:CheckedContinuation<String?,Never>]=[:]
 static func getAppIconCached(for id:String,cacheVersion:String) async throws -> String? {
  await withCheckedContinuation { replies[cacheVersion]=$0 }
 }
}
@MainActor private final class IconViewFixture {
 let bundleIdentifier="app";var cacheVersion="old";let loadsIcon=true;var image:String?
''' + icon + r'''
}
final class UIStateRegressionTests:XCTestCase {
 @MainActor func testFailedRequestRemainsPendingUntilCancelAndSuccessDoesNotBlockMode() {
  let fixture=PendingFixture()
  fixture.currentRequest = .init();fixture.activeApp="app";fixture.viewModel?.status = .broken
  XCTAssertFalse(fixture.isInstalling);XCTAssertTrue(fixture.hasPendingInstalls)
  fixture.viewModel?.status = .completed(.success(()))
  XCTAssertFalse(fixture.hasPendingInstalls)
  fixture.currentRequest=nil;fixture.activeApp=nil
  XCTAssertFalse(fixture.hasPendingInstalls)
  fixture.queuedInstalls=[.init()];XCTAssertTrue(fixture.hasPendingInstalls)
 }
 @MainActor func testCancelledOldIconReplyCannotOverwriteNewImage() async {
  UIIconProxy.replies=[:]
  let fixture=IconViewFixture(),old=Task { await fixture.loadIcon() }
  while UIIconProxy.replies["old"] == nil { await Task.yield() }
  old.cancel();fixture.cacheVersion="new"
  let new=Task { await fixture.loadIcon() }
  while UIIconProxy.replies["new"] == nil { await Task.yield() }
  UIIconProxy.replies.removeValue(forKey:"new")!.resume(returning:"new-image");await new.value
  UIIconProxy.replies.removeValue(forKey:"old")!.resume(returning:"old-image");await old.value
  XCTAssertEqual(fixture.image,"new-image")
 }
}
'''
pathlib.Path(sys.argv[1], 'UIStateRegressionTests.swift').write_text(source)
