//
//  DownloadManager.swift
//  Aether
//

import CoreData
import Combine
import Foundation
import UIKit

class Download: ObservableObject, Identifiable, @unchecked Sendable {
	enum FailureAction: String, Codable, Equatable, Sendable {
		case resume
		case restart
		case retryProcessing
	}

	enum State: Equatable {
		case downloading
		case pausing
		case paused
		case resuming
		case processing
		case failed(String, FailureAction)
	}

	@Published var progress: Double = 0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0
	@Published var state: State

	var backgroundProgress: Double {
		if isSigningUpdate { return 0.55 }
		return overallProgress * (automaticUpdate == nil ? 1 : 0.5)
	}

	var overallProgress: Double {
		onlyArchiving
			? unpackageProgress
			: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var task: URLSessionDownloadTask?
	var resumeData: Data?
	var stagedFileName: String?
	var lastUIProgressUpdate: TimeInterval = 0
	var lastPersistedProgressUpdate: TimeInterval = 0
	var lastPersistedBytes: Int64 = 0

	/// Unique identity for this concrete transfer and all of its artifacts.
	let id: String
	/// Stable UI/source identity supplied by the caller.
	let logicalIdentifier: String
	let importIdentifier: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	let sourceIsStable: Bool
	var sourceProvenance: SourceAppProvenance?
	var automaticUpdate: AutomaticUpdateIntent?
	@Published var isSigningUpdate = false
	@Published var waitingForForeground = false
	var backgroundTaskTransferred = false
	var interruptionForegroundGeneration: UInt64 = 0

	init(
		transferIdentifier: String = UUID().uuidString,
		logicalIdentifier: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceIsStable: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil,
		state: State? = nil,
		fileName: String? = nil,
		stagedFileName: String? = nil,
		importIdentifier: String? = nil
	) {
		self.id = transferIdentifier
		self.logicalIdentifier = logicalIdentifier
		self.importIdentifier = importIdentifier ?? UUID().uuidString
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceIsStable = sourceIsStable
		self.sourceProvenance = sourceProvenance
		self.fileName = fileName ?? (url.lastPathComponent.isEmpty ? "Download.ipa" : url.lastPathComponent)
		self.stagedFileName = stagedFileName
		self.state = state ?? (onlyArchiving ? .processing : .downloading)
	}

	var isActive: Bool {
		switch state {
		case .downloading, .pausing, .resuming, .processing:
			return true
		case .paused, .failed:
			return false
		}
	}
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	static var backgroundSessionIdentifier: String {
		"\(Bundle.main.bundleIdentifier ?? "Aether").downloads"
	}

	@Published var downloads: [Download] = []

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.logicalIdentifier) }
	}

	private let _store = DownloadStore()
	private var _session: URLSession!
	private var _backgroundEventsCompletionHandler: (() -> Void)?
	private var _finishedEventsBeforeHandler = false
	private var _signingUpdates = Set<String>()
	private var _foregroundGeneration: UInt64 = 0
	private var _foregroundObserver: NSObjectProtocol?
	private var _backgroundObserver: NSObjectProtocol?
	private let _updateSigningGate = AutomaticUpdateSigningGate()
	private var _processingTasks: [String: Task<Void, Never>] = [:]
	private let _persistenceWriter = DownloadPersistenceWriter()
	private var _persistenceRevision: UInt64 = 0

	override init() {
		super.init()
		downloads = _store.loadDownloads()

		#if targetEnvironment(macCatalyst)
		let configuration = URLSessionConfiguration.default
		#else
		let configuration = URLSessionConfiguration.background(
			withIdentifier: Self.backgroundSessionIdentifier
		)
		configuration.sessionSendsLaunchEvents = true
		configuration.isDiscretionary = false
		configuration.waitsForConnectivity = true
		#endif
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

		_store.pruneArtifacts(keeping: downloads)
		_restoreSessionTasks()
		_foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?._foregroundGeneration &+= 1
				self?._resumeInterruptedProcessing()
				#if !targetEnvironment(macCatalyst)
				if let self { DownloadActivityManager.shared.reconcile(self.downloads) }
				#endif
			}
		}
		_backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				#if !targetEnvironment(macCatalyst)
				for download in self.downloads {
					guard case .processing = download.state,
						!BackgroundTaskManager.shared.hasExecution(for: download.id) else { continue }
					download.waitingForForeground = true
					download.interruptionForegroundGeneration = self._foregroundGeneration
					self._processingTasks[download.id]?.cancel()
				}
				self._persistDownloads()
				self._releaseIdleBackgroundTunnel()
				#endif
			}
		}
	}

	deinit {
		if let _backgroundObserver { NotificationCenter.default.removeObserver(_backgroundObserver) }
		if let _foregroundObserver { NotificationCenter.default.removeObserver(_foregroundObserver) }
	}

	func prepareForBackgroundEvents() {
		// Accessing the singleton recreates the background session during launch.
	}

	func setBackgroundEventsCompletionHandler(_ completionHandler: @escaping () -> Void) {
		if _finishedEventsBeforeHandler {
			_finishedEventsBeforeHandler = false
			completionHandler()
		} else {
			_backgroundEventsCompletionHandler = completionHandler
		}
	}

	func startDownload(
		from url: URL,
		id logicalIdentifier: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil,
		automaticUpdate: AutomaticUpdateIntent? = nil
	) async -> Download {
		if let existingDownload = getDownload(from: url, sourceProvenance: sourceProvenance) {
			return existingDownload
		}

		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			sourceProvenance: sourceProvenance
		)
		download.automaticUpdate = automaticUpdate
		downloads.append(download)
		guard await _persistBeforeResuming(download) else { return download }

		let task = _makeFreshTask(for: download)
		download.task = task
		_startDownloadActivity(for: download)
		task.resume()

		return download
	}

	func startArchive(
		from url: URL,
		id logicalIdentifier: String = UUID().uuidString,
		sourceIsStable: Bool = true
	) -> Download {
		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			onlyArchiving: true,
			sourceIsStable: sourceIsStable
		)
		downloads.append(download)
		_startDownloadActivity(for: download)
		return download
	}

	func pauseDownload(_ download: Download) {
		guard _isCurrent(download), case .downloading = download.state else { return }
		download.state = .pausing
		_persistDownloads()
		_requestResumeDataForPause(download)
	}

	func resumeDownload(_ download: Download) async {
		guard _isCurrent(download), case .paused = download.state else { return }
		guard let resumeData = download.resumeData else {
			_markRestartRequired(
				download,
				message: .localized("The saved download position is unavailable. Restart the download.")
			)
			return
		}

		download.state = .resuming
		let task = _session.downloadTask(withResumeData: resumeData)
		task.taskDescription = download.id
		download.task = task
		guard await _persistBeforeResuming(download) else { return }
		_startDownloadActivity(for: download)
		task.resume()
	}

	func restartDownload(_ download: Download) async {
		guard _isCurrent(download) else { return }
		download.task?.cancel()
		download.task = nil
		_store.cleanupArtifacts(for: download)
		download.resumeData = nil
		download.stagedFileName = nil
		download.progress = 0
		download.bytesDownloaded = 0
		download.totalBytes = 0
		download.unpackageProgress = 0
		download.state = .downloading

		let task = _makeFreshTask(for: download)
		download.task = task
		guard await _persistBeforeResuming(download) else { return }
		_startDownloadActivity(for: download)
		task.resume()
	}

	func retryDownload(_ download: Download) async {
		guard case .failed(_, let action) = download.state else { return }
		switch action {
		case .resume:
			download.state = .paused
			await resumeDownload(download)
		case .restart:
			await restartDownload(download)
		case .retryProcessing:
			retryProcessing(download)
		}
	}

	func retryProcessing(_ download: Download) {
		guard _isCurrent(download) else { return }

		if download.onlyArchiving {
			_startProcessing(download, sourceURL: download.url, sourceIsStable: download.sourceIsStable)
			return
		}

		guard
			let stagingURL = _store.stagingURL(for: download),
			FileManager.default.fileExists(atPath: stagingURL.path)
		else {
			_markRestartRequired(
				download,
				message: .localized("The downloaded IPA is no longer available. Restart the download.")
			)
			return
		}

		_startProcessing(download, sourceURL: stagingURL, sourceIsStable: true)
	}

	func deleteDownload(_ download: Download) {
		guard _isCurrent(download) else { return }
		#if !targetEnvironment(macCatalyst)
		DownloadActivityManager.shared.finish(download, status: .cancelled)
		#endif
		_processingTasks.removeValue(forKey: download.id)?.cancel()
		download.task?.cancel()
		download.task = nil
		_stopContinuedTask(for: download, success: false)

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}
		_persistDownloads()
		_releaseIdleBackgroundTunnel()
		_store.cleanupArtifacts(for: download)

		let importIdentifier = download.importIdentifier
		Task.detached(priority: .utility) {
			await AppFileHandler.removeImportTransaction(
				transactionIdentifier: importIdentifier
			)
		}
	}

	func isManualDownload(_ string: String) -> Bool {
		string.contains("AetherManualDownload")
	}

	/// Returns a transfer for the caller's logical source/app identifier.
	func getDownload(by logicalIdentifier: String) -> Download? {
		downloads.first(where: { $0.logicalIdentifier == logicalIdentifier })
	}

	/// UI lookup and transfer deduplication must use the same identity. A caller's
	/// model UUID can change when a source is refreshed or an app is decoded again.
	func getDownload(from url: URL, sourceProvenance: SourceAppProvenance?) -> Download? {
		let identity = _downloadIdentity(url: url, provenance: sourceProvenance)
		return downloads.first {
			_downloadIdentity(url: $0.url, provenance: $0.sourceProvenance) == identity
		}
	}

	private func _getDownload(transferIdentifier: String) -> Download? {
		downloads.first(where: { $0.id == transferIdentifier })
	}

	private func _getDownloadTask(_ task: URLSessionDownloadTask) -> Download? {
		if let transferIdentifier = task.taskDescription,
		   let download = _getDownload(transferIdentifier: transferIdentifier) {
			return download
		}
		return downloads.first(where: { $0.task === task })
	}

	private func _downloadIdentity(
		url: URL,
		provenance: SourceAppProvenance?
	) -> String {
		if let provenance {
			return "source|\(provenance.sourceVersionID)|\(url.absoluteString)"
		}
		return "url|\(url.absoluteString)"
	}

	private func _makeFreshTask(for download: Download) -> URLSessionDownloadTask {
		let task = _session.downloadTask(with: download.url)
		task.taskDescription = download.id
		return task
	}

	private func _requestResumeDataForPause(_ download: Download) {
		guard let task = download.task else {
			_markRestartRequired(
				download,
				message: .localized("The active system download is unavailable. Restart the download.")
			)
			return
		}

		task.cancel(byProducingResumeData: { [weak self, weak download] resumeData in
			DispatchQueue.main.async {
				guard
					let self,
					let download,
					self._isCurrent(download),
					case .pausing = download.state
				else { return }

				download.task = nil
				guard let resumeData else {
					self._markRestartRequired(
						download,
						message: .localized("This server did not provide resumable download data. Restart is required.")
					)
					return
				}

				do {
					try self._store.saveResumeData(resumeData, for: download.id)
					download.resumeData = resumeData
					download.state = .paused
					self._persistDownloads()
					self._stopContinuedTask(for: download, success: false)
				} catch {
					self._markRestartRequired(download, message: error.localizedDescription)
				}
			}
		})
	}

	private func _startProcessing(
		_ download: Download,
		sourceURL: URL,
		sourceIsStable: Bool
	) {
		guard _isCurrent(download), _processingTasks[download.id] == nil else { return }
		download.state = .processing
		#if !targetEnvironment(macCatalyst)
		DownloadActivityManager.shared.finish(download, status: .downloaded)
		#endif
		guard _ensureProcessingExecution(download, subtitle: .localized("Processing")) else { return }
		download.waitingForForeground = false
		download.unpackageProgress = 0
		_persistDownloads()

		let task = FR.handlePackageFile(
			sourceURL,
			download: download,
			transactionIdentifier: download.importIdentifier,
			copySource: !sourceIsStable
		) { [weak self, weak download] error in
			guard let self, let download else { return }
			self._processingTasks.removeValue(forKey: download.id)
			guard self._isCurrent(download) else { return }

			if download.waitingForForeground {
				self._persistDownloads()
				self._resumeInterruptedProcessing()
				return
			}
			if let error {
				if !(error is CancellationError) {
					UINotificationFeedbackGenerator().notificationOccurred(.error)
				}
				self._failProcessing(download, error: error)
			} else {
				self._complete(download: download)
			}
		}
		_processingTasks[download.id] = task
	}

	private func _restoreSessionTasks() {
		_session.getAllTasks { [weak self] tasks in
			DispatchQueue.main.async {
				guard let self else { return }
				var restoredIDs = Set<String>()
				var downloadsToPause: [Download] = []

				for task in tasks {
					guard let task = task as? URLSessionDownloadTask else {
						task.cancel()
						continue
					}

					let download = task.taskDescription.flatMap { description in
						self._getDownload(transferIdentifier: description)
							?? self.downloads.first(where: { $0.logicalIdentifier == description })
					} ?? self.downloads.first(where: {
						$0.url == task.originalRequest?.url && $0.isActive
					})

					guard let download else {
						task.cancel()
						continue
					}

					switch download.state {
					case .downloading, .pausing, .resuming:
						break
					case .paused, .processing, .failed:
						task.cancel()
						continue
					}

					task.taskDescription = download.id
					download.task = task
					restoredIDs.insert(download.id)

					if case .resuming = download.state,
					   let response = task.response as? HTTPURLResponse {
						if response.statusCode == 206, task.countOfBytesReceived > 0 {
							self._confirmResume(
								download,
								offset: max(task.countOfBytesReceived, download.bytesDownloaded),
								expectedTotalBytes: task.countOfBytesExpectedToReceive
							)
						} else if response.statusCode == 200 {
							download.task = nil
							task.cancel()
							self._markRestartRequired(
								download,
								message: .localized("The server restarted this download from the beginning. Choose Restart to continue.")
							)
							continue
						}
					}

					if case .pausing = download.state {
						downloadsToPause.append(download)
					} else if task.state == .suspended {
						task.resume()
					}
				}

				var downloadsToProcess: [(Download, URL)] = []
				for download in self.downloads {
					switch download.state {
					case .downloading where !restoredIDs.contains(download.id):
						self._restoreMissingTransfer(download)
					case .pausing where !restoredIDs.contains(download.id):
						if download.resumeData != nil {
							download.state = .paused
						} else {
							self._markRestartRequired(
								download,
								message: .localized("The app closed before pausing completed. Restart the download.")
							)
						}
					case .resuming where !restoredIDs.contains(download.id):
						if download.resumeData != nil {
							download.state = .paused
						} else {
							self._markRestartRequired(
								download,
								message: .localized("The resumed system download could not be restored. Restart the download.")
							)
						}
					case .processing:
						if download.automaticUpdate?.signedUUID != nil {
							self._complete(download: download)
							continue
						}
						if
							let stagingURL = self._store.stagingURL(for: download),
							FileManager.default.fileExists(atPath: stagingURL.path)
						{
							downloadsToProcess.append((download, stagingURL))
						} else {
							self._recoverCommittedImport(for: download)
						}
					default:
						break
					}
				}

				#if !targetEnvironment(macCatalyst)
				DownloadActivityManager.shared.reconcile(self.downloads)
				#endif
				self._persistDownloads()
				self._store.pruneArtifacts(keeping: self.downloads)
				for download in downloadsToPause {
					self._requestResumeDataForPause(download)
				}
				for (download, stagingURL) in downloadsToProcess {
					self._startProcessing(
						download,
						sourceURL: stagingURL,
						sourceIsStable: true
					)
				}
			}
		}
	}

	private func _restoreMissingTransfer(_ download: Download) {
		if download.resumeData != nil {
			download.state = .failed(
				.localized("The system download stopped. Resume from the saved position."),
				.resume
			)
		} else {
			_markRestartRequired(
				download,
				message: .localized("The system download could not be restored. Restart the download.")
			)
		}
	}

	private func _recoverCommittedImport(for download: Download) {
		FR.recoverPackageImport(download: download) { [weak self, weak download] result in
			guard let self, let download, self._isCurrent(download) else { return }
			switch result {
			case .success(true):
				self._complete(download: download)
			case .success(false):
				self._failProcessing(download, error: DownloadRecoveryError.missingStagedFile)
			case .failure(let error):
				self._failProcessing(download, error: error)
			}
		}
	}

	private func _complete(download: Download) {
		guard _isCurrent(download) else { return }
		if download.automaticUpdate != nil {
			_finishAutomaticUpdate(download)
			return
		}
		_finishDownload(download)
	}

	private func _finishDownload(_ download: Download) {
		guard _isCurrent(download) else { return }
		download.progress = 1
		download.unpackageProgress = 1
		#if !targetEnvironment(macCatalyst)
		if !download.backgroundTaskTransferred { BackgroundTaskManager.shared.updateProgress(for: download.id, progress: 1) }
		#endif
		if !download.backgroundTaskTransferred { _stopContinuedTask(for: download, success: true) }
		_store.cleanupArtifacts(for: download)

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}
		_persistDownloads()
		_releaseIdleBackgroundTunnel()
	}

	private func _failTransfer(
		_ download: Download,
		error: Error,
		resumeData: Data?
	) {
		guard _isCurrent(download) else { return }
		download.task = nil
		_store.removeStagingFile(for: download)
		download.stagedFileName = nil

		if let resumeData {
			do {
				try _store.saveResumeData(resumeData, for: download.id)
				download.resumeData = resumeData
				download.state = .failed(error.localizedDescription, .resume)
			} catch {
				download.resumeData = nil
				_store.removeResumeData(for: download.id)
				download.state = .failed(error.localizedDescription, .restart)
			}
		} else {
			download.resumeData = nil
			_store.removeResumeData(for: download.id)
			download.state = .failed(error.localizedDescription, .restart)
		}

		_stopContinuedTask(for: download, success: false)
		_persistDownloads()
	}

	private func _failProcessing(_ download: Download, error: Error) {
		guard _isCurrent(download) else { return }
		download.task = nil
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		download.state = .failed(error.localizedDescription, .retryProcessing)
		_stopContinuedTask(for: download, success: false)
		_persistDownloads()
	}

	private func _failResumeAttempt(
		_ download: Download,
		error: Error,
		newResumeData: Data?
	) {
		guard _isCurrent(download) else { return }
		download.task = nil

		if let newResumeData {
			do {
				try _store.saveResumeData(newResumeData, for: download.id)
				download.resumeData = newResumeData
			} catch {
				// The previously persisted token remains the last known-good retry point.
			}
		}

		if download.resumeData != nil {
			download.state = .failed(error.localizedDescription, .resume)
			_stopContinuedTask(for: download, success: false)
			_persistDownloads()
		} else {
			_markRestartRequired(
				download,
				message: .localized("The saved download position is unavailable. Restart the download.")
			)
		}
	}

	private func _markRestartRequired(_ download: Download, message: String) {
		guard _isCurrent(download) else { return }
		download.task = nil
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		download.state = .failed(message, .restart)
		_stopContinuedTask(for: download, success: false)
		_persistDownloads()
	}

	private func _confirmResume(
		_ download: Download,
		offset: Int64,
		expectedTotalBytes: Int64
	) {
		guard _isCurrent(download), offset > 0 else { return }
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		download.bytesDownloaded = offset
		if expectedTotalBytes > 0 {
			download.totalBytes = expectedTotalBytes
			download.progress = min(Double(offset) / Double(expectedTotalBytes), 1)
		}
		download.state = .downloading
		_persistDownloads()
	}

	private func _persistDownloads(immediately: Bool = true) {
		#if !targetEnvironment(macCatalyst)
		for download in downloads { DownloadActivityManager.shared.update(download) }
		#endif
		_persistenceRevision &+= 1
		let revision = _persistenceRevision
		let records = downloads
			.filter { !$0.onlyArchiving }
			.map(StoredDownload.init)
		let writer = _persistenceWriter
		Task {
			await writer.schedule(records: records, immediately: immediately, revision: revision)
		}
	}

	private func _persistBeforeResuming(_ download: Download) async -> Bool {
		_persistenceRevision &+= 1
		let revision = _persistenceRevision
		let records = downloads
			.filter { !$0.onlyArchiving }
			.map(StoredDownload.init)
		do {
			try await _persistenceWriter.commit(records: records, revision: revision)
			return true
		} catch {
			download.task = nil
			download.state = .failed(
				"Aether couldn’t save this download before starting it: \(error.localizedDescription)",
				.restart
			)
			await DebugLogManager.shared.log(
				"Could not persist download before resuming: \(error.localizedDescription)",
				category: "Download",
				level: .error
			)
			_persistDownloads()
			return false
		}
	}

	private func _isCurrent(_ download: Download) -> Bool {
		downloads.contains(where: { $0 === download })
	}

	private func _ensureProcessingExecution(_ download: Download, subtitle: String) -> Bool {
		#if !targetEnvironment(macCatalyst)
		let accepted = BackgroundTaskManager.shared.startWork(for: download.id,
			title: download.sourceProvenance?.sourceAppName ?? download.fileName,
			subtitle: subtitle, progress: download.backgroundProgress) { [weak self, weak download] in
			guard let self, let download, self._isCurrent(download) else { return }
			// URLSession owns networking independently. Only defer in-app work.
			guard case .processing = download.state else { return }
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = self._foregroundGeneration
			self._processingTasks[download.id]?.cancel()
			self._persistDownloads()
			self._releaseIdleBackgroundTunnel()
			DebugLogManager.shared.log("Processing interrupted; retaining the IPA and Update intent for foreground recovery.", category: "Background", level: .notice)
		}
		if !accepted, UIApplication.shared.applicationState != .active {
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = _foregroundGeneration
			_persistDownloads()
			return false
		}
		#endif
		return true
	}

	private func _resumeInterruptedProcessing() {
		guard UIApplication.shared.applicationState == .active else { return }
		for download in downloads where download.waitingForForeground && _foregroundGeneration > download.interruptionForegroundGeneration {
			guard _processingTasks[download.id] == nil, !_signingUpdates.contains(download.id) else { continue }
			download.waitingForForeground = false
			if download.automaticUpdate?.signedUUID != nil { _complete(download: download) }
			else { retryProcessing(download) }
		}
	}

	private func _startDownloadActivity(for download: Download) {
		if download.onlyArchiving {
			_ = _ensureProcessingExecution(download, subtitle: .localized("Processing"))
			return
		}
		#if !targetEnvironment(macCatalyst)
		DownloadActivityManager.shared.start(download)
		#endif
	}

	private func _stopContinuedTask(for download: Download, success: Bool) {
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.stopTask(for: download.id, success: success)
		#endif
		_releaseIdleBackgroundTunnel()
	}

	private func _releaseIdleBackgroundTunnel() {
		if UIApplication.shared.applicationState == .background { DeviceConnectionManager.shared.handleAppBackground() }
	}
}

