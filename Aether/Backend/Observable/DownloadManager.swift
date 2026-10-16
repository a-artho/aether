//
//  DownloadManager.swift
//  Aether
//

import Combine
import Foundation
import UIKit
import UserNotifications
import NimbleExtensions

@MainActor
class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	static var backgroundSessionIdentifier: String {
		"\(Bundle.main.bundleIdentifier ?? "Aether").downloads"
	}

	@Published var downloads: [Download] = []

	var hasActiveWork: Bool { downloads.contains(where: \.isActive) || !_processingTasks.isEmpty || _retiringProcessingCount > 0 }

	private let _store = DownloadStore()
	private var _session: URLSession!
	private var _restorableTransferIDs = Set<String>()
	private var _restoringTransferIDs = Set<String>()
	private var _backgroundEventsCompletionHandler: (() -> Void)?
	private var _finishedEventsBeforeHandler = false
	private var _foregroundGeneration: UInt64 = 0
	private var _foregroundObserver: NSObjectProtocol?
	private var _backgroundObserver: NSObjectProtocol?
	private var _processingTasks: [String: Task<Void, Never>] = [:]
	@Published private var _retiringProcessingCount = 0
	private var _archiveSourceCleanup: [String: @Sendable () -> Void] = [:]
	private let _persistenceWriter = DownloadPersistenceWriter()
	private var _persistenceRevision: UInt64 = 0

	override init() {
		super.init()
		downloads = _store.loadDownloads()
		_restorableTransferIDs = Set(downloads.filter { $0.state == .downloading || $0.state == .pausing || $0.state == .resuming }.map(\.id))
		_restoringTransferIDs = _restorableTransferIDs

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
				guard let self, UIApplication.shared.applicationState == .active else { return }
				self._foregroundGeneration &+= 1
				self._resumeInterruptedProcessing()
			}
		}
		_backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				guard let self, UIApplication.shared.applicationState == .background else { return }
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

	isolated deinit {
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
		sourceProvenance: SourceAppProvenance? = nil
	) async -> Download {
		if let existingDownload = getDownload(from: url, sourceProvenance: sourceProvenance) {
			return existingDownload
		}

		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			sourceProvenance: sourceProvenance
		)
		downloads.append(download)
		if AppMaintenanceGuard.isResetting {
			download.state = .failed(.localized("Wait for the reset to finish."), download.onlyArchiving ? .retryProcessing : .restart)
			return download
		}
		LibraryArtifactIndex.shared.recordImport(uuid: download.importIdentifier)
		let task = _makeFreshTask(for: download)
		download.task = task
		_startDownloadExecution(for: download)
		guard await _persistBeforeResuming(download) else { return download }
		guard _isCurrent(download), download.task === task, case .downloading = download.state else {
			task.cancel()
			return download
		}
		task.resume()

		return download
	}

	func startArchive(
		from url: URL,
		id logicalIdentifier: String = UUID().uuidString,
		sourceIsStable: Bool = true,
		sourceCleanup: (@Sendable () -> Void)? = nil
	) -> Download {
		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			onlyArchiving: true,
			sourceIsStable: sourceIsStable
		)
		downloads.append(download)
		if AppMaintenanceGuard.isResetting {
			download.state = .failed(.localized("Wait for the reset to finish."), download.onlyArchiving ? .retryProcessing : .restart)
			return download
		}
		LibraryArtifactIndex.shared.recordImport(uuid: download.importIdentifier)
		_archiveSourceCleanup[download.id] = sourceCleanup
		_persistDownloads()
		return download
	}

	/// Publish the row and acquire execution before a file provider starts copying.
	func startExternalArchive(from url: URL, id: String) {
		let download = startArchive(from: url, id: id, sourceIsStable: false)
		download.isPreparingSource = true
		retryProcessing(download)
	}

	private func _prepareExternalArchive(_ download: Download) {
		guard _isCurrent(download), _processingTasks[download.id] == nil else { return }
		download.state = .processing
		download.isPreparingSource = true
		guard _ensureProcessingExecution(download, subtitle: .localized("Preparing Import")) else { return }
		download.waitingForForeground = false
		let destinationURL: URL
		do { destinationURL = try _store.makeStagingURL(for: download, suggestedFilename: download.fileName) }
		catch { _failProcessing(download, error: error); return }
		_persistDownloads()
		let sourceURL = download.url
		let worker = Task.detached(priority: .utility) { [weak self] in
			let result = Result {
				try Task.checkCancellation()
				let file = try FileManager.default.materializePackageForImport(at: sourceURL) { message in
					Task { @MainActor in
						DebugLogManager.shared.log("[\(download.id)] \(message)", category: "Import")
					}
				}
				defer { file.cleanup() }
				try Task.checkCancellation()
				let fileManager = FileManager.default
				let partialURL = destinationURL.appendingPathExtension("partial")
				defer { try? fileManager.removeItem(at: partialURL) }
				try fileManager.removeFileIfNeeded(at: partialURL)
				try fileManager.copyItemPreferClone(at: file.fileURL, to: partialURL)
				try Task.checkCancellation()
				try fileManager.removeFileIfNeeded(at: destinationURL)
				try fileManager.moveItem(at: partialURL, to: destinationURL)
				return destinationURL
			}
			await self?._externalArchivePrepared(download, result: result)
		}
		_processingTasks[download.id] = worker
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.setCancellationHandler(for: download.id) { worker.cancel() }
		#endif
	}

	private func _externalArchivePrepared(_ download: Download, result: Result<URL, Error>) {
		_processingTasks.removeValue(forKey: download.id)
		guard _isCurrent(download) else {
			if case .success(let url) = result { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) } }
			return
		}
		#if !targetEnvironment(macCatalyst)
		if BackgroundTaskManager.shared.isCancellationRequested(for: download.id) {
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = _foregroundGeneration
		}
		#endif
		switch result {
		case .success(let url):
			download.stagedFileName = url.lastPathComponent
			download.isPreparingSource = false
			_persistDownloads()
			// Keep this import's execution across copying and extraction when the gate is free.
			if download.waitingForForeground { _resumeInterruptedProcessing() }
			else { _startProcessing(download, sourceURL: url, sourceIsStable: true) }
		case .failure(let error):
			if download.waitingForForeground { _resumeInterruptedProcessing() }
			else { _failProcessing(download, error: error) }
		}
	}

	func pauseDownload(_ download: Download) {
		guard _isCurrent(download) else { return }
		guard download.state == .downloading || download.state == .resuming else { return }
		download.state = .pausing
		_persistDownloads()
		_requestResumeDataForPause(download)
	}

	func resumeDownload(_ download: Download) async {
		guard _isCurrent(download), case .paused = download.state else { return }
		_restorableTransferIDs.remove(download.id)
		_restoringTransferIDs.remove(download.id)
		guard let resumeData = download.resumeData else {
			if download.bytesDownloaded == 0 { await restartDownload(download); return }
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
		_startDownloadExecution(for: download)
		guard await _persistBeforeResuming(download) else { return }
		guard _isCurrent(download), download.task === task, case .resuming = download.state else {
			task.cancel()
			return
		}
		task.resume()
	}

	func restartDownload(_ download: Download) async {
		guard _isCurrent(download) else { return }
		_restorableTransferIDs.remove(download.id)
		_restoringTransferIDs.remove(download.id)
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
		_startDownloadExecution(for: download)
		guard await _persistBeforeResuming(download) else { return }
		guard _isCurrent(download), download.task === task, case .downloading = download.state else {
			task.cancel()
			return
		}
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
		guard !AppMaintenanceGuard.isResetting else { return }
		guard _isCurrent(download) else { return }

		if download.onlyArchiving && download.stagedFileName == nil {
			_prepareExternalArchive(download)
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

	func deleteDownload(_ download: Download, completion: (@MainActor @Sendable () -> Void)? = nil) {
		guard _isCurrent(download) else { completion?(); return }
		let processing = _processingTasks.removeValue(forKey: download.id)
		if processing != nil { _retiringProcessingCount += 1 }
		let sourceCleanup = _archiveSourceCleanup.removeValue(forKey: download.id)
		processing?.cancel()
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
			await processing?.value
			await MainActor.run { self._store.cleanupArtifacts(for: download) }
			sourceCleanup?()
			await AppFileHandler.removeImportTransaction(
				transactionIdentifier: importIdentifier
			)
			if processing != nil { await MainActor.run { self._retiringProcessingCount -= 1 } }
			await completion?()
		}
	}

	func usesLibraryArtifact(_ app: AppInfoPresentable) -> Bool {
		guard let uuid = app.uuid else { return false }
		return downloads.contains { download in
			!app.isSigned && download.importIdentifier == uuid && download.isActive
		}
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
			// Only a transfer saved at launch may adopt an early system callback.
			// Retries remove this permission before creating a replacement task.
			if download.task == nil, _restorableTransferIDs.remove(download.id) != nil {
				download.task = task
			}
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

		#if !targetEnvironment(macCatalyst)
		let checkpoint = DownloadCheckpointLease()
		#endif
		task.cancel(byProducingResumeData: { [weak self, weak download] resumeData in
			DispatchQueue.main.async { [weak self, weak download] in
				#if !targetEnvironment(macCatalyst)
				defer { checkpoint.end() }
				#endif
				guard
					let self,
					let download,
					self._isCurrent(download),
					download.task === task,
					case .pausing = download.state
				else { return }

				download.task = nil
				guard let resumeData else {
					if download.bytesDownloaded == 0 {
						download.state = .paused
						self._stopContinuedTask(for: download, success: false)
						self._persistDownloads()
						return
					}
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
		download.unpackageProgress = 0
		download.waitingForForeground = false
		_persistDownloads()

		let task = FR.handlePackageFile(
			sourceURL,
			download: download,
			transactionIdentifier: download.importIdentifier,
			copySource: !sourceIsStable,
			beginProcessing: { [weak self, weak download] in
				guard let self, let download, self._isCurrent(download), !Task.isCancelled else { return false }
				guard self._ensureProcessingExecution(download, subtitle: .localized("Processing")) else { return false }
				#if !targetEnvironment(macCatalyst)
				if let worker = self._processingTasks[download.id] {
					BackgroundTaskManager.shared.setCancellationHandler(for: download.id) { worker.cancel() }
				}
				#endif
				return true
			},
			waitingForProcessing: { [weak self, weak download] in
				guard let self, let download, self._isCurrent(download) else { return }
				// A queued import must not hold an idle execution grant.
				self._stopContinuedTask(for: download, success: true)
			}
		) { [weak self, weak download] error in
			guard let self, let download else { return }
			self._processingTasks.removeValue(forKey: download.id)
			guard self._isCurrent(download) else { return }

			#if !targetEnvironment(macCatalyst)
			if BackgroundTaskManager.shared.isCancellationRequested(for: download.id) {
				download.waitingForForeground = true
				download.interruptionForegroundGeneration = self._foregroundGeneration
			}
			#endif
			if download.waitingForForeground {
				self._persistDownloads()
				self._resumeInterruptedProcessing()
				return
			}
			if let error {
				if !(error is CancellationError) {
					HapticManager.shared.impact()
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
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				var restoredIDs = Set(self.downloads.filter { $0.task != nil }.map(\.id))
				defer { self._restorableTransferIDs.removeAll(); self._restoringTransferIDs.removeAll() }
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

					// Do not overwrite a task adopted by a callback or a newer retry.
					if let attached = download.task, attached !== task { task.cancel(); continue }
					guard self._restoringTransferIDs.contains(download.id) else { continue }
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
					case .downloading where self._restorableTransferIDs.contains(download.id) && !restoredIDs.contains(download.id):
						self._restoreMissingTransfer(download)
					case .pausing where self._restorableTransferIDs.contains(download.id) && !restoredIDs.contains(download.id):
						if download.resumeData != nil {
							download.state = .paused
						} else {
							self._markRestartRequired(
								download,
								message: .localized("The app closed before pausing completed. Restart the download.")
							)
						}
					case .resuming where self._restorableTransferIDs.contains(download.id) && !restoredIDs.contains(download.id):
						if download.resumeData != nil {
							download.state = .paused
						} else {
							self._markRestartRequired(
								download,
								message: .localized("The resumed system download could not be restored. Restart the download.")
							)
						}
					case .processing:
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
		_finishDownload(download)
	}

	private func _finishDownload(_ download: Download) {
		guard _isCurrent(download) else { return }
		download.progress = 1
		download.unpackageProgress = 1
		#if !targetEnvironment(macCatalyst)
		BackgroundTaskManager.shared.updateProgress(for: download.id, progress: 1)
		#endif
		_stopContinuedTask(for: download, success: true)
		_store.cleanupArtifacts(for: download)
		if let sourceCleanup = _archiveSourceCleanup.removeValue(forKey: download.id) {
			Task.detached(priority: .utility) { sourceCleanup() }
		}

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
		_persistDownloads(immediately: true)
		let name = download.sourceProvenance?.sourceAppName ?? download.fileName
		_notifyDownload(download, title: .localized("Download failed"),
			body: "\(name): \(error.localizedDescription)")
	}

	private func _failProcessing(_ download: Download, error: Error) {
		guard _isCurrent(download) else { return }
		download.isPreparingSource = false
		download.task = nil
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		download.state = .failed(error.localizedDescription, .retryProcessing)
		_stopContinuedTask(for: download, success: false)
		_persistDownloads(immediately: true)
		let name = download.sourceProvenance?.sourceAppName ?? download.fileName
		_notifyDownload(download, title: .localized("Import failed"),
			body: "\(name): \(error.localizedDescription)")
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
			_persistDownloads(immediately: true)
			let name = download.sourceProvenance?.sourceAppName ?? download.fileName
			_notifyDownload(download, title: .localized("Download failed"),
				body: "\(name): \(error.localizedDescription)")
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
		_persistDownloads(immediately: true)
		let name = download.sourceProvenance?.sourceAppName ?? download.fileName
		_notifyDownload(download, title: .localized("Download failed"), body: "\(name): \(message)")
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
		_persistenceRevision &+= 1
		let revision = _persistenceRevision
		let records = downloads
			.map(StoredDownload.init)
		let writer = _persistenceWriter
		#if !targetEnvironment(macCatalyst)
		let checkpoint = immediately ? DownloadCheckpointLease() : nil
		#endif
		Task {
			#if !targetEnvironment(macCatalyst)
			defer { checkpoint?.end() }
			#endif
			await writer.schedule(records: records, immediately: immediately, revision: revision)
		}
	}

	private func _persistBeforeResuming(_ download: Download) async -> Bool {
		let task = download.task
		_persistenceRevision &+= 1
		let revision = _persistenceRevision
		let records = downloads
			.map(StoredDownload.init)
		do {
			try await _persistenceWriter.commit(records: records, revision: revision)
			return true
		} catch {
			guard _isCurrent(download), download.task === task else { return false }
			download.task?.cancel()
			download.task = nil
			download.state = .failed(
				"Aether couldn’t save this download before starting it: \(error.localizedDescription)",
				.restart
			)
			_stopContinuedTask(for: download, success: false)
			DebugLogManager.shared.log(
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
		if UIApplication.shared.applicationState != .active,
			!BackgroundTaskManager.shared.hasNativeTask(for: download.id) {
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = _foregroundGeneration
			_persistDownloads()
			DebugLogManager.shared.log("Processing deferred: no active native grant; id=\(download.id) stage=\(subtitle).", category: "Background", level: .notice)
			return false
		}
		#endif
		let accepted = _ensureOperationExecution(download, subtitle: subtitle)
		if !accepted, UIApplication.shared.applicationState != .active {
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = _foregroundGeneration
			_persistDownloads()
			return false
		}
		return true
	}

	/// Execution grants cover local processing only. URLSession owns network transfers.
	@discardableResult
	private func _ensureOperationExecution(_ download: Download, subtitle: String) -> Bool {
		#if !targetEnvironment(macCatalyst)
		return BackgroundTaskManager.shared.startWork(for: download.id,
			title: download.sourceProvenance?.sourceAppName ?? download.fileName,
			subtitle: subtitle, progress: download.backgroundProgress) { [weak self, weak download] in
			guard let self, let download, self._isCurrent(download) else { return }
			guard case .processing = download.state else { return }
			download.waitingForForeground = true
			download.interruptionForegroundGeneration = self._foregroundGeneration
			self._processingTasks[download.id]?.cancel()
			self._persistDownloads()
			self._releaseIdleBackgroundTunnel()
			DebugLogManager.shared.log("Processing interrupted; retaining the IPA for foreground recovery.", category: "Background", level: .notice)
		}
		#else
		return true
		#endif
	}

	private func _resumeInterruptedProcessing() {
		guard UIApplication.shared.applicationState == .active else { return }
		for download in downloads where download.waitingForForeground && _foregroundGeneration > download.interruptionForegroundGeneration {
			guard _processingTasks[download.id] == nil else { continue }
			download.waitingForForeground = false
			retryProcessing(download)
		}
	}

	private func _startDownloadExecution(for download: Download) {
		#if !targetEnvironment(macCatalyst)
		DownloadResultNotifier.shared.requestPermissionIfNeeded()
		#endif
	}

	private func _notifyDownloadCompleted(_ download: Download) {
		let name = download.sourceProvenance?.sourceAppName ?? download.fileName
		_notifyDownload(download, title: .localized("Download complete"),
			body: .localized("%@ has downloaded. Open Aether to view or finish importing it.", arguments: name))
	}

	private func _notifyDownload(_ download: Download, title: String, body: String) {
        DownloadResultNotifier.shared.send(transferIdentifier: download.id, title: title, body: body)
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
			download.state = .processing
			_persistDownloads(immediately: true)
			_notifyDownloadCompleted(download)
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
		}

		#if !targetEnvironment(macCatalyst)
		if now - download.lastBackgroundDiagnosticUpdate >= 10 || totalBytesWritten == totalBytesExpectedToWrite {
			download.lastBackgroundDiagnosticUpdate = now
			DebugLogManager.shared.log("Download progress id=\(download.id) bytes=\(totalBytesWritten)/\(totalBytesExpectedToWrite) state=\(UIApplication.shared.applicationState.rawValue) native=\(BackgroundTaskManager.shared.hasNativeTask(for: download.id)) execution=\(BackgroundTaskManager.shared.hasExecution(for: download.id)).", category: "Download", level: .info)
		}
		#endif

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
