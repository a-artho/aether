import Foundation

/// Coalesces signing and server-transfer worker callbacks without creating a main-actor task per file/page.
/// Closing drops pending deliveries before completion, failure, or cancellation.
final class OperationProgressPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double?
    private var scheduled = false
    private var closed = false
    private var highest = 0.0
    private let publish: @MainActor (Double) -> Void

    init(publish: @escaping @MainActor (Double) -> Void) { self.publish = publish }

    func submit(_ value: Double) {
        guard value.isFinite else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        highest = max(highest, min(0.99, max(0, value)))
        latest = highest
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        if enqueue { DispatchQueue.main.async { [self] in drain() } }
    }

    @MainActor private func drain() {
        lock.lock()
        let value = closed ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let value { publish(value) }
    }

    func cancel() {
        lock.lock()
        closed = true
        latest = nil
        lock.unlock()
    }
}
