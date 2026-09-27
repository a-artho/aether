//
//  DownloadStore.swift
//  Feather
//

import CryptoKit
import Foundation

struct StoredDownload: Codable {
	enum Status: String, Codable {
		case downloading
		case paused
		case processing
		case failed
	}

	let id: String
	let importIdentifier: String?
	let url: URL
	let fileName: String
	let sourceProvenance: SourceAppProvenance?
	let status: Status
	let failureMessage: String?
	let stagedFileName: String?

	init(download: Download) {
		self.id = download.id
		self.importIdentifier = download.importIdentifier
		self.url = download.url
		self.fileName = download.fileName
		self.sourceProvenance = download.sourceProvenance
		self.stagedFileName = download.stagedFileName

		switch download.state {
		case .downloading:
			self.status = .downloading
			self.failureMessage = nil
		case .paused:
			self.status = .paused
			self.failureMessage = nil
		case .processing:
			self.status = .processing
			self.failureMessage = nil
		case .failed(let message):
			self.status = .failed
			self.failureMessage = message
		}
	}

	var state: Download.State {
		switch status {
		case .downloading: return .downloading
		case .paused: return .paused
		case .processing: return .processing
		case .failed: return .failed(failureMessage ?? String.localized("Download Failed"))
		}
	}
}

final class DownloadStore {
	private let fileManager = FileManager.default
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	private var rootURL: URL {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("FeatherDownloads", isDirectory: true)
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
			let download = Download(
				id: record.id,
				url: record.url,
				sourceProvenance: record.sourceProvenance,
				state: record.state,
				fileName: record.fileName,
				stagedFileName: record.stagedFileName,
				importIdentifier: record.importIdentifier ?? storageKey(for: record.id)
			)
			download.resumeData = loadResumeData(for: record.id)
			return download
		}
	}

	func save(_ downloads: [Download]) {
		let records = downloads
			.filter { !$0.onlyArchiving }
			.map(StoredDownload.init)

		guard !records.isEmpty else {
			try? fileManager.removeItem(at: rootURL)
			return
		}

		do {
			try prepareDirectories()
			let data = try encoder.encode(records)
			try data.write(to: recordsURL, options: .atomic)
		} catch {
			print("Failed to persist downloads:", error)
		}
	}

	func saveResumeData(_ data: Data?, for id: String) {
		let url = resumeDataURL(for: id)
		guard let data else {
			try? fileManager.removeItem(at: url)
			return
		}

		do {
			try prepareDirectories()
			try data.write(to: url, options: .atomic)
		} catch {
			print("Failed to persist resume data:", error)
		}
	}

	func loadResumeData(for id: String) -> Data? {
		try? Data(contentsOf: resumeDataURL(for: id))
	}

	func removeResumeData(for id: String) {
		try? fileManager.removeItem(at: resumeDataURL(for: id))
	}

	func makeStagingURL(for download: Download, suggestedFilename: String?) throws -> URL {
		try prepareDirectories()
		let suggestedExtension = URL(fileURLWithPath: suggestedFilename ?? "").pathExtension
		let sourceExtension = download.url.pathExtension
		let pathExtension = [suggestedExtension, sourceExtension]
			.first(where: { !$0.isEmpty }) ?? "ipa"
		let fileName = "\(storageKey(for: download.id)).\(pathExtension)"
		return stagingDirectoryURL.appendingPathComponent(fileName)
	}

	func stagingURL(for download: Download) -> URL? {
		guard let stagedFileName = download.stagedFileName else { return nil }
		return stagingDirectoryURL.appendingPathComponent(stagedFileName)
	}

	func cleanupArtifacts(for download: Download) {
		removeResumeData(for: download.id)
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

	func pruneArtifacts(keeping downloads: [Download]) {
		let retainedResumeFiles = Set(
			downloads.compactMap { download in
				download.resumeData == nil ? nil : resumeDataURL(for: download.id).lastPathComponent
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

	private func resumeDataURL(for id: String) -> URL {
		resumeDirectoryURL.appendingPathComponent(storageKey(for: id) + ".resume")
	}

	private func storageKey(for id: String) -> String {
		SHA256.hash(data: Data(id.utf8))
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
