#if !targetEnvironment(macCatalyst)
import Foundation
import BackgroundTasks
import UIKit

@MainActor
class BackgroundTaskManager: ObservableObject {
    static let shared = BackgroundTaskManager()
    private let baseId = "\(Bundle.main.bundleIdentifier ?? "Aether").userTask"
    private let progressUnits: Int64 = 1_000_000

    // A registration keeps only this tiny completion box after an operation ends.
    // Late scheduler delivery must never consume a newer operation's state.
    private final class LaunchState { var completion: Bool? }
    private final class Work {
        let identifier: String
        let launch = LaunchState()
        var task: BGContinuedProcessingTask?
        var fallback: UIBackgroundTaskIdentifier = .invalid
        var title: String
        var subtitle: String
        var progress: Double
        var onExpiration: (() -> Void)?
        init(identifier: String, title: String, subtitle: String, progress: Double, onExpiration: (() -> Void)?) {
            self.identifier = identifier; self.title = title; self.subtitle = subtitle
            self.progress = progress; self.onExpiration = onExpiration
        }
    }
    private var workByToken: [String: Work] = [:]

    @discardableResult
    func startWork(for token: String, title: String, subtitle: String, progress: Double,
        installation: Bool = false, signing: Bool = false, onExpiration: @escaping () -> Void) -> Bool {
        if let work = workByToken[token] {
            work.onExpiration = onExpiration
            _updateTask(for: token, title: title, subtitle: subtitle, progress: progress)
            return true
        }
        return _startTask(for: token, kind: installation ? .installation : (signing ? .signing : .download),
            title: title, subtitle: subtitle, progress: progress, onExpiration: onExpiration)
    }

    func hasExecution(for token: String) -> Bool {
        guard let work = workByToken[token] else { return false }
        return work.task != nil || work.fallback != .invalid
    }

    func hasNativeTask(for token: String) -> Bool { workByToken[token]?.task != nil }

    func updateWork(for token: String, title: String, subtitle: String, progress: Double) {
        _updateTask(for: token, title: title, subtitle: subtitle, progress: progress)
    }
	@discardableResult
	func startPairingTask(
		for sessionIdentifier: UUID,
		onExpiration: @escaping () -> Void
	) -> Bool {
		_startTask(
			for: sessionIdentifier.uuidString,
			kind: .pairing,
			title: .localized("Pairing Aether"),
			subtitle: .localized("Open Settings"),
			progress: 0,
			onExpiration: onExpiration
		)
	}

