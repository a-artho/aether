import Foundation
import IDevice

/// One monotonic budget across lock acquisition, candidate ports, discovery and retries.
/// Cancellation reads a separate generation lock, never the native transport lock.
final class RSDConnectionAttempt: @unchecked Sendable {
    private let deadline: TimeInterval
    private let cancelled: @Sendable () -> Bool

    init(timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        self.cancelled = cancelled
    }
    var remaining: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }
    var isCancelled: Bool { cancelled() }
    func check() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
        if remaining <= 0 { throw IDeviceSwiftError(109, message: "Device connection timed out") }
    }
    func lock(_ lock: NSLock) throws {
        while true {
            try check()
            if lock.lock(before: Date(timeIntervalSinceNow: min(remaining, 0.025))) { break }
        }
        do { try check() } catch { lock.unlock(); throw error }
    }
    func backoff(_ seconds: TimeInterval) throws {
        let end = ProcessInfo.processInfo.systemUptime + min(seconds, remaining)
        while ProcessInfo.processInfo.systemUptime < end {
            try check()
            Thread.sleep(forTimeInterval: min(0.025, max(0, end - ProcessInfo.processInfo.systemUptime)))
        }
        try check()
    }
    func beginNativeScope() throws {
        try check()
        idevice_connection_attempt_begin(UInt64(max(1, remaining * 1000)), 350, { context in
            guard let context else { return true }
            return Unmanaged<RSDConnectionAttempt>.fromOpaque(context).takeUnretainedValue().isCancelled
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func endNativeScope() {
        withExtendedLifetime(self) { idevice_connection_attempt_end() }
    }
}
