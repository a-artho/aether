//
//  DownloadManager.swift
//  Feather
//

import Combine
import Foundation
import UIKit

class Download: ObservableObject, Identifiable, @unchecked Sendable {
	enum FailureAction: String, Codable, Equatable {
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
	var sourceProvenance: SourceAppProvenance?

	init(
		transferIdentifier: String = UUID().uuidString,
		logicalIdentifier: String,
		url: URL,
		onlyArchiving: Bool = false,
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

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	static var backgroundSessionIdentifier: String {
		"\(Bundle.main.bundleIdentifier ?? "Feather").downloads"
	}

	@Published var downloads: [Download] = []

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.logicalIdentifier) }
	}

	private let _store = DownloadStore()
	private var _session: URLSession!
	private var _backgroundEventsCompletionHandler: (() -> Void)?
	private var _finishedEventsBeforeHandler = false
	private var _processingBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
	private var _processingTasks: [String: Task<Void, Never>] = [:]
	private var _deletedTransferIdentifiers: Set<String> = []

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
	) -> Download {
		let identity = _downloadIdentity(url: url, provenance: sourceProvenance)
		if let existingDownload = downloads.first(where: {
			_downloadIdentity(url: $0.url, provenance: $0.sourceProvenance) == identity
		}) {
			return existingDownload
		}

		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			sourceProvenance: sourceProvenance
		)
		downloads.append(download)
		_persistDownloads()

		let task = _makeFreshTask(for: download)
		download.task = task
		_startContinuedTask(for: download)
		task.resume()

		return download
	}

	func startArchive(
		from url: URL,
		id logicalIdentifier: String = UUID().uuidString
	) -> Download {
		let download = Download(
			logicalIdentifier: logicalIdentifier,
			url: url,
			onlyArchiving: true
		)
		downloads.append(download)
		_startContinuedTask(for: download)
		_beginProcessingBackgroundTime(for: download)
		return download
	}

	func pauseDownload(_ download: Download) {
		guard _isCurrent(download), case .downloading = download.state else { return }
		download.state = .pausing
		_persistDownloads()
		_requestResumeDataForPause(download)
	}

	func resumeDownload(_ download: Download) {
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
		_persistDownloads()
		_startContinuedTask(for: download)
		task.resume()
	}

	func restartDownload(_ download: Download) {
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
		_persistDownloads()
		_startContinuedTask(for: download)
		task.resume()
	}

	func retryDownload(_ download: Download) {
		guard case .failed(_, let action) = download.state else { return }
		switch action {
		case .resume:
			download.state = .paused
			resumeDownload(download)
		case .restart:
			restartDownload(download)
		case .retryProcessing:
			retryProcessing(download)
		}
	}

	func retryProcessing(_ download: Download) {
		guard _isCurrent(download) else { return }

		if download.onlyArchiving {
			_startProcessing(download, sourceURL: download.url, sourceIsStable: false)
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
		_deletedTransferIdentifiers.insert(download.id)
		_processingTasks.removeValue(forKey: download.id)?.cancel()
		download.task?.cancel()
		download.task = nil
		_stopContinuedTask(for: download, success: false)
		_endProcessingBackgroundTime(for: download.id)

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}
		_persistDownloads()
		_store.cleanupArtifacts(for: download)

		let importIdentifier = download.importIdentifier
		Task.detached(priority: .utility) {
			await AppFileHandler.removeImportTransaction(
				transactionIdentifier: importIdentifier
			)
		}
	}

	func isManualDownload(_ string: String) -> Bool {
		string.contains("FeatherManualDownload")
	}

	/// Returns a transfer for the caller's logical source/app identifier.
	func getDownload(by logicalIdentifier: String) -> Download? {
		downloads.first(where: { $0.logicalIdentifier == logicalIdentifier })
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
		guard _isCurrent(download) else { return }
		download.state = .processing
		download.unpackageProgress = 0
		_persistDownloads()
		_beginProcessingBackgroundTime(for: download)

		let task = FR.handlePackageFile(
			sourceURL,
			download: download,
			transactionIdentifier: download.importIdentifier,
			copySource: !sourceIsStable
		) { [weak self, weak download] error in
			guard let self, let download else { return }
			self._processingTasks.removeValue(forKey: download.id)
			guard self._isCurrent(download) else { return }

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
		download.progress = 1
		download.unpackageProgress = 1
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.updateProgress(for: download.id, progress: 1)
		}
		#endif
		_stopContinuedTask(for: download, success: true)
		_endProcessingBackgroundTime(for: download.id)
		_store.cleanupArtifacts(for: download)

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}
		_persistDownloads()
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
		_endProcessingBackgroundTime(for: download.id)
		_persistDownloads()
	}

	private func _failProcessing(_ download: Download, error: Error) {
		guard _isCurrent(download) else { return }
		download.task = nil
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		download.state = .failed(error.localizedDescription, .retryProcessing)
		_stopContinuedTask(for: download, success: false)
		_endProcessingBackgroundTime(for: download.id)
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
			_endProcessingBackgroundTime(for: download.id)
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
		_endProcessingBackgroundTime(for: download.id)
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

	private func _persistDownloads() {
		do {
			try _store.save(downloads)
		} catch {
			print("Failed to persist downloads:", error)
		}
	}

	private func _isCurrent(_ download: Download) -> Bool {
		!_deletedTransferIdentifiers.contains(download.id)
			&& downloads.contains(where: { $0 === download })
	}

	private func _startContinuedTask(for download: Download) {
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(
				for: download.id,
				filename: download.sourceProvenance?.sourceAppName ?? download.fileName
			)
		}
		#endif
	}

	private func _stopContinuedTask(for download: Download, success: Bool) {
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(for: download.id, success: success)
		}
		#endif
	}

	private func _beginProcessingBackgroundTime(for download: Download) {
		#if !targetEnvironment(macCatalyst)
		guard #unavailable(iOS 26.0) else { return }
		guard _processingBackgroundTasks[download.id] == nil else { return }

		let identifier = UIApplication.shared.beginBackgroundTask(
			withName: "Process \(download.fileName)"
		) { [weak self] in
			DispatchQueue.main.async {
				self?._endProcessingBackgroundTime(for: download.id)
			}
		}
		if identifier != .invalid {
			_processingBackgroundTasks[download.id] = identifier
		}
		#endif
	}

	private func _endProcessingBackgroundTime(for downloadID: String) {
		#if !targetEnvironment(macCatalyst)
		guard let identifier = _processingBackgroundTasks.removeValue(forKey: downloadID) else {
			return
		}
		UIApplication.shared.endBackgroundTask(identifier)
		#endif
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
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
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(
					for: download.id,
					progress: download.overallProgress
				)
			}
			#endif
		}

		if shouldPersist {
			download.lastPersistedProgressUpdate = now
			download.lastPersistedBytes = totalBytesWritten
			_persistDownloads()
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