	func markPairingSettingsOpened(for sessionIdentifier: UUID) {
		_updateTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Aether"),
			subtitle: .localized("Waiting for pairing code"),
			progress: 0.2
		)
	}

	func showPairingCode(_ code: String, for sessionIdentifier: UUID) {
		_updateTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Aether"),
			subtitle: .localized("Code: \(code)"),
			progress: 0.6
		)
	}

	func showPairingProgress(_ subtitle: String, for sessionIdentifier: UUID) {
		_updateTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Aether"),
			subtitle: subtitle,
			progress: 0.6
		)
	}

	func stopPairingTask(for sessionIdentifier: UUID, success: Bool) {
		_stopTask(for: sessionIdentifier.uuidString, success: success)
	}


    private enum TaskKind: String { case download, signing, installation, pairing }

    @discardableResult
    private func _startTask(for token: String, kind: TaskKind, title: String, subtitle: String,
        progress: Double, onExpiration: (() -> Void)? = nil) -> Bool {
        if let existing = workByToken[token] {
            if let onExpiration { existing.onExpiration = onExpiration }
            _updateTask(for: token, title: title, subtitle: subtitle, progress: progress)
            return true
        }
        // Unique per attempt, including retries of the same download.
        let identifier = "\(baseId).\(kind.rawValue).\(UUID().uuidString)"
        let work = Work(identifier: identifier, title: title, subtitle: subtitle,
            progress: progress, onExpiration: onExpiration)
        workByToken[token] = work

        // A restored background URLSession completion cannot submit a new user task.
        if UIApplication.shared.applicationState == .background {
            guard _startFallback(for: token, work: work) else { _clear(token, work: work); return false }
            return true
        }
        let launch = work.launch
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self, weak work] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            guard let self, let work, self.workByToken[token] === work, launch.completion == nil else {
                task.setTaskCompleted(success: launch.completion ?? false)
                return
            }
            work.task = task
            self._endFallback(work)
            self.applyProgress(to: task, progress: work.progress)
            task.updateTitle(work.title, subtitle: work.subtitle)
            task.expirationHandler = { [weak self, weak work, weak task] in
                Task { @MainActor in
                    guard let self, let work, let task, self.workByToken[token] === work, work.task === task else { return }
                    self._interrupt(token, work: work)
                }
            }
            DebugLogManager.shared.log("Continued task running id=\(identifier) token=\(token).", category: "Background", level: .info)
        }
        guard registered else { _clear(token, work: work); return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            // Bridge delivery; its expiration interrupts the operation, never silently
            // disconnecting the display while leaving that operation running.
            if workByToken[token] === work, work.task == nil { _ = _startFallback(for: token, work: work) }
            DebugLogManager.shared.log("Continued task submitted id=\(identifier) token=\(token).", category: "Background", level: .info)
            return true
        } catch {
            DebugLogManager.shared.log("Continued task denied id=\(identifier): \(error.localizedDescription)", category: "Background", level: .notice)
            launch.completion = false
            if onExpiration != nil, _startFallback(for: token, work: work) { return true }
            _clear(token, work: work)
            return false
        }
    }

    func updateProgress(for downloadId: String, progress: Double) { _updateTask(for: downloadId, progress: progress) }
    func stopTask(for downloadId: String, success: Bool) { _stopTask(for: downloadId, success: success) }

    private func _updateTask(for token: String, title: String? = nil, subtitle: String? = nil, progress: Double) {
        guard let work = workByToken[token] else { return }
        let previousTitle = work.title, previousSubtitle = work.subtitle
        work.progress = min(max(progress, 0), 1)
        if let title { work.title = title }; if let subtitle { work.subtitle = subtitle }
        if let task = work.task {
            applyProgress(to: task, progress: work.progress)
            if previousTitle != work.title || previousSubtitle != work.subtitle { task.updateTitle(work.title, subtitle: work.subtitle) }
        }
    }

    private func _stopTask(for token: String, success: Bool) {
        guard let work = workByToken[token] else { return }
        work.launch.completion = success
        if let task = work.task {
            if success { applyProgress(to: task, progress: 1) }
            task.setTaskCompleted(success: success)
        } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: work.identifier) }
        DebugLogManager.shared.log("Continued task finished id=\(work.identifier) success=\(success).", category: "Background", level: .info)
        _clear(token, work: work)
    }

    private func _interrupt(_ token: String, work: Work) {
        guard workByToken[token] === work else { return }
        let handler = work.onExpiration
        DebugLogManager.shared.log("Continued execution interrupted id=\(work.identifier) progress=\(work.progress) state=\(UIApplication.shared.applicationState.rawValue)", category: "Background", level: .notice)
        // Publish the recovery instruction while the native activity still belongs to us.
        // Completion may replace its presentation with the system's failed-task UI.
        work.subtitle = .localized("Open Aether to resume")
        work.task?.updateTitle(work.title, subtitle: work.subtitle)
        _stopTask(for: token, success: false)
        handler?()
    }

    private func _clear(_ token: String, work: Work) {
        _endFallback(work)
        work.onExpiration = nil
        work.task = nil
        if workByToken[token] === work { workByToken.removeValue(forKey: token) }
    }

    @discardableResult
    private func _startFallback(for token: String, work: Work) -> Bool {
        if work.fallback != .invalid { return true }
        work.fallback = UIApplication.shared.beginBackgroundTask(withName: work.identifier) { [weak self, weak work] in
            Task { @MainActor in
                guard let self, let work, self.workByToken[token] === work, work.fallback != .invalid else { return }
                self._interrupt(token, work: work)
            }
        }
        return work.fallback != .invalid
    }
    private func _endFallback(_ work: Work) {
        guard work.fallback != .invalid else { return }
        UIApplication.shared.endBackgroundTask(work.fallback)
        work.fallback = .invalid
    }
    private func applyProgress(to task: BGContinuedProcessingTask, progress: Double) {
        task.progress.totalUnitCount = progressUnits
        let units = Int64(min(max(progress, 0), 1) * Double(progressUnits))
        if task.progress.completedUnitCount != units { task.progress.completedUnitCount = units }
    }
}
#endif
