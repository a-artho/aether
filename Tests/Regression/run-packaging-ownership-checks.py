#!/usr/bin/env python3
"""Compile the real archive handler and exercise direct reads and lease lifetime."""
from pathlib import Path
import json, os, subprocess, tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='aether-packaging-') as directory:
    root = Path(directory)
    core = root / 'Sources/Checks'
    core.mkdir(parents=True)
    dependencies = []
    for name, url, version, variable in [
        ('Zip', 'https://github.com/marmelroy/Zip', '2.1.2', 'AETHER_ZIP_CHECKOUT'),
        ('ZIPFoundation', 'https://github.com/weichsel/ZIPFoundation', '0.9.20', 'AETHER_ZIPFOUNDATION_CHECKOUT'),
    ]:
        checkout = os.environ.get(variable)
        dependencies.append('.package(path: '+json.dumps(checkout)+')' if checkout else
                            '.package(url: '+json.dumps(url)+', exact: '+json.dumps(version)+')')
    (root / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PackagingOwnership", platforms: [.macOS(.v13)],
 dependencies: [''' + ','.join(dependencies) + '''], targets: [
 .executableTarget(name: "Checks", dependencies: [.product(name: "Zip", package: "Zip"), .product(name: "ZIPFoundation", package: "ZIPFoundation")])])
''')
    for name in ['LibraryArtifactAccess.swift', 'Handlers/BundlePackageWriter.swift', 'Handlers/ArchiveHandler.swift']:
        source = (repo / 'Aether/Utilities' / name).read_text()
        source = source.replace('import UIKit.UIApplication\n', '').replace('import IDeviceSwift\n', '')
        (core / Path(name).name).write_text(source)
    (core / 'ZipCompression+cases.swift').write_text((repo / 'Aether/Extensions/ZipCompression+cases.swift').read_text())
    (core / 'AppMaintenanceGuard.swift').write_text((repo / 'Aether/Utilities/AppMaintenanceGuard.swift').read_text())
    (core / 'Platform.swift').write_text(r'''
import Foundation
protocol AppInfoPresentable { var uuid: String? { get }; var isSigned: Bool { get } }
struct AppSnapshot: AppInfoPresentable, Sendable {
 let uuid: String?; let isSigned: Bool
 let name: String? = "Fixture"; let identifier: String? = "test.fixture"; let version: String? = "1"
}
enum SigningFileHandlerError: Error { case appNotFound }
@MainActor final class AppInstallationManager {
 static let shared = AppInstallationManager()
 let hasPendingInstalls = false; let hasRetiringWork = false
 let uninstallingBundleIdentifiers = Set<String>()
}
@MainActor final class DownloadManager { static let shared = DownloadManager(); let hasActiveWork = false }
@MainActor final class ExportManager { static let shared = ExportManager(); let hasActiveWork = false }
@MainActor final class OnDevicePairingManager { static let shared = OnDevicePairingManager(); let isActive = false }
@MainActor final class InstallerStatusViewModel { var packageProgress: Double = 0 }
enum UIApplication { @MainActor static func open(_ url: URL) {} }
extension String { static func localized(_ value: String) -> String { value } }
@MainActor final class DebugLogManager {
 enum Level { case notice, error }
 static let shared = DebugLogManager()
 func log(_ message: String, category: String, level: Level) {}
}
@MainActor final class Storage {
 static let shared = Storage()
 var removed: [String] = []
 var failRemoval = false
 struct Failure: Error {}
 func removeImported(uuid: String) throws {
  if failRemoval { throw Failure() }
  removed.append(uuid)
 }
}
extension URL { func toSharedDocumentsURL() -> URL? { nil } }
extension FileManager {
 static let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 var archives: URL { Self.fixtureRoot.appendingPathComponent("Archives") }
 func signed(_ uuid: String) -> URL { Self.fixtureRoot.appendingPathComponent("Signed/" + uuid) }
 func unsigned(_ uuid: String) -> URL { Self.fixtureRoot.appendingPathComponent("Unsigned/" + uuid) }
 func getPath(in directory: URL, for suffix: String) -> URL? {
  (try? contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.first { $0.pathExtension == suffix }
 }
 func createDirectoryIfNeeded(at directory: URL) throws {
  try createDirectory(at: directory, withIntermediateDirectories: true)
 }
 func removeFileIfNeeded(at url: URL) throws {
  if fileExists(atPath: url.path) { try removeItem(at: url) }
 }
}
''')
    cleanup = (repo / 'Aether/Utilities/Handlers/AppFileHandler.swift').read_text()
    start = cleanup.index('static func removeImportTransaction(')
    end = cleanup.index('{', start) + 1
    depth = 1
    while depth:
        depth += (cleanup[end] == '{') - (cleanup[end] == '}')
        end += 1
    (core / 'ImportCleaner.swift').write_text('import Foundation\nenum ImportCleaner {\n' + cleanup[start:end] + '\n}\n')
    (core / 'OwnershipChecks.swift').write_text(r'''
import Foundation
import ZIPFoundation

enum CheckFailure: Error { case missingValue }
func check(_ value: Bool) { precondition(value) }
func checkFalse(_ value: Bool) { precondition(!value) }
func checkEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b) }
func fail(_ message: String) -> Never { fatalError(message) }
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure.missingValue }; return value }
func checkThrows<T>(_ value: @autoclosure () throws -> T) {
 do { _ = try value(); fail("Expected an error") } catch {}
}

