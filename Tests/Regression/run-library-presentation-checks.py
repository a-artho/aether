#!/usr/bin/env python3
"""Run the production Library coordinator against controllable service publishers."""
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[2]
production = (repo / 'Aether/Backend/Observable/LibraryUpdatesStore.swift').read_text()
production = production[production.index('@MainActor\nfinal class LibraryUpdatesStore:'):production.index('/// The app shell forwards')]
production = production.replace('private(set) ', '').replace('private ', '')
stubs = r'''
import Foundation
import Combine
struct Transaction { var disablesAnimations = false; init(animation: Any?) {} }
@MainActor func withTransaction(_ transaction: Transaction, _ action: () -> Void) { action() }
struct ObjectID { let id: String; func uriRepresentation() -> URL { URL(string: "source://" + id)! } }
struct AltSource { let objectID = ObjectID(id: "one"); let sourceURL = URL(string: "https://test.invalid/repo") }
enum AetherBuiltInRepository {
 static let key = "builtin:aether"
 static let url = URL(string: "https://test.invalid/aether")!
}
struct Repository {}
struct SourceAppCatalogContext: Equatable {
 let sourceObjectURI: String; let sourceURL: URL?; let revision: String
 init(sourceObjectURI: String, sourceURL: URL?, repository: Repository, revision: String) {
  self.sourceObjectURI = sourceObjectURI; self.sourceURL = sourceURL; self.revision = revision
 }
}
enum Level { case error }
@MainActor final class DebugLogManager {
 static let shared = DebugLogManager()
 func log(_ message: String, category: String, level: Level) {}
}
enum DeviceConnectionState { case connected, connecting, disconnecting, disconnected }
@MainActor final class DeviceConnectionManager: ObservableObject {
 static let shared = DeviceConnectionManager()
 @Published var state = DeviceConnectionState.connected
 var isConnected: Bool { state == .connected }
 var isUpdating: Bool { state == .connecting || state == .disconnecting }
 var isAwaitingAutomaticConnection = false
 var isDisconnectWhenIdleEnabled = false
 var hasActiveTunnelDependencies = false
 var automatic = true
 enum Method {case inApp,localDevVPN};var tunnelMethod=Method.inApp
 var connections = 0
 func connectAutomaticallyIfNeeded() {
  guard automatic, state == .disconnected else { return }
  connections += 1; state = .connecting
  Task { await Task.yield(); self.state = .connected }
 }
 func verifyForAppRefresh() async -> Bool {
  connectAutomaticallyIfNeeded()
  while isUpdating && !Task.isCancelled {await Task.yield()}
  return !Task.isCancelled && isConnected
 }
}
@MainActor final class CellularAssistManager: ObservableObject {
 static let shared = CellularAssistManager()
 @Published var isBusy = false
}
@MainActor final class IgnoredAppUpdates: ObservableObject {
 static let shared = IgnoredAppUpdates()
 @Published var identifiers: Set<String> = []
}
@MainActor final class SourcesViewModel: ObservableObject {
 static let shared = SourcesViewModel()
 @Published var catalogRevision = 0
 @Published var isFinished = true
 @Published var isRefreshRequested = false
 var refreshErrors: [String: String] = [:]
 var calls = 0
 var lastUpdated: Date?
 var pause = false
 var waiter: CheckedContinuation<Void, Never>?
 var builtInContext: SourceAppCatalogContext?
 var task: Task<Void, Never>?
 func repository(for source: AltSource) -> Repository? { calls > 0 ? Repository() : nil }
 func revision(for source: AltSource) -> String { String(catalogRevision) }
 func builtInAetherUpdateContext(installedBundleIdentifier: String?) -> SourceAppCatalogContext? {
  guard installedBundleIdentifier != nil else { return nil }
  return builtInContext
 }
 func startRefresh(_ sources: [AltSource]) -> Task<Void, Never> {
  if let task { return task }
  calls += 1; isRefreshRequested = true; isFinished = false
  let work = Task { @MainActor in
   if pause { await withCheckedContinuation { waiter = $0 } }
   else { await Task.yield() }
   catalogRevision += 1; lastUpdated = .now
   task = nil; isFinished = true; isRefreshRequested = false
  }
  task = work
  return work
 }
 func refreshIfNeeded(_ sources: [AltSource]) async {
  if lastUpdated == nil || Date().timeIntervalSince(lastUpdated!) >= 120 { await startRefresh(sources).value }
 }
 func finish() { pause = false; waiter?.resume(); waiter = nil }
}
struct InstalledApp: Equatable { let bundleIdentifier: String; let version: String? }
@MainActor final class InstalledAppsStore: ObservableObject {
 static let shared = InstalledAppsStore()
 @Published var apps: [InstalledApp] = []
 @Published var isLoading = false
 @Published var hasLoadedApps = false
 @Published var errorMessage: String?
 var next = [InstalledApp(bundleIdentifier: "app", version: "1")]
 var calls = 0
 var lastUpdated: Date?
 var pause = false
 var waiter: CheckedContinuation<Void, Never>?
 func invalidateConnection() { hasLoadedApps = false; lastUpdated = nil; isLoading = false; errorMessage = nil }
 func beginRefreshEpisode() {}
 func refreshOnForeground() async {
  if !hasLoadedApps || Date().timeIntervalSince(lastUpdated ?? .distantPast) >= 60 { await refresh(force: false) }
 }
 func refresh(force: Bool) async {
  guard !isLoading else { return }
  calls += 1; isLoading = true
  defer { isLoading = false }
  if pause { await withCheckedContinuation { waiter = $0 } }
  else { await Task.yield() }
  guard !Task.isCancelled else { return }
  apps = next; hasLoadedApps = true; lastUpdated = .now
 }
 func finish() { pause = false; waiter?.resume(); waiter = nil }
}
actor InstalledAppUpdateCatalog {
 static let shared = InstalledAppUpdateCatalog()
 var calls = 0
 var pause = false
 var waiter: CheckedContinuation<Void, Never>?
 var result: [String: [SourceAppCatalogContext]] = [:]
 func configure(_ result: [String: [SourceAppCatalogContext]], pause: Bool = false) { self.result = result; self.pause = pause }
 func resume() { pause = false; waiter?.resume(); waiter = nil }
 func updates(installedVersions: [String: String], contexts: [SourceAppCatalogContext], ignoredIdentifiers: Set<String>) async throws -> [String: [SourceAppCatalogContext]] {
  calls += 1
  let snapshot = result.filter { installedVersions[$0.key] != nil && !ignoredIdentifiers.contains($0.key) }
  if pause { await withCheckedContinuation { waiter = $0 } }
  return snapshot
 }
}
'''
checks = r'''
@main struct Checks {
 @MainActor static func drain() async { for _ in 0..<30 { await Task.yield() } }
 @MainActor static func idle(_ coordinator: LibraryUpdatesStore) async {
  for _ in 0..<12 {
   await drain()
   if let task = coordinator.refreshTask { await task.value }
   else { return }
  }
  preconditionFailure("Coordinator did not settle")
 }
 @MainActor static func main() async throws {
  UserDefaults.standard.set(1, forKey: "Aether.installationMethod")
  let repositories = SourcesViewModel.shared, installed = InstalledAppsStore.shared
  let connection = DeviceConnectionManager.shared, catalog = InstalledAppUpdateCatalog.shared
  let coordinator = LibraryUpdatesStore()
  coordinator.setSources([AltSource()])
  let context = SourceAppCatalogContext(sourceObjectURI: "source://one", sourceURL: nil, repository: Repository(), revision: "1")
  let aetherIdentifier = "com.anfear.aether.fixture"
  let aetherContext = SourceAppCatalogContext(sourceObjectURI: AetherBuiltInRepository.key,
   sourceURL: AetherBuiltInRepository.url, repository: Repository(), revision: "1")
  repositories.builtInContext = aetherContext
  installed.next = [.init(bundleIdentifier: "app", version: "1"),
   .init(bundleIdentifier: aetherIdentifier, version: "1")]
  await catalog.configure(["app": [context], aetherIdentifier: [aetherContext]])
  let start = ContinuousClock.now
  coordinator.activate(); coordinator.activate()
  await idle(coordinator)
  precondition(start.duration(to: .now) >= .seconds(1), "Checking with its spinner has a one-second minimum")
  precondition(repositories.calls == 1 && installed.calls == 1, "Cold launch coalesces activation and service publications")
  precondition(coordinator.phase == .idle && coordinator.hasVerifiedUpdates && coordinator.updateContexts["app"] == [context])
  precondition(coordinator.updateContexts[aetherIdentifier] == [aetherContext],
   "Built-in Aether update context participates using the installed bundle identity")
  let firstMatches = await catalog.calls
  coordinator.activate(); await drain()
  precondition(coordinator.refreshTask == nil, "Reappearing tabs cannot start refresh work")
  coordinator.didEnterBackground(); coordinator.activate(); await idle(coordinator)
  precondition(repositories.calls == 1 && installed.calls == 1, "Fresh foreground data does not repeat network/browse work")
  let cachedMatches = await catalog.calls
  precondition(cachedMatches == firstMatches, "Unchanged inputs reuse matched updates")

  // A Sources refresh is joined, and its final revision is matched automatically.
  await repositories.startRefresh([AltSource()]).value
  await idle(coordinator)
  precondition(repositories.calls == 2 && installed.calls == 1)
  let repoMatches = await catalog.calls
  precondition(repoMatches > cachedMatches, "Sources refresh completion rematches without a tab switch")

  installed.next = [.init(bundleIdentifier: "app", version: "2")]
  coordinator.refreshInstalledApps(); await idle(coordinator)
  precondition(installed.calls == 2 && repositories.calls == 2, "Install completion refreshes apps without refetching repositories")
  let installMatches = await catalog.calls
  installed.apps = [] // Successful uninstall already updates the device store.
  await idle(coordinator)
  let uninstallMatches = await catalog.calls
  precondition(uninstallMatches > installMatches && coordinator.updateContexts.isEmpty,
   "Uninstall rematches remaining apps without an additional browse")
  precondition(installed.calls == 2 && repositories.calls == 2)

  installed.next = [.init(bundleIdentifier: "app", version: "3")]
  coordinator.startRefresh(); coordinator.startRefresh()
  await idle(coordinator)
  precondition(installed.calls == 3 && repositories.calls == 3, "Manual pulls bypass freshness and join one forced refresh")
  IgnoredAppUpdates.shared.identifiers = ["app"]
  await idle(coordinator)
  precondition(coordinator.updateContexts.isEmpty, "Ignoring an update rematches through the same owner")
  precondition(installed.calls == 3 && repositories.calls == 3)

  // A delayed scan cannot commit inputs that changed underneath it.
  IgnoredAppUpdates.shared.identifiers = []
  await catalog.configure(["app": [context]], pause: true)
  installed.apps = [.init(bundleIdentifier: "app", version: "4")]
  while await catalog.waiter == nil { await Task.yield() }
  installed.apps = []
  await drain()
  await catalog.resume()
  await idle(coordinator)
  precondition(coordinator.updateContexts.isEmpty, "An app removed during matching cannot reappear as an update")

  // Disconnect-on-idle invalidates synchronously; no canceled result can restore it.
  connection.isDisconnectWhenIdleEnabled = true
  coordinator.didEnterBackground()
  precondition(!coordinator.hasVerifiedUpdates && coordinator.phase == .idle)
  connection.state = .disconnected
  coordinator.activate()
  await idle(coordinator)
  precondition(connection.connections == 1 && installed.calls == 4, "Foreground reconnect browses once even with many state publications")

  // A manual pull during an automatic check still forces both data sources.
  installed.lastUpdated = .now
  installed.pause = true
  coordinator.refreshInstalledApps()
  while installed.waiter == nil { await Task.yield() }
  coordinator.startRefresh(); coordinator.startRefresh()
  installed.finish()
  await idle(coordinator)
  precondition(repositories.calls == 4, "A manual request during another cycle forces repos exactly once")
  precondition(coordinator.phase == .idle && coordinator.refreshTask == nil)
  installed.apps = [.init(bundleIdentifier: "app", version: "10")]
  while coordinator.lastMatchedInputs?.contains("10") != true { await Task.yield() }
  let beforeHoldChange = await catalog.calls
  precondition(coordinator.phase == .checking)
  installed.apps = [.init(bundleIdentifier: "app", version: "11")]
  await idle(coordinator)
  let afterHoldChange = await catalog.calls
  precondition(afterHoldChange > beforeHoldChange && coordinator.lastMatchedInputs?.contains("11") == true,
   "Input changes during the one-second presentation hold must still be matched")

  await catalog.configure(["app": [context]], pause: true)
  installed.apps = [.init(bundleIdentifier: "app", version: "9")]
  while await catalog.waiter == nil { await Task.yield() }
  let canceledOwner = coordinator.refreshTask!
  coordinator.didEnterBackground()
  precondition(coordinator.phase == .idle && !coordinator.hasVerifiedUpdates)
  await catalog.resume(); await canceledOwner.value
  precondition(!coordinator.hasVerifiedUpdates, "A canceled background scan cannot restore verified updates")
  await catalog.configure(["app": [context]])
  coordinator.activate(); await idle(coordinator)
  precondition(coordinator.hasVerifiedUpdates, "Foreground refresh recovers after cancellation")
  coordinator.didEnterBackground()
  connection.automatic = false; connection.state = .disconnected
  coordinator.activate(); await idle(coordinator)
  precondition(coordinator.phase == .idle && !coordinator.hasVerifiedUpdates,
   "A missing connection with automatic tunneling off must settle without a stuck spinner")
  print("Library coordinator checks passed: lifecycle, deduplication, cache reuse, forced pulls, source changes, install/uninstall, ignored updates, stale matches and reconnect")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-library-coordinator-') as folder:
    root = Path(folder)
    swift = root / 'Checks.swift'
    swift.write_text(stubs + production + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(root / 'checks')], check=True)
    subprocess.run([str(root / 'checks')], check=True, timeout=35)
