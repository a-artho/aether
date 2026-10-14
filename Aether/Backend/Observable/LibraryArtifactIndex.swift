import Foundation
import Combine

/// File identity, not catalog identity: unrelated IPAs must never collapse together.
struct LibraryArtifactLineage: Codable, Equatable, Sendable {
	struct Origin: Codable, Equatable, Sendable {
		var originalUUID: String?
		var rowID: String
	}
	var signedOrigins: [String: Origin] = [:]
	var revealedOriginals: Set<String> = []
	var originalDates: [String: Date] = [:]

	mutating func recordSigned(uuid: String, sourceUUID: String?, sourceIsSigned: Bool) {
		guard let sourceUUID else {
			signedOrigins[uuid] = Origin(rowID: "app:" + uuid)
			return
		}
		if sourceIsSigned {
			let previous = signedOrigins[sourceUUID] ?? Origin(rowID: "app:" + sourceUUID)
			// The new variant inherits the signing row; the previous variant survives separately.
			signedOrigins[sourceUUID] = Origin(originalUUID: previous.originalUUID, rowID: "variant:" + UUID().uuidString)
			signedOrigins[uuid] = previous
		} else {
			let existing = signedOrigins.filter { $0.value.originalUUID == sourceUUID }
			for (key, origin) in existing where origin.rowID == "app:" + sourceUUID {
				signedOrigins[key] = Origin(originalUUID: sourceUUID, rowID: "variant:" + UUID().uuidString)
			}
			signedOrigins[uuid] = Origin(originalUUID: sourceUUID,
				rowID: revealedOriginals.contains(sourceUUID) ? "app:" + uuid : "app:" + sourceUUID)
		}
	}

	func rowID(forSigned uuid: String) -> String {
		signedOrigins[uuid]?.rowID ?? "app:" + uuid
	}

	mutating func reveal(originalUUID: String) {
		guard revealedOriginals.insert(originalUUID).inserted else { return }
		for (uuid, origin) in signedOrigins where origin.originalUUID == originalUUID {
			signedOrigins[uuid] = Origin(originalUUID: originalUUID, rowID: "app:" + uuid)
		}
	}

	func originalUUIDsToDelete(deletingSigned: Set<String>, existingSigned: Set<String>) -> Set<String> {
		var groups: [String: Set<String>] = [:]
		for uuid in existingSigned {
			if let original = signedOrigins[uuid]?.originalUUID { groups[original, default: []].insert(uuid) }
		}
		return Set(groups.compactMap { original, variants in
			!revealedOriginals.contains(original) && variants.isSubset(of: deletingSigned) ? original : nil
		})
	}

	mutating func remove(uuid: String, isSigned: Bool) {
		if isSigned { signedOrigins.removeValue(forKey: uuid) }
		else {
			revealedOriginals.remove(uuid)
			originalDates.removeValue(forKey: uuid)
			for (key, origin) in signedOrigins where origin.originalUUID == uuid {
				var updated = origin
				updated.originalUUID = nil
				signedOrigins[key] = updated
			}
		}
	}
}

@MainActor
final class LibraryArtifactIndex: ObservableObject {
	static let shared = LibraryArtifactIndex()
	private static let fileURL = URL.applicationSupportDirectory.appendingPathComponent("LibraryArtifactIndex.json")
	@Published private(set) var lineage: LibraryArtifactLineage

	private init() {
		lineage = (try? Data(contentsOf: Self.fileURL))
			.flatMap { try? JSONDecoder().decode(LibraryArtifactLineage.self, from: $0) } ?? LibraryArtifactLineage()
	}

	func recordSigned(uuid: String, sourceUUID: String?, sourceIsSigned: Bool) {
		lineage.recordSigned(uuid: uuid, sourceUUID: sourceUUID, sourceIsSigned: sourceIsSigned)
		save()
	}

	func recordImport(uuid: String) {
		guard lineage.originalDates[uuid] == nil else { return }
		lineage.originalDates[uuid] = Date()
		save()
	}

	func reveal(originalUUID: String) {
		lineage.reveal(originalUUID: originalUUID)
		save()
	}

	func remove(uuid: String, isSigned: Bool) {
		lineage.remove(uuid: uuid, isSigned: isSigned)
		save()
	}

	func resetSigned() {
		lineage.signedOrigins.removeAll()
		save()
	}

	func resetImported() {
		lineage.revealedOriginals.removeAll()
		lineage.originalDates.removeAll()
		for (key, origin) in lineage.signedOrigins {
			var updated = origin
			updated.originalUUID = nil
			lineage.signedOrigins[key] = updated
		}
		save()
	}

	private func save() {
		do {
			try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try JSONEncoder().encode(lineage).write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			DebugLogManager.shared.log("Could not save library artifact links: \(error.localizedDescription)", category: "Library", level: .error)
		}
	}
}