actor Gate {
 var continuation: CheckedContinuation<Void, Never>?
 var opened = false
 func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
 func open() { opened = true; continuation?.resume(); continuation = nil }
}

final class OwnershipChecks {
 @MainActor func testReaderCountsAndArtifactKinds() async throws {
  let app = AppSnapshot(uuid: UUID().uuidString, isSigned: true)
  var first: LibraryArtifactAccess.ReadLease? = try LibraryArtifactAccess.shared.acquireRead(for: app)
  var second: LibraryArtifactAccess.ReadLease? = try LibraryArtifactAccess.shared.acquireRead(for: app)
  check(LibraryArtifactAccess.shared.hasReaders(for: app))
  check(AppMaintenanceGuard.resetBlockReason != nil)
  checkFalse(AppMaintenanceGuard.beginReset())
  checkFalse(LibraryArtifactAccess.shared.hasReaders(uuid: app.uuid!, isSigned: false))
  withExtendedLifetime(first) {}; first = nil
  check(LibraryArtifactAccess.shared.hasReaders(for: app))
  withExtendedLifetime(second) {}; second = nil
  checkFalse(LibraryArtifactAccess.shared.hasReaders(for: app))
  check(AppMaintenanceGuard.resetBlockReason == nil)
 }
 @MainActor func testWorkerKeepsLeaseAfterItsOwnerCancels() async throws {
  let app = AppSnapshot(uuid: UUID().uuidString, isSigned: false)
  var lease: LibraryArtifactAccess.ReadLease? = try LibraryArtifactAccess.shared.acquireRead(for: app)
  let gate = Gate()
  var worker: Task<Void, Never>? = Task.detached { [held = lease!] in
   await gate.wait()
   withExtendedLifetime(held) {}
  }
  lease = nil
  worker?.cancel()
  check(LibraryArtifactAccess.shared.hasReaders(for: app))
  await gate.open()
  await worker?.value
  worker = nil
  checkFalse(LibraryArtifactAccess.shared.hasReaders(for: app))
 }
 @MainActor func testResetCannotAcquireAReader() async throws {
  check(AppMaintenanceGuard.beginReset())
  checkThrows(try LibraryArtifactAccess.shared.acquireRead(for: AppSnapshot(uuid: "blocked", isSigned: true)))
  checkFalse(LibraryArtifactAccess.shared.hasReaders(uuid: "blocked", isSigned: true))
 }
 @MainActor func testArchiveReadsOriginalAndCleanReleasesLease() async throws {
  let app = AppSnapshot(uuid: UUID().uuidString, isSigned: true)
  let directory = FileManager.default.signed(app.uuid!).appendingPathComponent("Fixture.app")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
  let bytes = Data("signed binary fixture".utf8)
  try bytes.write(to: directory.appendingPathComponent("binary"))
  try FileManager.default.createDirectory(at: directory.appendingPathComponent("Empty"), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "binary")
  let handler = ArchiveHandler(app: app, viewModel: InstallerStatusViewModel(), purpose: .install)
  defer { handler.clean() }
  try await handler.move()
  check(LibraryArtifactAccess.shared.hasReaders(for: app))
  let destination = try await handler.archive()
  checkFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("Payload").path))
  let archive = try Archive(url: destination, accessMode: .read)
  let entry = try unwrap(archive["Payload/Fixture.app/binary"])
  var read = Data()
  _ = try archive.extract(entry) { read.append($0) }
  checkEqual(read, bytes)
  check(archive["Payload/Fixture.app/Empty/"] != nil)
  let link = try unwrap(archive["Payload/Fixture.app/link"])
  checkEqual(link.type, .symlink)
  var target = Data()
  _ = try archive.extract(link) { target.append($0) }
  checkEqual(String(data: target, encoding: .utf8), "binary")
  handler.clean()
  checkFalse(LibraryArtifactAccess.shared.hasReaders(for: app))
  check(FileManager.default.fileExists(atPath: directory.path))
  do { _ = try await handler.archive(); fail("Cleaned handler must not read again") } catch {}
 }
 @MainActor func testFailedPreparationReleasesItsReader() async throws {
  let app = AppSnapshot(uuid: UUID().uuidString, isSigned: false)
  let handler = ArchiveHandler(app: app, viewModel: InstallerStatusViewModel(), purpose: .export)
  do { try await handler.move(); fail("Missing app must fail") } catch {}
  handler.clean()
  checkFalse(LibraryArtifactAccess.shared.hasReaders(for: app))
 }
 @MainActor func testImportCleanupRespectsReadersAndRestoresOnFailure() async throws {
  let app = AppSnapshot(uuid: UUID().uuidString, isSigned: false)
  let directory = FileManager.default.unsigned(app.uuid!)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  var lease: LibraryArtifactAccess.ReadLease? = try LibraryArtifactAccess.shared.acquireRead(for: app)
  await ImportCleaner.removeImportTransaction(transactionIdentifier: app.uuid!)
  check(FileManager.default.fileExists(atPath: directory.path))
  checkFalse(Storage.shared.removed.contains(app.uuid!))
  withExtendedLifetime(lease) {}; lease = nil
  Storage.shared.failRemoval = true
  await ImportCleaner.removeImportTransaction(transactionIdentifier: app.uuid!)
  check(FileManager.default.fileExists(atPath: directory.path))
  Storage.shared.failRemoval = false
  await ImportCleaner.removeImportTransaction(transactionIdentifier: app.uuid!)
  checkFalse(FileManager.default.fileExists(atPath: directory.path))
  check(Storage.shared.removed.contains(app.uuid!))
 }
}
''')
    (core / 'Run.swift').write_text(r'''
@main struct Run {
 @MainActor static func main() async throws {
  let checks = OwnershipChecks()
  try await checks.testReaderCountsAndArtifactKinds()
  try await checks.testWorkerKeepsLeaseAfterItsOwnerCancels()
  try await checks.testArchiveReadsOriginalAndCleanReleasesLease()
  try await checks.testFailedPreparationReleasesItsReader()
  try await checks.testImportCleanupRespectsReadersAndRestoresOnFailure()
  try await checks.testResetCannotAcquireAReader()
  print("Packaging ownership checks passed: counted readers, worker lifetime, reset exclusion, direct archive, cleanup, failure release and import retirement")
 }
}
''')
    subprocess.run(['swift', 'run', '--package-path', str(root), 'Checks'], check=True)
