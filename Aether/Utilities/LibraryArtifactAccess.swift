import Foundation

/// Acquisition and destructive library operations are serialized on the main
/// actor. A worker may release its lease on any thread after its last file read.
final class LibraryArtifactAccess: @unchecked Sendable {
    static let shared = LibraryArtifactAccess()

    private struct Key: Hashable, Sendable {
        let uuid: String
        let isSigned: Bool
    }

    final class ReadLease: Sendable {
        let directory: URL
        private let onRelease: @Sendable () -> Void

        fileprivate init(directory: URL, onRelease: @escaping @Sendable () -> Void) {
            self.directory = directory
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    private let lock = NSLock()
    private var readers: [Key: Int] = [:]
    private init() {}

    @MainActor
    func acquireRead(for app: AppSnapshot) throws -> ReadLease {
        try Task.checkCancellation()
        guard !AppMaintenanceGuard.isResetting, let uuid = app.uuid else {
            throw SigningFileHandlerError.appNotFound
        }
        let key = Key(uuid: uuid, isSigned: app.isSigned)
        let directory = app.isSigned ? FileManager.default.signed(uuid) : FileManager.default.unsigned(uuid)
        lock.withLock { readers[key, default: 0] += 1 }
        return ReadLease(directory: directory) { [self] in
            lock.withLock {
                guard let count = readers[key] else { return }
                if count == 1 { readers.removeValue(forKey: key) }
                else { readers[key] = count - 1 }
            }
        }
    }

    @MainActor
    func hasReaders(for app: AppInfoPresentable) -> Bool {
        guard let uuid = app.uuid else { return false }
        return hasReaders(uuid: uuid, isSigned: app.isSigned)
    }

    @MainActor
    func hasReaders(uuid: String, isSigned: Bool) -> Bool {
        lock.withLock { readers[Key(uuid: uuid, isSigned: isSigned)] != nil }
    }

    @MainActor
    func hasReaders(isSigned: Bool) -> Bool {
        lock.withLock { readers.keys.contains { $0.isSigned == isSigned } }
    }

    var hasReaders: Bool { lock.withLock { !readers.isEmpty } }
}
