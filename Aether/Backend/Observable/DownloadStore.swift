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

	// Logical source identity is separate from the concrete transfer identity.
	let id: String
	let transferIdentifier: String
	let importIdentifier: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool?
	let sourceProvenance: SourceAppProvenance?
	let waitingForForeground: Bool
	let status: Status
	let failureMessage: String?
	let failureAction: Download.FailureAction?
	let stagedFileName: String?
	let bytesDownloaded: Int64
	let totalBytes: Int64
	let progress: Double

	@MainActor
	init(download: Download) {
		self.onlyArchiving = download.onlyArchiving
		self.id = download.logicalIdentifier
		self.transferIdentifier = download.id
		self.importIdentifier = download.importIdentifier
		self.url = download.url
		self.fileName = download.fileName
		self.sourceProvenance = download.sourceProvenance
		self.waitingForForeground = download.waitingForForeground
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
    private var recoveryCheckpointNeeded = false
    private var recoveryMarker: URL { rootURL.appendingPathComponent("recovery-required") }
    var hasUnrestoredArtifacts: Bool { recoveryCheckpointNeeded || fileManager.fileExists(atPath: recoveryMarker.path) }

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

	@MainActor
	func loadDownloads() -> [Download] {
        let records: [StoredDownload]
        do {
            records = try decoder.decode([StoredDownload].self, from: Data(contentsOf: recordsURL))
        } catch {
            let failure = error as NSError
            let hasArtifacts = [resumeDirectoryURL, stagingDirectoryURL].contains {
                !((try? fileManager.contentsOfDirectory(atPath: $0.path)) ?? []).isEmpty
            }
            // A new installation is empty; an unreadable queue is not proof that
            // existing transfers and staged IPAs can be discarded.
            if failure.domain != NSCocoaErrorDomain || failure.code != NSFileReadNoSuchFileError || hasArtifacts {
                preserveUnrestoredArtifacts(error: error)
            }
            return []
        }

		let stagedFiles = (try? fileManager.contentsOfDirectory(at: stagingDirectoryURL,
			includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
		return records.map { record in
			let transferIdentifier = record.transferIdentifier
			let resumeData = loadResumeData(for: transferIdentifier)
			let download = Download(
				transferIdentifier: transferIdentifier,
				logicalIdentifier: record.id,
				url: record.url,
				onlyArchiving: record.onlyArchiving ?? false,
				sourceIsStable: true,
				sourceProvenance: record.sourceProvenance,
				state: record.state(hasResumeData: resumeData != nil),
				fileName: record.fileName,
				stagedFileName: record.stagedFileName,
				importIdentifier: record.importIdentifier
			)
			download.waitingForForeground = record.waitingForForeground
			download.resumeData = resumeData
			download.bytesDownloaded = record.bytesDownloaded
			download.totalBytes = record.totalBytes
			download.progress = record.progress
			// The validated URLSession file may have moved before its queue checkpoint committed.
			// Recover only the exact transfer's regular file before startup pruning runs.
			if record.stagedFileName == nil, record.status == .downloading || record.status == .resuming || record.status == .processing,
				let staged = stagedFiles.first(where: { url in
					guard url.deletingPathExtension().lastPathComponent == storageKey(for: transferIdentifier),
						let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
					return values.isRegularFile == true && values.isSymbolicLink != true
				}) {
				download.stagedFileName = staged.lastPathComponent
				download.state = .processing
				download.resumeData = nil
				download.progress = 1
			}
			return download
		}
	}

	func save(records: [StoredDownload]) throws {
        try checkpointUnrestoredArtifacts()
		guard !records.isEmpty else {
            // Artifact ownership is handled per transfer. Do not erase quarantined
            // files just because the readable portion of the queue is now empty.
            if fileManager.fileExists(atPath: recordsURL.path) { try fileManager.removeItem(at: recordsURL) }
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

	@MainActor
	func makeStagingURL(for download: Download, suggestedFilename: String?) throws -> URL {
		try prepareDirectories()
		let suggestedExtension = URL(fileURLWithPath: suggestedFilename ?? "").pathExtension
		let sourceExtension = download.url.pathExtension
		let pathExtension = [suggestedExtension, sourceExtension]
			.first(where: { !$0.isEmpty })?.lowercased() ?? "ipa"
		let fileName = "\(storageKey(for: download.id)).\(pathExtension)"
		return stagingDirectoryURL.appendingPathComponent(fileName)
	}

	@MainActor
	func stagingURL(for download: Download) -> URL? {
		guard let stagedFileName = download.stagedFileName else { return nil }
		return stagingDirectoryURL.appendingPathComponent(stagedFileName)
	}

	@MainActor
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

	@MainActor
	func cleanupArtifacts(for download: Download) {
		removeResumeData(for: download.id)
		removeStagingFile(for: download)
	}

	@MainActor
	func pruneArtifacts(keeping downloads: [Download]) {
        guard !hasUnrestoredArtifacts else { return }
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

    /// Explicit Work Cache reset only. Keep every readable queue entry's artifacts.
    func clearRecoveryArtifacts(keeping records: [StoredDownload]) throws {
        let retainedResume = Set(records.map { resumeDataURL(for: $0.transferIdentifier).lastPathComponent })
        let retainedStaging = Set(records.compactMap(\.stagedFileName))
        for (directory, retained) in [(resumeDirectoryURL, retainedResume), (stagingDirectoryURL, retainedStaging)] {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            for file in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where !retained.contains(file.lastPathComponent) {
                try fileManager.removeItem(at: file)
            }
        }
        if fileManager.fileExists(atPath: rootURL.path) {
            for file in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("queue-unreadable-") && file.pathExtension == "json" {
                try fileManager.removeItem(at: file)
            }
        }
        // Remove protection last, so a partial cleanup remains recoverable.
        if fileManager.fileExists(atPath: recoveryMarker.path) { try fileManager.removeItem(at: recoveryMarker) }
        recoveryCheckpointNeeded = false
    }

    private func preserveUnrestoredArtifacts(error: Error) {
        recoveryCheckpointNeeded = true
        do { try checkpointUnrestoredArtifacts() }
        catch {
            DiagnosticLog.error("Could not checkpoint download recovery protection: \(error.localizedDescription)", category: "Download")
        }
        DiagnosticLog.error("Download queue could not be restored; preserving staged files and resume data: \(error.localizedDescription)", category: "Download")
    }

    private func checkpointUnrestoredArtifacts() throws {
        guard recoveryCheckpointNeeded else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: recordsURL.path) {
            let backup = rootURL.appendingPathComponent("queue-unreadable-\(UUID().uuidString).json")
            try fileManager.copyItem(at: recordsURL, to: backup)
        }
        try Data("Preserve unknown download artifacts until explicit cleanup.".utf8).write(to: recoveryMarker, options: .atomic)
        recoveryCheckpointNeeded = false
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
