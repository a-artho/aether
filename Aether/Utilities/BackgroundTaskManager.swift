//
//  BackgroundTaskManager.swift
//  Aether
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks

class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()

	private let baseId = "\(Bundle.main.bundleIdentifier ?? "Aether").userTask"
	private let maximumDownloadTasks = 4
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []
	private var taskIdentifierByToken: [String: String] = [:]
	private var tokenByTaskIdentifier: [String: String] = [:]
	private var latestProgress: [String: Double] = [:]
	private var latestPresentation: [String: (title: String, subtitle: String)] = [:]
	private var completionBeforeLaunch: [String: Bool] = [:]
	private var expirationHandlers: [String: () -> Void] = [:]
	
	func startTask(for downloadId: String, filename: String) {
		_ = _startTask(
			for: downloadId,
			kind: .download,
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

	private func _startTask(
		for token: String,
		kind: TaskKind,
		title: String,
		subtitle: String,
		progress: Double,
		onExpiration: (() -> Void)? = nil
	) -> Bool {
		guard let taskIdentifier = _reserveTaskIdentifier(for: token, kind: kind) else {
			return false
		}
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
		guard let taskIdentifier = taskIdentifierByToken[token] else { return }
		let clampedProgress = min(max(progress, 0), 1)
		latestProgress[taskIdentifier] = clampedProgress

		let previousPresentation = latestPresentation[taskIdentifier]
		if let title, let subtitle {
			latestPresentation[taskIdentifier] = (title, subtitle)
		}

		if let task = activeTasks[taskIdentifier] {
			applyProgress(to: task, progress: clampedProgress)
			if
				let presentation = latestPresentation[taskIdentifier],
				previousPresentation?.title != presentation.title ||
				previousPresentation?.subtitle != presentation.subtitle
			{
				task.updateTitle(presentation.title, subtitle: presentation.subtitle)
			}
		}
	}

	private func _stopTask(for token: String, success: Bool) {
		guard let taskIdentifier = taskIdentifierByToken[token] else { return }
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

	private enum TaskKind {
		case download
		case pairing
	}

	private func _reserveTaskIdentifier(for token: String, kind: TaskKind) -> String? {
		if let taskIdentifier = taskIdentifierByToken[token] {
			return taskIdentifier
		}

		let candidates: [String]
		switch kind {
		case .download:
			candidates = (0..<maximumDownloadTasks).map { "\(baseId).download.\($0)" }
		case .pairing:
			candidates = ["\(baseId).pairing"]
		}

		guard let taskIdentifier = candidates.first(where: { tokenByTaskIdentifier[$0] == nil }) else {
			return nil
		}

		taskIdentifierByToken[token] = taskIdentifier
		tokenByTaskIdentifier[taskIdentifier] = token
		return taskIdentifier
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
		if let token = tokenByTaskIdentifier.removeValue(forKey: taskIdentifier) {
			taskIdentifierByToken.removeValue(forKey: token)
		}
	}

	private func applyProgress(to task: BGContinuedProcessingTask, progress: Double) {
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)
	}
}

#endif
