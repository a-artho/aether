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
	
	private let baseId = "\(Bundle.main.bundleIdentifier!).userTask"
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []
	private var latestProgress: [String: Double] = [:]
	private var completionBeforeLaunch: [String: Bool] = [:]
	
	func startTask(for downloadId: String, filename: String) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		completionBeforeLaunch.removeValue(forKey: taskIdentifier)
		latestProgress[taskIdentifier] = 0
		
		if !registeredTasks.contains(taskIdentifier) {
			let didRegister = BGTaskScheduler.shared.register(
				forTaskWithIdentifier: taskIdentifier,
				using: .main
			) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				task.progress.totalUnitCount = 100
				self.applyProgress(to: task, progress: self.latestProgress[task.identifier] ?? 0)
				
				task.expirationHandler = {
					DispatchQueue.main.async {
						self.activeTasks.removeValue(forKey: task.identifier)
						self.latestProgress.removeValue(forKey: task.identifier)
						self.completionBeforeLaunch.removeValue(forKey: task.identifier)
						task.setTaskCompleted(success: false)
					}
				}

				if let success = self.completionBeforeLaunch.removeValue(forKey: task.identifier) {
					task.setTaskCompleted(success: success)
					self.activeTasks.removeValue(forKey: task.identifier)
					self.latestProgress.removeValue(forKey: task.identifier)
				}
			}
			guard didRegister else {
				latestProgress.removeValue(forKey: taskIdentifier)
				return
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .fail
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			latestProgress.removeValue(forKey: taskIdentifier)
			print(error)
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		let clampedProgress = min(max(progress, 0), 1)
		latestProgress[taskIdentifier] = clampedProgress

		if let task = activeTasks[taskIdentifier] {
			applyProgress(to: task, progress: clampedProgress)
		}

		if clampedProgress >= 1 {
			stopTask(for: downloadId, success: true)
		}
	}
	
	func stopTask(for downloadId: String, success: Bool) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		if let task = activeTasks.removeValue(forKey: taskIdentifier) {
			task.setTaskCompleted(success: success)
			completionBeforeLaunch.removeValue(forKey: taskIdentifier)
		} else {
			completionBeforeLaunch[taskIdentifier] = success
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
		}
		latestProgress.removeValue(forKey: taskIdentifier)
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
