//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

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

	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?

	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = url.lastPathComponent
		self.state = onlyArchiving ? .processing : .downloading
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

	@Published var downloads: [Download] = []

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	private var _session: URLSession!

	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if downloads.contains(where: \.isActive) {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif

	override init() {
		super.init()
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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

		let task = _session.downloadTask(with: url)
		download.task = task
		task.resume()

		downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif

		return download
	}

	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		return download
	}

	func resumeDownload(_ download: Download) {
		download.state = .downloading
		download.progress = 0
		download.bytesDownloaded = 0
		download.totalBytes = 0
		download.unpackageProgress = 0

		if let resumeData = download.resumeData {
			let task = _session.downloadTask(withResumeData: resumeData)
			download.task = task
			download.resumeData = nil
			task.resume()

		} else {
			let task = _session.downloadTask(with: download.url)
			download.task = task
			task.resume()

		}

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
	}

	func pauseDownload(_ download: Download) {
		guard case .downloading = download.state else { return }
		download.state = .paused
		download.task?.cancel(byProducingResumeData: { resumeData in
			DispatchQueue.main.async {
				download.resumeData = resumeData
				download.task = nil
				#if !targetEnvironment(macCatalyst)
				self._updateBackgroundAudioState()
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
				}
				#endif
			}
		})
	}

	func retryDownload(_ download: Download) {
		guard case .failed = download.state else { return }
		resumeDownload(download)
	}

	func cancelDownload(_ download: Download) {
		download.task?.cancel()

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)

			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}

	func dismissDownload(_ download: Download) {
		guard case .failed = download.state else { return }
		cancelDownload(download)
	}

	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}

	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
}

extension DownloadManager: URLSessionDownloadDelegate {

	func handlePachageFile(url: URL, dl: Download) throws {
		FR.handlePackageFile(url, download: dl) { err in
			if let err {
				DispatchQueue.main.async {
					let generator = UINotificationFeedbackGenerator()
					generator.notificationOccurred(.error)
					dl.state = .failed(err.localizedDescription)

					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.stopTask(for: dl.id, success: false)
					}
					self._updateBackgroundAudioState()
					#endif
				}
				return
			}

			DispatchQueue.main.async {
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)

					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.updateProgress(for: dl.id, progress: 1.0)
					}

					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		DispatchQueue.main.async {
			download.state = .processing
		}

		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)

		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)

			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)

			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)

			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			DispatchQueue.main.async {
				download.state = .failed(error.localizedDescription)
				#if !targetEnvironment(macCatalyst)
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
				}
				self._updateBackgroundAudioState()
				#endif
			}
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		DispatchQueue.main.async {
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite

			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}

		DispatchQueue.main.async {
			guard download.state != .paused else { return }
			let nsError = error as NSError
			download.resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
			download.task = nil
			download.state = .failed(error.localizedDescription)
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			self._updateBackgroundAudioState()
			#endif
		}
	}
}
