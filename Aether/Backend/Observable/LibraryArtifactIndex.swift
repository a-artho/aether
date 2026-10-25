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

	static func signedResultRowID(for requestID: UUID) -> String {
		"signed-operation:" + requestID.uuidString
	}

	mutating func recordSigned(uuid: String, sourceUUID: String?, sourceIsSigned: Bool, rowID: String? = nil) {
		guard let sourceUUID else {
			signedOrigins[uuid] = Origin(rowID: rowID ?? "app:" + uuid)
			return
		}
		if sourceIsSigned {
			let previous = signedOrigins[sourceUUID] ?? Origin(rowID: "app:" + sourceUUID)
			// The new variant inherits the signing row; the previous variant survives separately.
			signedOrigins[sourceUUID] = Origin(originalUUID: previous.originalUUID, rowID: "variant:" + UUID().uuidString)
			signedOrigins[uuid] = Origin(originalUUID: previous.originalUUID, rowID: rowID ?? previous.rowID)
		} else {
			let existing = signedOrigins.filter { $0.value.originalUUID == sourceUUID }
			for (key, origin) in existing where origin.rowID == "app:" + sourceUUID {
				signedOrigins[key] = Origin(originalUUID: sourceUUID, rowID: "variant:" + UUID().uuidString)
			}
			signedOrigins[uuid] = Origin(originalUUID: sourceUUID,
				rowID: rowID ?? (revealedOriginals.contains(sourceUUID) ? "app:" + uuid : "app:" + sourceUUID))
		}
	}

	func rowID(forSigned uuid: String) -> String {
		signedOrigins[uuid]?.rowID ?? "app:" + uuid
	}

	mutating func reveal(originalUUID: String) {
		revealedOriginals.insert(originalUUID)
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
			originalDates.removeValue(forKey: uuid)
			// Keep the split relationship after either copy is deleted. The
			// remaining artifact stays in its grouped detail page and remains an
			// independent file; it is never deleted as a side effect.
			if !signedOrigins.values.contains(where: { $0.originalUUID == uuid }) {
				revealedOriginals.remove(uuid)
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


	/// Install the UI identity before Core Data announces the new signed artifact.
	/// A failed database commit restores the previous mapping, including variants.
	func publishSigned(uuid: String, sourceUUID: String?, sourceIsSigned: Bool, rowID: String? = nil,
		commit: () throws -> Void) throws {
		let previous = lineage
		lineage.recordSigned(uuid: uuid, sourceUUID: sourceUUID, sourceIsSigned: sourceIsSigned, rowID: rowID)
		do {
			try commit()
			save()
		} catch {
			lineage = previous
			throw error
		}
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
		lineage.revealedOriginals.removeAll()
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
