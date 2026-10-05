import Foundation
import Darwin

/// Retains at most one completed package. This is an optional optimization:
/// cache damage or storage failures must never turn a valid install into a failure.
final class InstallPackageCache {
    static let shared = InstallPackageCache(directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("AetherInstallPackage", isDirectory: true))
    private struct Record: Codable { let key: String; let digest: String }
    private let directory: URL
    private let lock = NSLock()
    init(directory: URL) { self.directory = directory }

    func package(_ entries: [BundlePackageWriter.Entry], to output: URL, compression: Int32,
        check: () throws -> Void = { try Task.checkCancellation() }, progress: (Double) -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try check()
        let key = try BundlePackageWriter.fingerprint(entries, compression: compression, check: check)
        let artifact = directory.appendingPathComponent("Package.ipa")
        let recordURL = directory.appendingPathComponent("Package.json")
        if let recordData = try? Data(contentsOf: recordURL),
            let record = try? JSONDecoder().decode(Record.self, from: recordData), record.key == key {
            do {
                guard try BundlePackageWriter.digest(at: artifact, check: check) == record.digest else { throw BundlePackageWriter.Failure.archive("cache integrity") }
                try FileManager.default.copyItemPreferClone(at: artifact, to: output)
                try check()
                progress(1)
                return true
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
        try BundlePackageWriter.write(entries, to: output, compression: compression, check: check, progress: progress)
        try check()
        // Publish the complete artifact atomically; the manifest is published last.
        // Mismatches after a crash become cache misses, never stale package hits.
        let pending = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: pending) }
        do {
            let digest = try BundlePackageWriter.digest(at: output, check: check)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItemPreferClone(at: output, to: pending)
            try check()
            guard rename(pending.path, artifact.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let data = try JSONEncoder().encode(Record(key: key, digest: digest))
            try data.write(to: recordURL, options: .atomic)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Installation still uses the already-complete private output file.
            try? FileManager.default.removeItem(at: recordURL)
        }
        return false
    }
}
