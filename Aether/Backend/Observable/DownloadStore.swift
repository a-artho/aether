//
//  DownloadStore.swift
//  Aether
//

import CryptoKit
import Foundation

struct StoredDownload: Codable, Sendable {
	enum Status: String, Codable, Sendable {
		case downloading
		case pausing
		case paused
		case resuming
		case processing
		case failed
	}

	// `id` remains the logical app/version ID for queue migration compatibility.
	let id: String
	let transferIdentifier: String?
	let importIdentifier: String?
	let url: URL
	let fileName: String
	let sourceProvenance: SourceAppProvenance?
	let status: Status
	let failureMessage: String?
	let failureAction: Download.FailureAction?
	let stagedFileName: String?
	let bytesDownloaded: Int64?
	let totalBytes: Int64?
	let progress: Double?

	init(download: Download) {
		self.id = download.logicalIdentifier
		self.transferIdentifier = download.id
		self.importIdentifier = download.importIdentifier
		self.url = download.url
		self.fileName = download.fileName
		self.sourceProvenance = download.sourceProvenance
		self.stagedFileName = download.stagedFileName
		self.bytesDownloaded = download.bytesDownloaded
		self.totalBytes = download.totalBytes
		self.progress = download.progress

		switch download.state {
		case .downloading:
			self.status = .downloading
			self.failureMessage = nil
			self.failureAction = nil
		case .pausing:
			self.status = .pausing
			self.failureMessage = nil
			self.failureAction = nil
		case .paused:
			self.status = .paused
			self.failureMessage = nil
			self.failureAction = nil
		case .resuming:
			self.status = .resuming
			self.failureMessage = nil
			self.failureAction = nil
		case .processing:
			self.status = .processing
			self.failureMessage = nil
			self.failureAction = nil
		case .failed(let message, let action):
			self.status = .failed
			self.failureMessage = message
			self.failureAction = action
		}
	}

	func state(hasResumeData: Bool) -> Download.State {
		switch status {
		case .downloading: return .downloading
		case .pausing: return .pausing
		case .paused: return .paused
		case .resuming: return .resuming
		case .processing: return .processing
		case .failed:
			let fallbackAction: Download.FailureAction
			if stagedFileName != nil {
				fallbackAction = .retryProcessing
			} else if hasResumeData {
				fallbackAction = .resume
			} else {
				fallbackAction = .restart
			}
			return .failed(
				failureMessage ?? String.localized("Download Failed"),
				failureAction ?? fallbackAction
			)
		}
	}
}

final class DownloadStore {
	private let fileManager = FileManager.default
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	private var rootURL: URL {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AetherDownloads", isDirectory: true)
	}

	private var recordsURL: URL {
		rootURL.appendingPathComponent("queue.json")
	}

	private var resumeDirectoryURL: URL {
		rootURL.appendingPathComponent("ResumeData", isDirectory: true)
	}

	private var stagingDirectoryURL: URL {
		rootURL.appendingPathComponent("Staging", isDirectory: true)
	}

	func loadDownloads() -> [Download] {
		guard
			let data = try? Data(contentsOf: recordsURL),
			let records = try? decoder.decode([StoredDownload].self, from: data)
		else {
			return []
		}

		return records.map { record in
			let transferIdentifier = record.transferIdentifier ?? storageKey(for: record.id)
			let legacyResumeData = record.transferIdentifier == nil
				? loadResumeData(for: record.id)
				: nil
			let resumeData = loadResumeData(for: transferIdentifier) ?? legacyResumeData
			if let legacyResumeData {
				do {
					try saveResumeData(legacyResumeData, for: transferIdentifier)
					removeResumeData(for: record.id)
				} catch {
					// Keep the legacy file until a later successful persistence attempt.
				}
			}
			let download = Download(
				transferIdentifier: transferIdentifier,
				logicalIdentifier: record.id,
				url: record.url,
				sourceProvenance: record.sourceProvenance,
				state: record.state(hasResumeData: resumeData != nil),
				fileName: record.fileName,
				stagedFileName: record.stagedFileName,
				importIdentifier: record.importIdentifier ?? storageKey(for: record.id)
			)
			download.resumeData = resumeData
			download.bytesDownloaded = record.bytesDownloaded ?? 0
			download.totalBytes = record.totalBytes ?? 0
			download.progress = record.progress ?? {
				guard download.totalBytes > 0 else { return 0 }
				return Double(download.bytesDownloaded) / Double(download.totalBytes)
			}()
			return download
		}
	}

