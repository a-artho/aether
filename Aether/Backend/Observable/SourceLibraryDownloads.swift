import Combine
import CoreData
import Foundation
import UIKit

/// Catalog identity is independent of the name/bundle ID inside an IPA and of
/// the UUID assigned to each concrete import or signed copy.
struct SourceLibraryIdentity: Hashable, Sendable {
	let repositoryURL: URL
	let appIdentifier: String
	let version: String?
	let downloadURL: URL

	init?(repositoryURL: URL?, appIdentifier: String?, version: String?, downloadURL: URL?) {
		guard let repositoryURL, let appIdentifier, !appIdentifier.isEmpty,
			let downloadURL else { return nil }
		self.repositoryURL = repositoryURL
		self.appIdentifier = appIdentifier
		self.version = version
		self.downloadURL = downloadURL
	}

	init?(_ provenance: SourceAppProvenance?) {
		self.init(repositoryURL: provenance?.sourceRepositoryURL,
			appIdentifier: provenance?.sourceAppIdentifier,
			version: provenance?.sourceAppVersion,
			downloadURL: provenance?.sourceAppDownloadURL)
	}
}

/// One live index for every repo/update row and detail download control.
/// Core Data stays on its context; only immutable values reach file workers.
@MainActor
final class SourceLibraryDownloads: ObservableObject {
	static let shared = SourceLibraryDownloads()
	@Published private(set) var identities: Set<SourceLibraryIdentity> = []
	private struct Artifact: Hashable, Sendable {
		let uuid: String
		let kind: String
	}
	private struct Entry: Equatable, Sendable {
		let identity: SourceLibraryIdentity
		let directory: URL
	}
	private let storage: Storage
	private let validateDirectory: @Sendable (URL) -> Bool
	private var entries: [Artifact: Entry] = [:]
	private var checked: [Artifact: Entry] = [:]
	private var valid: [Artifact: Entry] = [:]
	private var observations = Set<AnyCancellable>()
	private var refreshTask: Task<Void, Never>?
	private var validationTask: Task<Void, Never>?
	private var fileWorker: Task<Set<Artifact>, Never>?
	private var generation: UInt64 = 0
	private var needsFileRecheck = false