// This session is created with delegateQueue: .main. Keep callbacks synchronous:
// the downloaded temporary file must be moved before its delegate method returns.
extension DownloadManager: @preconcurrency URLSessionDownloadDelegate {
	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		guard
			let download = _getDownloadTask(downloadTask),
			_isCurrent(download),
			download.task === downloadTask
		else { return }

		guard case .downloading = download.state else {
			download.task = nil
			downloadTask.cancel()
			_markRestartRequired(
				download,
				message: .localized("The resumed download could not be verified. Restart the download.")
			)
			return
		}

		do {
			try _validateResponse(downloadTask.response)
			try _validateArchive(at: location)
			let destinationURL = try _store.makeStagingURL(
				for: download,
				suggestedFilename: downloadTask.response?.suggestedFilename
			)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destinationURL.path)

			download.task = nil
			download.resumeData = nil
			download.progress = 1
			if downloadTask.countOfBytesReceived > 0 {
				download.bytesDownloaded = downloadTask.countOfBytesReceived
				download.totalBytes = max(
					downloadTask.countOfBytesExpectedToReceive,
					downloadTask.countOfBytesReceived
				)
			}
			download.stagedFileName = destinationURL.lastPathComponent
			_store.removeResumeData(for: download.id)
			_persistDownloads()
			_startProcessing(download, sourceURL: destinationURL, sourceIsStable: true)
		} catch {
			_failTransfer(download, error: error, resumeData: nil)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard
			let download = _getDownloadTask(downloadTask),
			_isCurrent(download),
			download.task === downloadTask,
			case .downloading = download.state
		else { return }

		let now = Date.timeIntervalSinceReferenceDate
		let shouldUpdateUI = now - download.lastUIProgressUpdate >= 0.125
			|| totalBytesWritten == totalBytesExpectedToWrite
		let shouldPersist = now - download.lastPersistedProgressUpdate >= 1
			|| totalBytesWritten - download.lastPersistedBytes >= 5 * 1024 * 1024

		if shouldUpdateUI || shouldPersist {
			download.progress = totalBytesExpectedToWrite > 0
				? min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)
				: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
		}

		if shouldUpdateUI {
			download.lastUIProgressUpdate = now
			#if !targetEnvironment(macCatalyst)
			DownloadActivityManager.shared.update(download)
			#endif
		}

		if shouldPersist {
			download.lastPersistedProgressUpdate = now
			download.lastPersistedBytes = totalBytesWritten
			_persistDownloads(immediately: false)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didResumeAtOffset fileOffset: Int64,
		expectedTotalBytes: Int64
	) {
		guard
			let download = _getDownloadTask(downloadTask),
			_isCurrent(download),
			download.task === downloadTask,
			case .resuming = download.state
		else { return }

		guard fileOffset > 0 else {
			download.task = nil
			downloadTask.cancel()
			_markRestartRequired(
				download,
				message: .localized("The server restarted this download from byte zero. Choose Restart to continue.")
			)
			return
		}

		_confirmResume(
			download,
			offset: fileOffset,
			expectedTotalBytes: expectedTotalBytes
		)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = _getDownloadTask(downloadTask),
			_isCurrent(download),
			download.task === downloadTask
		else {
			return
		}

		if case .pausing = download.state {
			return
		}

		if case .resuming = download.state {
			let nsError = error as NSError
			if let newResumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
				_failResumeAttempt(
					download,
					error: error,
					newResumeData: newResumeData
				)
			} else {
				download.task = nil
				_markRestartRequired(
					download,
					message: .localized("The saved download position was rejected. Restart the download.")
				)
			}
			return
		}

		let nsError = error as NSError
		let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
		_failTransfer(download, error: error, resumeData: resumeData)
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		if let completionHandler = _backgroundEventsCompletionHandler {
			_backgroundEventsCompletionHandler = nil
			completionHandler()
		} else {
			_finishedEventsBeforeHandler = true
		}
	}

	private func _validateResponse(_ response: URLResponse?) throws {
		guard let response = response as? HTTPURLResponse else {
			throw DownloadValidationError.invalidResponse
		}
		guard (200..<300).contains(response.statusCode) else {
			throw DownloadValidationError.httpStatus(response.statusCode)
		}
	}

	private func _validateArchive(at url: URL) throws {
		let file = try FileHandle(forReadingFrom: url)
		defer { try? file.close() }
		let signature = try file.read(upToCount: 4) ?? Data()
		let validSignatures: Set<Data> = [
			Data([0x50, 0x4B, 0x03, 0x04]),
			Data([0x50, 0x4B, 0x05, 0x06]),
			Data([0x50, 0x4B, 0x07, 0x08])
		]
		guard validSignatures.contains(signature) else {
			throw DownloadValidationError.invalidArchive
		}
	}
}

