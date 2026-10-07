#!/usr/bin/env python3
"""Exercise the six follow-up audit fixes with production methods and platform doubles."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]

def declaration(path, start):
    source = (repo / path).read_text()
    begin = source.index(start)
    end = source.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

source = 'import Foundation\nimport CoreData\n'
source += (repo / 'AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift').read_text().replace(
    'import SwiftUI', 'public struct Color: Codable, Hashable, Sendable {}')
source += (repo / 'AltSourceKit/Sources/AltSourceKit/Extensions/Array/Array+safe.swift').read_text()
source += '''
protocol AppInfoPresentable { var uuid: String? { get }; var isSigned: Bool { get } }
struct Snapshot: AppInfoPresentable { let uuid: String?; let isSigned: Bool }
final class AppInstallationManager { static let shared = AppInstallationManager(); var busy = false; func containsInstallation(for app: AppInfoPresentable) -> Bool { busy } }
final class ExportManager { static let shared = ExportManager(); var busy = false; func usesLibraryArtifact(_ app: AppInfoPresentable) -> Bool { busy } }
final class DownloadManager { static let shared = DownloadManager(); func usesLibraryArtifact(_ app: AppInfoPresentable) -> Bool { false } }
enum Level { case notice, error, warning }
final class DebugLogManager { static let shared = DebugLogManager(); func log(_ s: String, category: String, level: Level) {} }
final class Storage {
 let context: NSManagedObjectContext; let root: URL
 init(_ context: NSManagedObjectContext, _ root: URL) { self.context = context; self.root = root }
 func getUuidDirectory(for app: AppInfoPresentable) -> URL? { root.appendingPathComponent(app.uuid!) }
 func deleteSourceMetadata(for uuid: String?, deferSave: Bool) throws {}
 var saveFailure: Error?; var saves=0; var failOnSave: Int?
 struct Failure: Error {}
 func saveContext() -> Error? { saves+=1; if saves==failOnSave { return Failure() }; if let saveFailure { return saveFailure }; do { try context.save(); return nil } catch { return error } }
'''
source += declaration('Aether/Backend/Storage/Storage+Shared.swift', 'func deleteApp(') + '\n}\n'
source += '''
struct CertificatePair { let uuid: String? }
struct SelectionBinding { var wrappedValue: Int }
struct CertificateSelection {
 var _selectedCertUUID: String; var _certificates: [CertificatePair]; var _selectedCertBinding: SelectionBinding
'''
source += declaration('Aether/Views/Settings/Certificates/CertificatesView.swift', 'private func _isSelected(').replace('private func', 'func', 1) + '\n}\n'
source += '''
struct InstalledApp { let id: String; var bundleIdentifier: String { id } }
enum AppLifecycleService { static var completion: (() -> Void)?; static func uninstallApp(bundleIdentifier: String) async throws { completion?() } }
struct Animation { static func easeOut(duration: Double) -> Animation { Animation() } }
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
final class AppsStore {
 var refreshGeneration = UUID(); var isLoading = true; var needsTrailingRefresh = true
 var iconPrefetchTask: Task<Void, Never>?; var apps = [InstalledApp(id: "remove"), InstalledApp(id: "keep")]
'''
source += declaration('Aether/Views/Installed/InstalledAppsStore.swift', 'func delete(app:') + '\n}\n'
archive = (repo / 'Aether/Utilities/Handlers/ArchiveHandler.swift').read_text()
filename = next(line.strip() for line in archive.splitlines() if 'let appendingString =' in line)
source += 'func exportName(_uuid: String) -> String { let name = "Same"; let version = "1"; ' + filename + '; return appendingString }\n'
connection = declaration('Aether/Backend/Observable/DeviceConnectionManager.swift', 'public func setConnection(')
guards = connection[:connection.index('\n\t\tlet method')]
source += '''
enum State { case connected, disconnected, connecting, disconnecting }
final class Connection {
 var connectionEpoch: UInt64 = 0; var activeVerificationID: UUID?
 func _cancelForegroundRecovery() {}
 var connectionPreparation: UUID? = UUID(); var state: State = .connecting; var proceeded = false
 var isUpdating: Bool { state == .connecting || state == .disconnecting }
'''+guards+'\n proceeded = true\n}\n}\n'
embedded = (repo / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
start = embedded[embedded.index('public func start('):embedded.index('public func stop(')]
start = start.split('\t\t#if targetEnvironment(simulator)')[0] + start.split('\t\t#elseif os(iOS) && !targetEnvironment(macCatalyst)')[1].split('\t\t#else')[0] + '\n}\n'
source += """
enum EmbeddedTunnelError: Error { case unavailable, invalidConfiguration, providerNotReady }
enum VPNStatus { case disconnected, connected, connecting, reasserting }
enum TunnelState { case connected, connecting; case error(String) }
final class FakeVPNConnection {
 var status: VPNStatus = .disconnected; var starts = 0
 func startVPNTunnel(options: [String: NSObject]) throws { starts += 1 }
}
final class NETunnelProviderManager { var isEnabled = true; let connection = FakeVPNConnection() }
final class HeartbeatManager { static let shared = HeartbeatManager(); var ipAddress = "" }
final class TunnelProbe {
 var manager: NETunnelProviderManager? = NETunnelProviderManager(); var state: TunnelState = .connecting
 let peerIPOnly = "peer", interfaceAddress = "interface", peerAddress = "peer"
 static let interfaceAddressKey = "interface", peerAddressKey = "peer"
 var prepared: (() -> Void)?; var waited: (() -> Void)?
 func prepare() async throws -> Bool { prepared?(); return true }
 func save(_ m: NETunnelProviderManager) async throws {}
 func load(_ m: NETunnelProviderManager) async throws {}
 func resetConfiguration() async {}
 func waitForConnected() async -> Bool { waited?(); return true }
 func _setState(_ s: TunnelState) { state = s }
 func _log(_ s: String, level: Level = .notice) {}
"""
source += start
source += declaration('Aether/Backend/Observable/EmbeddedTunnelManager.swift', 'func startTunnel(') + '\n}\n'
source += '''
@main struct Checks {
 static func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
 @MainActor static func main() async throws {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: root) }
 let model = NSManagedObjectModel()
 model.entities = ["Imported", "Signed"].map { name in
  let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = "NSManagedObject"
  let uuid = NSAttributeDescription(); uuid.name = "uuid"; uuid.attributeType = .stringAttributeType; entity.properties = [uuid]; return entity
 }
 let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
 try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
 let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
 for (entity, uuid) in [("Imported", "original"), ("Imported", "other"), ("Signed", "original")] {
  let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context); object.setValue(uuid, forKey: "uuid")
  try FileManager.default.createDirectory(at: root.appendingPathComponent(uuid), withIntermediateDirectories: true)
 }
 try context.save()
 let storage = Storage(context, root)
 AppInstallationManager.shared.busy = true
 check(!storage.deleteApp(for: Snapshot(uuid: "original", isSigned: false)), "Active operation must retain original")
 AppInstallationManager.shared.busy = false
 ExportManager.shared.busy = true
 check(!storage.deleteApp(for: Snapshot(uuid: "original", isSigned: false)), "Active export retains source files")
 ExportManager.shared.busy = false
 storage.failOnSave = storage.saves + 2
 check(!storage.deleteApp(for: Snapshot(uuid: "original", isSigned: false)), "Failed deletion save reports failure")
 check(tryCount(context, "Imported") == 2, "Failed save restores database record")
 check(FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path), "Failed save restores app files")
 storage.failOnSave = nil
 check(storage.deleteApp(for: Snapshot(uuid: "original", isSigned: false)), "Snapshot deletion succeeded")
 check(tryCount(context, "Imported") == 1, "Original Library record removed; other import retained")
 check(tryCount(context, "Signed") == 1, "Signed record retained")
 check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path), "Original files removed")
 let connection = Connection(); connection.setConnection(enabled: false)
 check(!connection.proceeded, "Ordinary toggle must respect active transition")
 connection.setConnection(enabled: false, force: true)
 check(connection.proceeded, "Forced disconnect must supersede connecting transition")
 var validStart = true
 let cancelledTunnel = TunnelProbe(); cancelledTunnel.prepared = { validStart = false }
 do { try await cancelledTunnel.start { validStart }; preconditionFailure("Superseded start must stop") }
 catch { check(error is CancellationError, "Superseded tunnel start returns cancellation") }
 check(cancelledTunnel.manager!.connection.starts == 0, "Disconnect during preparation prevents VPN start")
 let normalTunnel = TunnelProbe(); try await normalTunnel.start()
 check(normalTunnel.manager!.connection.starts == 1, "Normal tunnel start retained")
 let staleCompletion = TunnelProbe(); validStart = true; staleCompletion.waited = { validStart = false }
 do { try await staleCompletion.start { validStart }; preconditionFailure("Stale completion must not publish") }
 catch { check(error is CancellationError, "Stale tunnel completion ignored") }
 let store = AppsStore(); var inFlightGeneration = store.refreshGeneration
 AppLifecycleService.completion = { inFlightGeneration = store.refreshGeneration }
 try await store.delete(app: InstalledApp(id: "remove"))
 check(store.refreshGeneration != inFlightGeneration, "Pre-uninstall refresh cannot publish")
 check(!store.isLoading && !store.needsTrailingRefresh, "Refresh ownership released")
 check(store.apps.map(\\.id) == ["keep"], "Only uninstalled app removed")
 let a = CertificatePair(uuid: "selected"), b = CertificatePair(uuid: "new")
 let selection = CertificateSelection(_selectedCertUUID: "selected", _certificates: [b, a], _selectedCertBinding: SelectionBinding(wrappedValue: 0))
 check(selection._isSelected(a, at: 1) && !selection._isSelected(b, at: 0), "Certificate highlight follows UUID after insertion")
 let fallback = CertificateSelection(_selectedCertUUID: "missing", _certificates: [b, a], _selectedCertBinding: SelectionBinding(wrappedValue: 1))
 check(fallback._isSelected(a, at: 1), "Legacy index fallback retained")
 check(exportName(_uuid: "job-a") != exportName(_uuid: "job-b"), "Concurrent identical app exports have distinct filenames")
 for screenshots in [
  #"["https://example.com/a",{"url":"https://example.com/b","width":200},42,null,{}]"#,
  #"{"iphone":["https://example.com/a",{"url":"https://example.com/b"}],"ipad":[{"url":"https://example.com/pad"}]}"#
 ] {
  let json = "{\\"name\\":\\"Fixture\\",\\"apps\\":[{\\"name\\":\\"App\\",\\"bundleIdentifier\\":\\"test.app\\",\\"screenshots\\":" + screenshots + "}]}"
  let repo = try JSONDecoder().decode(ASRepository.self, from: Data(json.utf8))
  let artwork = repo.apps[0].screenshots!
  check(artwork.urls(forPad: false).count == 2, "Mixed screenshot formats decoded, malformed entries skipped")
  check(artwork.urls(forPad: true).count == (screenshots.hasPrefix("[") ? 2 : 1), "Device-specific artwork and fallback")
 }
 print("Six audit fix checks passed")
 }
 static func tryCount(_ context: NSManagedObjectContext, _ entity: String) -> Int { try! context.count(for: NSFetchRequest<NSManagedObject>(entityName: entity)) }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-audit-fixes-') as temp:
    path = pathlib.Path(temp)
    (path / 'checks.swift').write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
