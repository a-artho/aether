import Foundation

/// Handles cancellation arriving before an independently-created worker is attached.
final class TaskCancellationRelay: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false
	private var worker: Task<Void, Never>?
	func attach(_ task: Task<Void, Never>) {
		lock.lock()
		worker = task
		let shouldCancel = cancelled
		lock.unlock()
		if shouldCancel { task.cancel() }
	}
	func cancel() {
		lock.lock()
		cancelled = true
		let task = worker
		lock.unlock()
		task?.cancel()
	}
}