private enum DownloadRecoveryError: LocalizedError {
	case missingStagedFile

	var errorDescription: String? {
		.localized("The downloaded file is no longer available. Restart the download.")
	}
}

private enum DownloadValidationError: LocalizedError {
	case invalidResponse
	case httpStatus(Int)
	case invalidArchive

	var errorDescription: String? {
		switch self {
		case .invalidResponse:
			return .localized("The download server returned an invalid response.")
		case .httpStatus(let statusCode):
			let description = HTTPURLResponse.localizedString(forStatusCode: statusCode)
			return .localized("The download failed with HTTP %d (%@).", arguments: statusCode, description)
		case .invalidArchive:
			return .localized("The downloaded file is not a valid IPA archive.")
		}
	}
}

/// Persisted with the transfer, so pause/retry and background recovery retain
/// the user's Update intent. Certificate secrets stay in certificate storage.
struct AutomaticUpdateIntent: Codable {
	let bundleIdentifier: String
	let installedVersion: String?
	let certificateUUID: String
	let teamIdentifier: String?
	var options: Options
	var signedUUID: String?
	var installationEnqueued: Bool?
}

private actor AutomaticUpdateSigningGate {
	private var occupied = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	func acquire() async {
		if !occupied { occupied = true; return }
		await withCheckedContinuation { waiters.append($0) }
	}
	func release() {
		if waiters.isEmpty { occupied = false }
		else { waiters.removeFirst().resume() }
	}
}

