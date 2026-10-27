import UIKit

/// One execution lifetime for the serialized signing/install queue.
@MainActor
final class AppOperationExecution {
	private let token = "app-queue-\(UUID().uuidString)"
	private var title = String.localized("Installing App")
	private var subtitle = String.localized("Queued")
	private var includesSigning = false
	private var installationStarted = false
	private var isSigning = false
	private var completedJobs = 0
	private var totalJobs = 1
	private var phaseProgress = 0.0
	private var jobComplete = false
	private var serverAudioStarted = false
	private(set) var isFinished = false

	var isInterrupted: Bool {
		#if targetEnvironment(macCatalyst)
		return false
		#else
		return BackgroundTaskManager.shared.isCancellationRequested(for: token)
		#endif
	}

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
		installationStarted = false
		isSigning = signing
		jobComplete = false
		phaseProgress = 0
		subtitle = signing ? .localized("Signing") : .localized("Preparing Installation")
		#if targetEnvironment(macCatalyst)
		return true
		#else
		guard hasExecution || UIApplication.shared.applicationState == .active else { return false }
		return BackgroundTaskManager.shared.startWork(for: token, title: title, subtitle: queueSubtitle,
			progress: progress, installation: true) { [weak self] in
			self?.finish(success: false)
			onExpiration()
		}
		#endif
	}

	func updateSigning(progress: Double) {
		guard !installationStarted, !jobComplete else { return }
		subtitle = .localized("Signing")
		if bounded(progress) == 1 { isSigning = false }
		phaseProgress = max(phaseProgress, includesSigning ? bounded(progress) * 0.3 : bounded(progress))
		publish()
	}

	func updateInstallation(subtitle: String, progress: Double) {
		guard !isSigning, !jobComplete else { return }
		installationStarted = true
		self.subtitle = subtitle
		phaseProgress = max(phaseProgress, includesSigning ? 0.3 + bounded(progress) * 0.7 : bounded(progress))
		publish()
	}

	func completeJob() {
		guard !jobComplete else { return }
		jobComplete = true
		completedJobs += 1
		phaseProgress = 0
		publish()
	}

	private func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

	private var queueSubtitle: String {
		let position = min(totalJobs, completedJobs + (jobComplete ? 0 : 1))
		return String.localized("%d of %d · %@", arguments: max(1, position), totalJobs, subtitle)
	}

	func setWorker(_ worker: Task<Void, Never>?) {
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.setCancellationHandler(for: token) { worker?.cancel() }
		#endif
	}

	private var progress: Double {
		min(1, (Double(completedJobs) + min(0.99, max(0, phaseProgress))) / Double(totalJobs))
	}

	private func publish() {
		guard !isFinished else { return }
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.updateWork(for: token, title: title, subtitle: queueSubtitle, progress: progress)
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

	/// Finishes this app-owned task after handing installation responsibility to
	/// iOS. The Live Activity ends successfully but does not claim install success.
	func finishForHandoff() {
		guard !isFinished else { return }
		isFinished = true
		stopServerAudio()
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.finishTaskForHandoff(for: token)
		#endif
	}
}
