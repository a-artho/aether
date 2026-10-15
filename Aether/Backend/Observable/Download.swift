import Combine
import Foundation

@MainActor
final class Download: ObservableObject, Identifiable {
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
		// Includes preparation, extraction, movement and commit; only completion reaches 1.
		return unpackageProgress
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
	var lastBackgroundDiagnosticUpdate: TimeInterval = 0
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
	@Published var isPreparingSource = false
	@Published var waitingForForeground = false
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