private struct AutomaticUpdateError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

extension DownloadManager {
	func startUpdate(from url: URL, id: String, sourceProvenance: SourceAppProvenance?, installedApp: InstalledApp) async {
		// A transfer started in app details remains download-only. Never silently
		// convert an already running normal download into an installation.
		guard getDownload(from: url, sourceProvenance: sourceProvenance) == nil else { return }
		do {
			let certificates = Storage.shared.getAllCertificates()
			let selectedUUID = UserDefaults.standard.string(forKey: "aether.selectedCertUUID")
			let index = UserDefaults.standard.integer(forKey: "aether.selectedCert")
			let certificate = certificates.first { $0.uuid == selectedUUID }
				?? (certificates.indices.contains(index) ? certificates[index] : nil)
			guard let certificate, let uuid = certificate.uuid else {
				throw AutomaticUpdateError(message: .localized("Select a signing certificate in Library before updating."))
			}
			let team = installedApp.appInfo?.Entitlements?["com.apple.developer.team-identifier"]?.value as? String
			try _validateUpdateCertificate(certificate, team: team)
			var options = OptionsManager.shared.options
			// Updating must replace this app, even when normal signing preferences
			// rename identifiers or override the displayed version.
			options.appIdentifier = installedApp.bundleIdentifier
			options.appVersion = nil
			options.appName = nil
			options.signingOption = .default
			let intent = AutomaticUpdateIntent(bundleIdentifier: installedApp.bundleIdentifier,
				installedVersion: installedApp.version, certificateUUID: uuid,
				teamIdentifier: team, options: options)
			DebugLogManager.shared.log("Automatic update started for \(installedApp.bundleIdentifier).", category: "Update", level: .notice)
			_ = await startDownload(from: url, id: id, sourceProvenance: sourceProvenance, automaticUpdate: intent)
		} catch {
			DebugLogManager.shared.log("Update preflight failed: \(error.localizedDescription)", category: "Update", level: .error)
			UIAlertController.showAlertWithOk(title: .localized("Update"), message: error.localizedDescription)
		}
	}

