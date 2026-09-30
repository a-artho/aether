//
//  DownloadPersistenceWriter.swift
//  Aether
//

import Foundation

/// Serializes queue snapshots away from URLSession's main delegate queue. A
/// progress burst retains only the newest snapshot; state transitions bypass
/// the delay while still preserving write order.
actor DownloadPersistenceWriter {
	private let store = DownloadStore()
	private var pendingSnapshot: (revision: UInt64, records: [StoredDownload])?
	private var latestAcceptedRevision: UInt64 = 0
	private var scheduledFlush: Task<Void, Never>?
	private var scheduledFlushID: UUID?

	func schedule(records: [StoredDownload], immediately: Bool, revision: UInt64) {
		guard revision >= latestAcceptedRevision else { return }
		latestAcceptedRevision = revision
		pendingSnapshot = (revision, records)
		if immediately {
			scheduledFlush?.cancel()
			scheduledFlush = nil
			scheduledFlushID = nil
			flushPendingRecords()
			return
		}

		guard scheduledFlush == nil else { return }
		let identifier = UUID()
		scheduledFlushID = identifier
		scheduledFlush = Task { [weak self] in
			do {
				try await Task.sleep(nanoseconds: 1_000_000_000)
			} catch {
				return
			}
			await self?.flush(identifier: identifier)
		}
	}

	private func flush(identifier: UUID) {
		guard scheduledFlushID == identifier else { return }
		scheduledFlush = nil
		scheduledFlushID = nil
		flushPendingRecords()
	}

	private func flushPendingRecords() {
		guard let snapshot = pendingSnapshot else { return }
		pendingSnapshot = nil
		guard snapshot.revision == latestAcceptedRevision else { return }
		do {
			try store.save(records: snapshot.records)
		} catch {
			print("Failed to persist downloads: \(error.localizedDescription)")
		}
	}
}