	init(storage: Storage = .shared, validateDirectory: @escaping @Sendable (URL) -> Bool = { directory in
		let contents = try? FileManager.default.contentsOfDirectory(at: directory,
			includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		return contents?.contains { $0.pathExtension == "app" } == true
	}) {
		self.storage = storage
		self.validateDirectory = validateDirectory
		// First use of a repo button never synchronously enumerates the Library.
		scheduleRefresh(recheckFiles: true)
		NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: storage.context)
			.sink { [weak self] notification in
				MainActor.assumeIsolated {
					let entities: Set<String> = ["Imported", "Signed", "AppSourceMetadata"]
					let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey,
						NSRefreshedObjectsKey, NSInvalidatedObjectsKey].contains { key in
						(notification.userInfo?[key] as? Set<NSManagedObject>)?.contains {
							entities.contains($0.entity.name ?? "")
						} == true
					}
					let reset = notification.userInfo?[NSInvalidatedAllObjectsKey] != nil
					if changed || reset { self?.scheduleRefresh(recheckFiles: reset) }
				}
			}.store(in: &observations)
		NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
			.sink { [weak self] _ in
				MainActor.assumeIsolated { self?.scheduleRefresh(recheckFiles: true) }
			}.store(in: &observations)
	}

	func contains(_ provenance: SourceAppProvenance?) -> Bool {
		guard let identity = SourceLibraryIdentity(provenance) else { return false }
		return identities.contains(identity)
	}

	private func scheduleRefresh(recheckFiles: Bool) {
		needsFileRecheck = needsFileRecheck || recheckFiles
		guard refreshTask == nil else { return }
		refreshTask = Task { [weak self] in
			await Task.yield()
			guard !Task.isCancelled, let self else { return }
			self.refreshTask = nil
			self.refresh(recheckFiles: self.needsFileRecheck)
		}
	}

	/// Import/signing calls this only after files and source metadata are committed.
	/// Publish that known artifact immediately, without a filesystem scan, before
	/// retiring its progress control. Pending older file checks cannot overwrite it.
	func recordCommittedApp(_ app: AppInfoPresentable) {
		guard let uuid = app.uuid, let record = storage.sourceMetadata(for: uuid),
			let directory = storage.getUuidDirectory(for: app),
			let identity = SourceLibraryIdentity(repositoryURL: record.sourceRepositoryURL,
				appIdentifier: record.sourceAppIdentifier, version: record.sourceAppVersion,
				downloadURL: record.sourceAppDownloadURL) else { return }
		let artifact = Artifact(uuid: uuid, kind: app.isSigned ? "signed" : "imported")
		let entry = Entry(identity: identity, directory: directory)
		generation &+= 1
		validationTask?.cancel()
		validationTask = nil
		fileWorker?.cancel()
		fileWorker = nil
		entries[artifact] = entry
		checked[artifact] = entry
		valid[artifact] = entry
		publish()
		scheduleRefresh(recheckFiles: false)
	}

	/// Reconcile database membership, reusing file validation for unchanged
	/// artifacts. Foreground reconciliation additionally detects external removal.
	func refresh(recheckFiles: Bool = true) {
		refreshTask?.cancel()
		refreshTask = nil
		let recheck = recheckFiles || needsFileRecheck
		needsFileRecheck = false
		generation &+= 1
		let revision = generation
		validationTask?.cancel()
		validationTask = nil
		fileWorker?.cancel()
		fileWorker = nil
		do {
			let metadata = try storage.context.fetch(AppSourceMetadata.fetchRequest())
			let importedIDs = try artifactIDs(entity: "Imported")
			let signedIDs = try artifactIDs(entity: "Signed")
			var next: [Artifact: Entry] = [:]
			for record in metadata {
				guard let uuid = record.appUUID, let kind = record.appKind,
					let identity = SourceLibraryIdentity(repositoryURL: record.sourceRepositoryURL,
						appIdentifier: record.sourceAppIdentifier, version: record.sourceAppVersion,
						downloadURL: record.sourceAppDownloadURL) else { continue }
				let directory: URL
				switch kind {
				case "imported" where importedIDs.contains(uuid): directory = FileManager.default.unsigned(uuid)
				case "signed" where signedIDs.contains(uuid): directory = FileManager.default.signed(uuid)
				default: continue
				}
				next[Artifact(uuid: uuid, kind: kind)] = Entry(identity: identity, directory: directory)
			}
			entries = next
			valid = valid.filter { next[$0.key] == $0.value }
			checked = recheck ? [:] : checked.filter { next[$0.key] == $0.value }
			publish() // Deletion is reflected without waiting for file I/O.
			let pending = next.filter { checked[$0.key] != $0.value }
			guard !pending.isEmpty else { return }
			let validate = validateDirectory
			let worker = Task.detached(priority: .utility) { () -> Set<Artifact> in
				var present = Set<Artifact>()
				for (artifact, entry) in pending {
					guard !Task.isCancelled else { break }
					if validate(entry.directory) { present.insert(artifact) }
				}
				return present
			}
			fileWorker = worker
			validationTask = Task { [weak self] in
				let present = await worker.value
				guard !Task.isCancelled, let self, self.generation == revision else { return }
				for (artifact, entry) in pending where self.entries[artifact] == entry {
					self.checked[artifact] = entry
					self.valid[artifact] = present.contains(artifact) ? entry : nil
				}
				self.fileWorker = nil
				self.validationTask = nil
				self.publish()
			}
		} catch {
			checked = [:]
			valid = [:]
			publish()
			DebugLogManager.shared.log("Could not index source downloads in Library: \(error.localizedDescription)",
				category: "Library", level: .error)
		}
	}

	private func artifactIDs(entity: String) throws -> Set<String> {
		let request = NSFetchRequest<NSDictionary>(entityName: entity)
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["uuid"]
		return Set(try storage.context.fetch(request).compactMap { $0["uuid"] as? String })
	}

	private func publish() {
		let next = Set(valid.values.map(\.identity))
		if next != identities { identities = next }
	}
}