	private func _validateUpdateCertificate(_ certificate: CertificatePair, team: String?) throws {
		guard !certificate.revoked, let expiration = certificate.expiration, expiration > Date(),
			SigningCertificateSnapshot(certificate) != nil,
			let provision = Storage.shared.getProvisionFileDecoded(for: certificate) else {
			throw AutomaticUpdateError(message: .localized("The selected signing certificate is unavailable, expired, or revoked."))
		}
		if let team, !team.isEmpty, !provision.TeamIdentifier.contains(team) {
			throw AutomaticUpdateError(message: .localized("Choose a certificate from the installed app’s signing team to update it."))
		}
	}

	private func _finishAutomaticUpdate(_ download: Download) {
		if download.automaticUpdate?.installationEnqueued == true { _finishDownload(download); return }
		guard _isCurrent(download), !_signingUpdates.contains(download.id),
			_ensureProcessingExecution(download, subtitle: .localized("Signing Update")) else { return }
		_signingUpdates.insert(download.id)
		download.waitingForForeground = false
		download.state = .processing
		download.isSigningUpdate = true
		_persistDownloads()
		Task {
			await _updateSigningGate.acquire()
			do {
				guard _isCurrent(download), !download.waitingForForeground, var intent = download.automaticUpdate else {
					throw CancellationError()
				}
				let certificate = Storage.shared.getAllCertificates().first { $0.uuid == intent.certificateUUID }
				guard let certificate else {
					throw AutomaticUpdateError(message: .localized("The signing certificate was removed. Import it again before retrying."))
				}
				try _validateUpdateCertificate(certificate, team: intent.teamIdentifier)
				if intent.signedUUID == nil {
					let request: NSFetchRequest<Imported> = Imported.fetchRequest()
					request.fetchLimit = 1
					request.predicate = NSPredicate(format: "uuid == %@", download.importIdentifier)
					guard let imported = try Storage.shared.context.fetch(request).first,
						imported.identifier == intent.bundleIdentifier,
						InstalledAppUpdateCatalog.isNewer(imported.version, than: intent.installedVersion) else {
						throw AutomaticUpdateError(message: .localized("The downloaded app’s identifier or version does not match this update."))
					}
					DebugLogManager.shared.log("Signing update for \(intent.bundleIdentifier).", category: "Update", level: .notice)
					let signedUUID: String = try await withCheckedThrowingContinuation { continuation in
						FR.signPackageFile(imported, using: intent.options, icon: nil, certificate: certificate, backgroundTaskToken: download.id) {
							continuation.resume(with: $0)
						}
					}
					guard _isCurrent(download) else {
						if let signed = Storage.shared.signedApp(uuid: signedUUID) { Storage.shared.deleteApp(for: signed) }
						throw CancellationError()
					}
					intent.signedUUID = signedUUID
					download.automaticUpdate = intent
					guard await _persistBeforeResuming(download) else {
						download.state = .failed(.localized("Could not save the signed update. Retry processing."), .retryProcessing)
						_persistDownloads()
						throw CancellationError()
					}
				}
				guard _isCurrent(download), let uuid = intent.signedUUID,
					let signed = Storage.shared.signedApp(uuid: uuid) else {
					throw AutomaticUpdateError(message: .localized("The signed update is no longer available."))
				}
				DebugLogManager.shared.log("Sending update to the install queue for \(intent.bundleIdentifier).", category: "Update", level: .notice)
				guard !download.waitingForForeground else { throw CancellationError() }
				download.backgroundTaskTransferred = AppInstallationManager.shared.startInstall(app: signed, backgroundTaskToken: download.id, retryExisting: false)
				guard AppInstallationManager.shared.containsInstallation(for: signed) else {
					throw AutomaticUpdateError(message: .localized("The update could not enter the install queue. Check the installation method and retry."))
				}
				intent.installationEnqueued = true
				download.automaticUpdate = intent
				_ = await _persistBeforeResuming(download)
				if intent.options.post_deleteAppAfterSigned {
					let request: NSFetchRequest<Imported> = Imported.fetchRequest()
					request.fetchLimit = 1
					request.predicate = NSPredicate(format: "uuid == %@", download.importIdentifier)
					if let imported = try? Storage.shared.context.fetch(request).first { Storage.shared.deleteApp(for: imported) }
				}
				_finishDownload(download)
			} catch is CancellationError {
				// Removal cancels automatic installation, including during signing.
			} catch {
				_failProcessing(download, error: error)
				DebugLogManager.shared.log("Automatic update stopped: \(error.localizedDescription)", category: "Update", level: .error)
				if _isCurrent(download) {
					UIAlertController.showAlertWithOk(title: .localized("Update Failed"), message: error.localizedDescription)
				}
			}
			download.isSigningUpdate = false
			_signingUpdates.remove(download.id)
			await _updateSigningGate.release()
			_resumeInterruptedProcessing()
		}
	}
}