	func save(records: [StoredDownload]) throws {
		guard !records.isEmpty else {
			try? fileManager.removeItem(at: rootURL)
			return
		}

		try prepareDirectories()
		let data = try encoder.encode(records)
		try data.write(to: recordsURL, options: .atomic)
	}

	func saveResumeData(_ data: Data, for transferIdentifier: String) throws {
		try prepareDirectories()
		try data.write(
			to: resumeDataURL(for: transferIdentifier),
			options: .atomic
		)
	}

	func loadResumeData(for transferIdentifier: String) -> Data? {
		try? Data(contentsOf: resumeDataURL(for: transferIdentifier))
	}

	func removeResumeData(for transferIdentifier: String) {
		try? fileManager.removeItem(at: resumeDataURL(for: transferIdentifier))
	}

	func makeStagingURL(for download: Download, suggestedFilename: String?) throws -> URL {
		try prepareDirectories()
		let suggestedExtension = URL(fileURLWithPath: suggestedFilename ?? "").pathExtension
		let sourceExtension = download.url.pathExtension
		let pathExtension = [suggestedExtension, sourceExtension]
			.first(where: { !$0.isEmpty })?.lowercased() ?? "ipa"
		let fileName = "\(storageKey(for: download.id)).\(pathExtension)"
		return stagingDirectoryURL.appendingPathComponent(fileName)
	}

	func stagingURL(for download: Download) -> URL? {
		guard let stagedFileName = download.stagedFileName else { return nil }
		return stagingDirectoryURL.appendingPathComponent(stagedFileName)
	}

	func removeStagingFile(for download: Download) {
		if let stagingURL = stagingURL(for: download) {
			try? fileManager.removeItem(at: stagingURL)
		}

		guard let files = try? fileManager.contentsOfDirectory(
			at: stagingDirectoryURL,
			includingPropertiesForKeys: nil
		) else { return }

		let prefix = storageKey(for: download.id) + "."
		for file in files where file.lastPathComponent.hasPrefix(prefix) {
			try? fileManager.removeItem(at: file)
		}
	}

	func cleanupArtifacts(for download: Download) {
		removeResumeData(for: download.id)
		removeStagingFile(for: download)
	}

	func pruneArtifacts(keeping downloads: [Download]) {
		let retainedResumeFiles = Set(
			downloads.compactMap { download in
				download.resumeData == nil
					? nil
					: resumeDataURL(for: download.id).lastPathComponent
			}
		)
		let retainedStagingFiles = Set(downloads.compactMap(\.stagedFileName))

		prune(directory: resumeDirectoryURL, retaining: retainedResumeFiles)
		prune(directory: stagingDirectoryURL, retaining: retainedStagingFiles)
	}

	private func prepareDirectories() throws {
		try fileManager.createDirectory(at: resumeDirectoryURL, withIntermediateDirectories: true)
		try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)

		var resourceValues = URLResourceValues()
		resourceValues.isExcludedFromBackup = true
		var mutableRootURL = rootURL
		try? mutableRootURL.setResourceValues(resourceValues)
	}

	private func resumeDataURL(for transferIdentifier: String) -> URL {
		resumeDirectoryURL.appendingPathComponent(storageKey(for: transferIdentifier) + ".resume")
	}

	private func storageKey(for identifier: String) -> String {
		SHA256.hash(data: Data(identifier.utf8))
			.map { String(format: "%02x", $0) }
			.joined()
	}

	private func prune(directory: URL, retaining retainedNames: Set<String>) {
		guard let files = try? fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		) else { return }

		for file in files where !retainedNames.contains(file.lastPathComponent) {
			try? fileManager.removeItem(at: file)
		}
	}
}
