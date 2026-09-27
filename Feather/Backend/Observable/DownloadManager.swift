//
//  DownloadManager.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Combine
import Foundation
import UIKit

class Download: ObservableObject, Identifiable, @unchecked Sendable {
	enum State: Equatable {
		case downloading
		case paused
		case processing
		case failed(String)
	}

	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	@Published var state: State

	var overallProgress: Double {
		onlyArchiving
			? unpackageProgress
			: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var task: URLSessionDownloadTask?
	var resumeData: Data?
	var stagedFileName: String?

	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?

	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil,
		state: State? = nil,
		fileName: String? = nil,
		stagedFileName: String? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = fileName ?? (url.lastPathComponent.isEmpty ? "Download.ipa" : url.lastPathComponent)
		self.stagedFileName = stagedFileName
		self.state = state ?? (onlyArchiving ? .processing : .downloading)
	}

	var isActive: Bool {
		switch state {
		case .downloading, .processing:
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
		downloads.filter { isManualDownload($0.id) }
	}

	private let _store = DownloadStore()
	private var _session: URLSession!
	private var _backgroundEventsCompletionHandler: (() -> Void)?
	private var _finishedEventsBeforeHandler = false
	private var _processingBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

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
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil
	) -> Download {
		let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
			$0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance
		}) {
			switch existingDownload.state {
			case .paused, .failed:
				resumeDownload(existingDownload)
			case .downloading, .processing:
				break
			}
			return existingDownload
		}

		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance)
		_store.cleanupArtifacts(for: download)
		downloads.append(download)
		_persistDownloads()

		let task = _makeTask(for: download)
		download.task = task
		_startContinuedTask(for: download)
		task.resume()

		return download
	}

	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		_startContinuedTask(for: download)
		_beginProcessingBackgroundTime(for: download)
		return download
	}

	func resumeDownload(_ download: Download) {
		download.state = .downloading
		download.progress = 0
		download.bytesDownloaded = 0
		download.totalBytes = 0
		download.unpackageProgress = 0
		download.stagedFileName = nil

		let task: URLSessionDownloadTask
		if let resumeData = download.resumeData {
			task = _session.downloadTask(withResumeData: resumeData)
		} else {
			task = _session.downloadTask(with: download.url)
		}

		task.taskDescription = download.id
		download.task = task
		download.resumeData = nil
		_store.removeResumeData(for: download.id)
		_persistDownloads()
		_startContinuedTask(for: download)
		task.resume()
	}

	func pauseDownload(_ download: Download) {
		guard case .downloading = download.state else { return }
		download.state = .paused
		_persistDownloads()

		download.task?.cancel(byProducingResumeData: { [weak self] resumeData in
			DispatchQueue.main.async {
				guard let self else { return }
				download.resumeData = resumeData
				download.task = nil
				self._store.saveResumeData(resumeData, for: download.id)
				self._persistDownloads()
			}
		})
		_stopContinuedTask(for: download, success: false)
	}

	func retryDownload(_ download: Download) {
		guard case .failed = download.state else { return }

		if download.onlyArchiving {
			download.state = .processing
			download.unpackageProgress = 0
			_startContinuedTask(for: download)
			_beginProcessingBackgroundTime(for: download)
			try? handlePachageFile(url: download.url, dl: download)
		} else {
			resumeDownload(download)
		}
	}

	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		download.task = nil
		_stopContinuedTask(for: download, success: false)
		_endProcessingBackgroundTime(for: download.id)
		_store.cleanupArtifacts(for: download)

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}
		_persistDownloads()
	}

	func dismissDownload(_ download: Download) {
		guard case .failed = download.state else { return }
		cancelDownload(download)
	}

	func isManualDownload(_ string: String) -> Bool {
		string.contains("FeatherManualDownload")
	}

	func getDownload(by id: String) -> Download? {
		downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		if let id = task.taskDescription, let download = getDownload(by: id) {
			return download
		}
		return downloads.first(where: { $0.task == task })
	}

	func handlePachageFile(url: URL, dl: Download) throws {
		dl.state = .processing
		_persistDownloads()
		_beginProcessingBackgroundTime(for: dl)

		FR.handlePackageFile(url, download: dl) { [weak self] error in
			guard let self else { return }
			if let error {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
				self._fail(download: dl, error: error)
			} else {
				self._complete(download: dl)
			}
		}
	}

	private func _makeTask(for download: Download) -> URLSessionDownloadTask {
		let task = _session.downloadTask(with: download.url)
		task.taskDescription = download.id
		return task
	}

	private func _restoreSessionTasks() {
		_session.getAllTasks { [weak self] tasks in
			DispatchQueue.main.async {
				guard let self else { return }
				var restoredIDs = Set<String>()

				for task in tasks {
					guard let task = task as? URLSessionDownloadTask else {
						task.cancel()
						continue
					}

					let download = task.taskDescription.flatMap(self.getDownload(by:))
						?? self.downloads.first(where: {
							$0.url == task.originalRequest?.url && $0.state == .downloading
						})

					guard let download, download.state == .downloading else {
						task.cancel()
						continue
					}

					task.taskDescription = download.id
					download.task = task
					download.bytesDownloaded = task.countOfBytesReceived
					download.totalBytes = task.countOfBytesExpectedToReceive
					if task.countOfBytesExpectedToReceive > 0 {
						download.progress = Double(task.countOfBytesReceived)
							/ Double(task.countOfBytesExpectedToReceive)
					}
					restoredIDs.insert(download.id)
					if task.state == .suspended {
						task.resume()
					}
				}

				var downloadsToProcess: [(Download, URL)] = []
				for download in self.downloads {
					switch download.state {
					case .downloading where !restoredIDs.contains(download.id):
						self._fail(
							download: download,
							error: DownloadRecoveryError.missingSystemTask
						)
					case .processing:
						if
							let stagingURL = self._store.stagingURL(for: download),
							FileManager.default.fileExists(atPath: stagingURL.path)
						{
							downloadsToProcess.append((download, stagingURL))
						} else {
							self._fail(
								download: download,
								error: DownloadRecoveryError.missingStagedFile
							)
						}
					default:
						break
					}
				}

				self._persistDownloads()
				self._store.pruneArtifacts(keeping: self.downloads)
				for (download, stagingURL) in downloadsToProcess {
					try? self.handlePachageFile(url: stagingURL, dl: download)
				}
			}
		}
	}

	private func _complete(download: Download) {
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.updateProgress(for: download.id, progress: 1.0)
		}
		#endif
		_endProcessingBackgroundTime(for: download.id)
		_store.cleanupArtifacts(for: download)

		if let index = getDownloadIndex(by: download.id) {
			downloads.remove(at: index)
		}
		_persistDownloads()
	}

	private func _fail(download: Download, error: Error, resumeData: Data? = nil) {
		download.task = nil
		download.stagedFileName = nil
		download.resumeData = resumeData
		download.state = .failed(error.localizedDescription)
		_store.cleanupArtifacts(for: download)
		_store.saveResumeData(resumeData, for: download.id)
		_stopContinuedTask(for: download, success: false)
		_endProcessingBackgroundTime(for: download.id)
		_persistDownloads()
	}

	private func _persistDownloads() {
		_store.save(downloads)
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
		guard let download = getDownloadTask(by: downloadTask) else { return }

		do {
			let destinationURL = try _store.makeStagingURL(
				for: download,
				suggestedFilename: downloadTask.response?.suggestedFilename
			)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)

			download.task = nil
			download.resumeData = nil
			download.stagedFileName = destinationURL.lastPathComponent
			download.state = .processing
			_store.removeResumeData(for: download.id)
			_persistDownloads()
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			_fail(download: download, error: error)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
		download.bytesDownloaded = totalBytesWritten
		download.totalBytes = totalBytesExpectedToWrite

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.updateProgress(
				for: download.id,
				progress: download.overallProgress
			)
		}
		#endif
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}

		guard download.state != .paused else { return }
		let nsError = error as NSError
		let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
		_fail(download: download, error: error, resumeData: resumeData)
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		if let completionHandler = _backgroundEventsCompletionHandler {
			_backgroundEventsCompletionHandler = nil
			completionHandler()
		} else {
			_finishedEventsBeforeHandler = true
		}
	}
}

private enum DownloadRecoveryError: LocalizedError {
	case missingSystemTask
	case missingStagedFile

	var errorDescription: String? {
		switch self {
		case .missingSystemTask:
			return .localized("The system download could not be restored. Tap retry to start again.")
		case .missingStagedFile:
			return .localized("The downloaded file is no longer available. Tap retry to start again.")
		}
	}
}
