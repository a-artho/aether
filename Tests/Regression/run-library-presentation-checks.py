#!/usr/bin/env python3
"""Exercise production update lifecycle and presentation state without SwiftUI."""
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[2]
def declaration(path, marker):
    source = (repo / path).read_text()
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)
library = 'Aether/Backend/Observable/LibraryUpdatesStore.swift'
source = '''import Foundation
import Combine
struct Animation {
 static func easeIn(duration: Double) -> Self { Self() }
 static func easeOut(duration: Double) -> Self { Self() }
}
@MainActor func withAnimation(_ animation: Animation?, _ action: () -> Void) { action() }
struct Transaction { var disablesAnimations = false; init(animation: Animation?) {} }
@MainActor func withTransaction(_ transaction: Transaction, _ action: () -> Void) { action() }
struct SourceAppCatalogContext: Equatable {
 let id: String
 var sourceObjectURI: String { id }
 var sourceURL: URL? { nil }
 var revision: String { id }
}
enum Level { case error }
@MainActor final class DebugLogManager {
 static let shared = DebugLogManager()
 func log(_ message: String, category: String, level: Level) {}
}
actor InstalledAppUpdateCatalog {
 static let shared = InstalledAppUpdateCatalog()
 var calls = 0
 var result: [String: [SourceAppCatalogContext]] = [:]
 var pause = false
 var waiter: CheckedContinuation<Void, Never>?
 func configure(_ result: [String: [SourceAppCatalogContext]], pause: Bool = false) { self.result = result; self.pause = pause }
 func resume() { waiter?.resume(); waiter = nil; pause = false }
 func updates(installedVersions: [String: String], contexts: [SourceAppCatalogContext], ignoredIdentifiers: Set<String>) async throws -> [String: [SourceAppCatalogContext]] {
  calls += 1
  if pause { await withCheckedContinuation { waiter = $0 } }
  return result
 }
}
enum DeviceConnectionState { case connected, disconnecting, disconnected }
@MainActor final class DeviceConnectionManager {
 static let shared = DeviceConnectionManager()
 @Published var state = DeviceConnectionState.connected
}
struct AltSource {}
@MainActor final class SourcesViewModel {
 static let shared = SourcesViewModel()
 var calls = 0
 var waiter: CheckedContinuation<Void, Never>?
 func startRefresh(_ sources: [AltSource]) -> Task<Void, Never> {
  calls += 1
  return Task { await withCheckedContinuation { waiter = $0 } }
 }
 func finish() { waiter?.resume(); waiter = nil }
}
@MainActor final class InstalledAppsStore {
 static let shared = InstalledAppsStore()
 var calls = 0
 func invalidateConnection() {}
 func refresh(force: Bool) async { calls += 1 }
}
@MainActor final class Updates {
 var connectionObservation: AnyCancellable?
 var sources: [AltSource] = []
 var refreshTask: Task<Void, Never>?
 var refreshInProgress = false
 var updateContexts: [String: [SourceAppCatalogContext]] = [:]
 var showsAppRefresh = false
 var updateIndicatorStarted: ContinuousClock.Instant?
 var deviceRevision = 0
 var hasVerifiedUpdates = false
 var isMatching = false
 var awaitingMatch = true
 var verificationGeneration = UUID()
 var checkID: UUID?
 var lastMatchedInputs: [String]?
 var noUpdatesUntil: Date?
 var isCheckingForUpdates = false
 var higherPriority = false
 var updateIndicatorRequest: [Bool] { [isCheckingForUpdates, higherPriority] }
'''
source += declaration(library, 'init()') + '\n'
source += declaration(library, 'private func beginConnectedRefreshPresentation()') + '\n'
source += declaration(library, 'func updateRefreshIndicator(checking:') + '\n'
source += declaration(library, 'func invalidateVerification()') + '\n'
source += declaration(library, 'func matchUpdates(') + '\n'
source += declaration(library, 'func startRefresh()') + '\n'
source += 'func updateRefreshIndicator() async { await updateRefreshIndicator(checking: isCheckingForUpdates, higherPriority: higherPriority) }\n'
source += declaration(library, 'private func publishUpdateMatches(') + '\n}\n'
source += '''@main struct Checks {
 @MainActor static func main() async throws {
  let updates = Updates()
  let old = SourceAppCatalogContext(id: "old"), fresh = SourceAppCatalogContext(id: "fresh")
  updates.updateContexts = ["app": [old]]
  updates.isCheckingForUpdates = true
  await updates.updateRefreshIndicator()
  precondition(updates.showsAppRefresh && updates.updateContexts["app"] == [old], "Checking must not clear known rows")
  updates.publishUpdateMatches(["app": [], "new": [fresh]], complete: false)
  precondition(updates.updateContexts["app"] == [old] && updates.updateContexts["new"] == [fresh], "Partial checks retain old updates and publish new ones immediately")
  updates.isCheckingForUpdates = false
  let started = updates.updateIndicatorStarted!
  await updates.updateRefreshIndicator()
  precondition(started.duration(to: .now) >= .seconds(0.5), "Fast checks must display the indicator for at least half a second")
  precondition(!updates.showsAppRefresh && updates.updateContexts["new"] == [fresh])
  updates.publishUpdateMatches([:], complete: true)
  precondition(updates.updateContexts.isEmpty, "A successful empty result removes old updates")
  updates.isCheckingForUpdates = true
  await updates.updateRefreshIndicator()
  updates.isCheckingForUpdates = false
  let retiring = Task { await updates.updateRefreshIndicator() }
  await Task.yield()
  retiring.cancel()
  updates.isCheckingForUpdates = true
  await updates.updateRefreshIndicator()
  await retiring.value
  precondition(updates.showsAppRefresh, "An old canceled dismissal cannot hide a newer check")
  updates.higherPriority = true
  await updates.updateRefreshIndicator()
  precondition(!updates.showsAppRefresh && updates.updateIndicatorStarted == nil, "Connection/failure status overrides the minimum")
  updates.higherPriority = false
  await updates.updateRefreshIndicator()
  updates.updateIndicatorStarted = ContinuousClock.now.advanced(by: .seconds(-1))
  updates.isCheckingForUpdates = false
  await updates.updateRefreshIndicator()
  precondition(!updates.showsAppRefresh, "A slow check adds no extra hold")
  let catalog = InstalledAppUpdateCatalog.shared
  let lifecycle = Updates()
  await catalog.configure(["app": [fresh]])
  await lifecycle.matchUpdates(versions: ["app": "1"], contexts: [fresh], ignored: [], complete: true)
  precondition(lifecycle.hasVerifiedUpdates && lifecycle.updateContexts["app"] == [fresh])
  let firstCalls = await catalog.calls
  await lifecycle.matchUpdates(versions: ["app": "1"], contexts: [fresh], ignored: [], complete: true)
  let duplicateCalls = await catalog.calls
  precondition(duplicateCalls == firstCalls, "Reappearing tabs and identical inputs must not scan again")
  let beforeDisconnect = lifecycle.deviceRevision
  DeviceConnectionManager.shared.state = .disconnecting
  precondition(lifecycle.deviceRevision != beforeDisconnect && !lifecycle.hasVerifiedUpdates, "Connection publication invalidates synchronously without a SwiftUI redraw")
  DeviceConnectionManager.shared.state = .connected
  precondition(!lifecycle.hasVerifiedUpdates, "Reconnecting does not validate updates before a fresh device browse")
  precondition(lifecycle.showsAppRefresh && lifecycle.updateIndicatorStarted != nil,
   "Reconnecting immediately presents the installed-app refresh while freshness is revalidated")
  lifecycle.invalidateVerification()
  precondition(!lifecycle.hasVerifiedUpdates && lifecycle.updateContexts["app"] == [fresh], "Idle invalidation hides results synchronously without dropping the cache")
  await lifecycle.matchUpdates(versions: ["app": "1"], contexts: [fresh], ignored: [], complete: true)
  precondition(lifecycle.hasVerifiedUpdates, "A fresh browse can validate an unchanged result")
  let revalidatedCalls = await catalog.calls
  precondition(revalidatedCalls == firstCalls, "Revalidation of unchanged catalogs/versions reuses matches")
  await catalog.configure(["stale": [old]], pause: true)
  let stale = Task { await lifecycle.matchUpdates(versions: ["app": "2"], contexts: [fresh], ignored: [], complete: true) }
  while await catalog.waiter == nil { await Task.yield() }
  lifecycle.invalidateVerification()
  await catalog.resume()
  await stale.value
  precondition(!lifecycle.hasVerifiedUpdates && lifecycle.updateContexts["stale"] == nil, "A pre-disconnect check cannot publish into a newer lifecycle")
  await catalog.configure([:])
  await lifecycle.matchUpdates(versions: ["app": "3"], contexts: [fresh], ignored: [], complete: false)
  precondition(!lifecycle.hasVerifiedUpdates && lifecycle.updateContexts["app"] == [fresh], "A partial refresh cannot validate stale updates")
  await lifecycle.matchUpdates(versions: ["app": "3"], contexts: [fresh], ignored: [], complete: true)
  precondition(lifecycle.hasVerifiedUpdates && lifecycle.updateContexts.isEmpty, "A complete empty refresh replaces old matches")
  lifecycle.invalidateVerification()
  await lifecycle.matchUpdates(versions: ["app": "3"], contexts: [fresh], ignored: [], complete: true)
  precondition(lifecycle.hasVerifiedUpdates && lifecycle.noUpdatesUntil != nil, "Cached empty revalidation still announces No Updates Available")
  lifecycle.noUpdatesUntil = nil
  await lifecycle.matchUpdates(versions: ["app": "3"], contexts: [fresh], ignored: [], complete: true)
  precondition(lifecycle.noUpdatesUntil == nil, "Unchanged verified inputs must not replay the announcement")
  await catalog.configure(["app": [fresh]], pause: true)
  let canceledMatch = Task { await lifecycle.matchUpdates(versions: ["app": "4"], contexts: [fresh], ignored: [], complete: true) }
  while await catalog.waiter == nil { await Task.yield() }
  canceledMatch.cancel()
  await catalog.resume()
  await canceledMatch.value
  precondition(!lifecycle.isMatching && lifecycle.updateContexts.isEmpty, "Canceled checks stop progress and cannot publish")
  let manual = Updates()
  manual.awaitingMatch = false
  manual.startRefresh(); manual.startRefresh()
  precondition(manual.awaitingMatch, "Manual refresh requests result validation even when catalogs remain unchanged")
  precondition(manual.refreshInProgress && SourcesViewModel.shared.calls == 1, "Repeated pulls synchronously share one refresh owner")
  while SourcesViewModel.shared.waiter == nil { await Task.yield() }
  let pendingRefresh = manual.refreshTask!
  SourcesViewModel.shared.finish()
  await pendingRefresh.value
  precondition(!manual.refreshInProgress && manual.refreshTask == nil && InstalledAppsStore.shared.calls == 1, "Manual refresh finishes both repositories and installed apps once")
  print("Library lifecycle, deduplication, freshness, refresh ownership checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-library-presentation-') as folder:
    root = Path(folder)
    swift = root / 'Checks.swift'
    swift.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(root / 'checks')], check=True)
    subprocess.run([str(root / 'checks')], check=True, timeout=15)
