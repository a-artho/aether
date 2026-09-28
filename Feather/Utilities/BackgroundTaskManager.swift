//
//  BackgroundTaskManager.swift
//  Feather
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()

	private let baseId = "\(Bundle.main.bundleIdentifier ?? "Feather").userTask"
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []
	private var latestProgress: [String: Double] = [:]
	private var latestPresentation: [String: (title: String, subtitle: String)] = [:]
	private var completionBeforeLaunch: [String: Bool] = [:]
	private var expirationHandlers: [String: () -> Void] = [:]
	
	func startTask(for downloadId: String, filename: String) {
		_ = _startTask(
			for: downloadId,
			title: filename,
			subtitle: .localized("Downloading"),
			progress: 0
		)
	}

	@discardableResult
	func startPairingTask(
		for sessionIdentifier: UUID,
		onExpiration: @escaping () -> Void
	) -> Bool {
		_startTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Feather"),
			subtitle: .localized("Open Developer Mode"),
			progress: 0,
			onExpiration: onExpiration
		)
	}

	func markPairingSettingsOpened(for sessionIdentifier: UUID) {
		_updateTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Feather"),
			subtitle: .localized("Waiting for pairing code"),
			progress: 0.2
		)
	}

	func showPairingCode(_ code: String, for sessionIdentifier: UUID) {
		_updateTask(
			for: sessionIdentifier.uuidString,
			title: .localized("Pairing Feather"),
			subtitle: .localized("Code: \(code)"),
			progress: 0.6
		)
	}

	func stopPairingTask(for sessionIdentifier: UUID, success: Bool) {
		_stopTask(for: sessionIdentifier.uuidString, success: success)
	}

	private func _startTask(
		for token: String,
		title: String,
		subtitle: String,
		progress: Double,
		onExpiration: (() -> Void)? = nil
	) -> Bool {
		let taskIdentifier = _taskIdentifier(for: token)
		completionBeforeLaunch.removeValue(forKey: taskIdentifier)
		latestProgress[taskIdentifier] = progress
		latestPresentation[taskIdentifier] = (title, subtitle)
		if let onExpiration {
			expirationHandlers[taskIdentifier] = onExpiration
		}
		
		if !registeredTasks.contains(taskIdentifier) {
			let didRegister = BGTaskScheduler.shared.register(
				forTaskWithIdentifier: taskIdentifier,
				using: .main
			) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				task.progress.totalUnitCount = 100
				self.applyProgress(to: task, progress: self.latestProgress[task.identifier] ?? 0)
				if let presentation = self.latestPresentation[task.identifier] {
					task.updateTitle(presentation.title, subtitle: presentation.subtitle)
				}
				
				task.expirationHandler = { [weak self] in
					DispatchQueue.main.async {
						self?._expire(task)
					}
				}

				if let success = self.completionBeforeLaunch.removeValue(forKey: task.identifier) {
					task.setTaskCompleted(success: success)
					self._clearTaskState(for: task.identifier)
				}
			}
			guard didRegister else {
				_clearTaskState(for: taskIdentifier)
				return false
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: title, subtitle: subtitle)
		request.strategy = .fail
		do {
			try BGTaskScheduler.shared.submit(request)
			return true
		} catch {
			_clearTaskState(for: taskIdentifier)
			print(error)
			return false
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		_updateTask(for: downloadId, progress: progress)
	}

	func stopTask(for downloadId: String, success: Bool) {
		_stopTask(for: downloadId, success: success)
	}

	private func _updateTask(
		for token: String,
		title: String? = nil,
		subtitle: String? = nil,
		progress: Double
	) {
		let taskIdentifier = _taskIdentifier(for: token)
		let clampedProgress = min(max(progress, 0), 1)
		latestProgress[taskIdentifier] = clampedProgress

		if let title, let subtitle {
			latestPresentation[taskIdentifier] = (title, subtitle)
		}

		if let task = activeTasks[taskIdentifier] {
			applyProgress(to: task, progress: clampedProgress)
			if let presentation = latestPresentation[taskIdentifier] {
				task.updateTitle(presentation.title, subtitle: presentation.subtitle)
			}
		}
	}

	private func _stopTask(for token: String, success: Bool) {
		let taskIdentifier = _taskIdentifier(for: token)
		if let task = activeTasks.removeValue(forKey: taskIdentifier) {
			task.setTaskCompleted(success: success)
			completionBeforeLaunch.removeValue(forKey: taskIdentifier)
		} else {
			completionBeforeLaunch[taskIdentifier] = success
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
			_clearTaskState(for: taskIdentifier, preservingPendingCompletion: true)
			return
		}
		_clearTaskState(for: taskIdentifier)
	}

	private func _expire(_ task: BGContinuedProcessingTask) {
		let taskIdentifier = task.identifier
		activeTasks.removeValue(forKey: taskIdentifier)
		task.setTaskCompleted(success: false)
		let onExpiration = expirationHandlers[taskIdentifier]
		_clearTaskState(for: taskIdentifier)
		onExpiration?()
	}

	private func _taskIdentifier(for token: String) -> String {
		"\(baseId).\(token.md5)"
	}

	private func _clearTaskState(
		for taskIdentifier: String,
		preservingPendingCompletion: Bool = false
	) {
		activeTasks.removeValue(forKey: taskIdentifier)
		latestProgress.removeValue(forKey: taskIdentifier)
		latestPresentation.removeValue(forKey: taskIdentifier)
		if !preservingPendingCompletion {
			completionBeforeLaunch.removeValue(forKey: taskIdentifier)
		}
		expirationHandlers.removeValue(forKey: taskIdentifier)
	}

	private func applyProgress(to task: BGContinuedProcessingTask, progress: Double) {
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)
		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif
