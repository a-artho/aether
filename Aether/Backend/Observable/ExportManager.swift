//
//  ExportManager.swift
//  Aether
//

import Combine
import IDeviceSwift
import SwiftUI
import UIKit

final class AppExport: ObservableObject, Identifiable {
	enum State: Equatable {
		case exporting
		case failed(String)
	}

	let id = UUID()
	let app: AppInfoPresentable
	let snapshot: AppSnapshot
	@Published var progress: Double = 0
	@Published var state: State = .exporting

	init(app: AppInfoPresentable) {
		self.app = app
		self.snapshot = AppSnapshot(app)
	}
}

@MainActor
final class ExportManager: ObservableObject {
	static let shared = ExportManager()

	@Published private(set) var exports: [AppExport] = []

	private var tasks: [UUID: Task<Void, Never>] = [:]
	private var handlers: [UUID: ArchiveHandler] = [:]
	private var progressObservations: [UUID: AnyCancellable] = [:]
	private var runIDs: [UUID: UUID] = [:]
	@Published private var artifactReaders: [UUID: AppSnapshot] = [:]

	var hasActiveWork: Bool { !artifactReaders.isEmpty }

	private init() {}

	func usesLibraryArtifact(_ app: AppInfoPresentable) -> Bool {
		guard let uuid = app.uuid else { return false }
		return artifactReaders.values.contains { $0.uuid == uuid && $0.isSigned == app.isSigned }
	}

	func startExport(app: AppInfoPresentable) {
		guard !AppMaintenanceGuard.isResetting else { return }
		if exports.contains(where: { $0.app.uuid == app.uuid && app.uuid != nil }) {
			return
		}

		let export = AppExport(app: app)
		exports.append(export)
		_start(export)
	}

	func retry(_ export: AppExport) {
		guard exports.contains(where: { $0.id == export.id }) else { return }
		_cancelWork(for: export)
		export.progress = 0
		export.state = .exporting
		_start(export)
	}

	func cancel(_ export: AppExport) {
		guard exports.contains(where: { $0.id == export.id }) else { return }
		_cancelWork(for: export)
		exports.removeAll { $0.id == export.id }
	}

	private func _start(_ export: AppExport) {
		let runID = UUID()
		runIDs[export.id] = runID
		artifactReaders[runID] = export.snapshot

		let viewModel = InstallerStatusViewModel(isIdevice: false)
		progressObservations[export.id] = viewModel.$packageProgress
			.receive(on: DispatchQueue.main)
			.sink { [weak self, weak export] progress in
				guard let self, let export, self._isCurrent(export, runID: runID) else { return }
				export.progress = progress
			}

		let useShareSheet = UserDefaults.standard.bool(forKey: "Aether.useShareSheetForArchiving")
		tasks[export.id] = Task { @MainActor [weak self, weak export] in
			guard let self else { return }
			// Keep the artifact protected until the worker actually exits, even
			// when Cancel removes the export row before a clone finishes.
			defer { self.artifactReaders[runID] = nil }
			guard let export else { return }
			let handler = ArchiveHandler(app: export.snapshot, viewModel: viewModel, purpose: .export)
			self.handlers[export.id] = handler

			do {
				try await handler.move()
				try Task.checkCancellation()
				let packageURL = try await handler.archive()
				try Task.checkCancellation()
				let archiveURL = try await handler.moveToArchive(
					packageURL,
					shouldOpen: !useShareSheet
				)
				guard self._isCurrent(export, runID: runID), !Task.isCancelled else {
					handler.clean()
					return
				}

				handler.clean()
				self._complete(export, runID: runID)

				if useShareSheet, let archiveURL {
					UIActivityViewController.show(activityItems: [archiveURL])
				}
			} catch is CancellationError {
				handler.clean()
			} catch {
				handler.clean()
				guard self._isCurrent(export, runID: runID) else { return }
				self._fail(export, runID: runID, error: error)
			}
		}
	}

	private func _complete(_ export: AppExport, runID: UUID) {
		guard _isCurrent(export, runID: runID) else { return }
		_cleanUp(for: export)
		exports.removeAll { $0.id == export.id }
	}

	private func _fail(_ export: AppExport, runID: UUID, error: Error) {
		guard _isCurrent(export, runID: runID) else { return }
		_cleanUp(for: export)
		export.state = .failed(error.localizedDescription)
		HapticManager.shared.impact()
	}

	private func _cancelWork(for export: AppExport) {
		runIDs.removeValue(forKey: export.id)
		tasks.removeValue(forKey: export.id)?.cancel()
		handlers.removeValue(forKey: export.id)?.clean()
		progressObservations.removeValue(forKey: export.id)?.cancel()
	}

	private func _cleanUp(for export: AppExport) {
		runIDs.removeValue(forKey: export.id)
		tasks.removeValue(forKey: export.id)
		handlers.removeValue(forKey: export.id)
		progressObservations.removeValue(forKey: export.id)?.cancel()
	}

	private func _isCurrent(_ export: AppExport, runID: UUID) -> Bool {
		exports.contains(where: { $0.id == export.id }) && runIDs[export.id] == runID
	}
}
