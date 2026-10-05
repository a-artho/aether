import UIKit

/// One execution lifetime for the serialized signing/install queue.
@MainActor
final class AppOperationExecution {
	private let token = "app-queue-\(UUID().uuidString)"
	private var title = String.localized("Installing App")
	private var subtitle = String.localized("Queued")
	private var includesSigning = false
	private var completedJobs = 0
	private var totalJobs = 1
	private var phaseProgress = 0.0
	private var jobComplete = false
	private var serverAudioStarted = false
	private(set) var isFinished = false

	var hasExecution: Bool {
		#if targetEnvironment(macCatalyst)
		return !isFinished
		#else
		return !isFinished && BackgroundTaskManager.shared.hasExecution(for: token)
		#endif
	}

	func updateQueue(pendingJobs: Int) {
		totalJobs = max(1, completedJobs + pendingJobs)
		publish()
	}

	@discardableResult
	func beginJob(title: String, signing: Bool, installsAfterSigning: Bool = true, onExpiration: @escaping () -> Void) -> Bool {
		guard !isFinished else { return false }
		self.title = title
		self.includesSigning = signing && installsAfterSigning
		jobComplete = false
		phaseProgress = 0
		subtitle = signing ? .localized("Signing") : .localized("Preparing Installation")
		#if targetEnvironment(macCatalyst)
		return true
		#else
		guard hasExecution || UIApplication.shared.applicationState == .active else { return false }
		return BackgroundTaskManager.shared.startWork(for: token, title: title, subtitle: subtitle,
			progress: progress, installation: true) { [weak self] in
			self?.finish(success: false)
			onExpiration()
		}
		#endif
	}

	func updateSigning(progress: Double) {
		guard !jobComplete else { return }
		subtitle = .localized("Signing")
		phaseProgress = includesSigning ? progress * 0.3 : progress
		publish()
	}

	func updateInstallation(subtitle: String, progress: Double) {
		guard !jobComplete else { return }
		self.subtitle = subtitle
		phaseProgress = includesSigning ? 0.3 + progress * 0.7 : progress
		publish()
	}

	func completeJob() {
		guard !jobComplete else { return }
		jobComplete = true
		completedJobs += 1
		phaseProgress = 0
		publish()
	}

	private var progress: Double {
		min(1, (Double(completedJobs) + min(1, max(0, phaseProgress))) / Double(totalJobs))
	}

	private func publish() {
		guard !isFinished else { return }
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.updateWork(for: token, title: title, subtitle: subtitle, progress: progress)
		#endif
	}

	func startServerAudio() {
		guard !isFinished, !serverAudioStarted else { return }
		serverAudioStarted = true
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start(token)
		#endif
	}

	func stopServerAudio() {
		guard serverAudioStarted else { return }
		serverAudioStarted = false
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop(token)
		#endif
	}

	func finish(success: Bool) {
		guard !isFinished else { return }
		isFinished = true
		stopServerAudio()
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.stopTask(for: token, success: success)
		#endif
	}
}
