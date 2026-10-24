import SwiftUI
import CoreData
import NimbleViews
import UIKit
import Combine
import IDeviceSwift

@MainActor
struct UnifiedImportEntry: Identifiable {
	nonisolated let id: String
	var app: AppInfoPresentable?
	var original: Imported?
	var download: Download?
	var operation: AppInstallationManager.InstallationRequest?
	var export: AppExport?
	var date: Date?

	/// Ignore retired request snapshots while the List's projection catches up.
	func reconciled(with requests: [AppInstallationManager.InstallationRequest]) -> Self {
		guard let previous = operation else { return self }
		var row = self
		row.operation = requests.first { $0.id == previous.id }
		let request = row.operation ?? previous
		if request.signing == nil, request.app.isSigned {
			row.app = request.app
		}
		return row
	}

	var displayName: String {
		let candidates = [app?.name, operation?.app.name, export?.app.name,
			download?.sourceProvenance?.sourceAppName, app?.identifier,
			download?.sourceProvenance?.sourceAppIdentifier, download?.fileName]
		return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first { !$0.isEmpty } ?? .localized("Unknown")
	}

	var signature: String {
		var components: [String] = [id]
		components.append(app?.uuid ?? "")
		components.append(app?.name ?? "")
		components.append(app?.identifier ?? "")
		components.append(app?.version ?? "")
		components.append(String(date?.timeIntervalSinceReferenceDate ?? 0))
		components.append(original?.uuid ?? "")
		components.append(String(app?.isSigned ?? false))
		components.append(app is AppSnapshot ? "snapshot" : "stored")
		components.append(download?.id ?? "")
		components.append(operation?.id.uuidString ?? "")
		components.append(operation?.appKey ?? "")
		components.append(export?.id.uuidString ?? "")
		return components.joined(separator: "|")
	}
}

@MainActor
final class UnifiedImportsController: ObservableObject {
	@Published var infoApp: AnyApp?
	@Published var signingApp: AnyApp?
	@Published var importing = false
	@Published var importingURL = false
	@Published var urlText = ""
	@Published private(set) var deletingRows: Set<String> = []
	@Published private(set) var cancellingRows: Set<String> = []
	@Published private(set) var revision: UInt64 = 0
	private var rowSignatures: [String] = []
	@Published private(set) var rows: [UnifiedImportEntry] = []

	var visibleRows: [UnifiedImportEntry] {
		rows.filter { !deletingRows.contains($0.id) && !cancellingRows.contains($0.id) }
	}
	var hasRows: Bool { !visibleRows.isEmpty }

	func updateRows(_ rows: [UnifiedImportEntry]) {
		let signatures = rows.map { $0.signature }
		guard rowSignatures != signatures else { return }
		rowSignatures = signatures
		self.rows = rows
		revision &+= 1
	}

	func isProtected(_ row: UnifiedImportEntry) -> Bool {
		if deletingRows.contains(row.id) || cancellingRows.contains(row.id) { return true }
		if row.operation != nil { return true }
		var artifacts: [AppInfoPresentable] = []
		if let app = row.app { artifacts.append(app) }
		if let original = row.original { artifacts.append(original) }
		return artifacts.contains { app in
			AppInstallationManager.shared.containsInstallation(for: app)
				|| DownloadManager.shared.usesLibraryArtifact(app)
				|| ExportManager.shared.usesLibraryArtifact(app)
		}
	}

	func cancelDownload(_ download: Download, rowID: String) {
		guard !cancellingRows.contains(rowID) else { return }
		cancellingRows.insert(rowID)
		Task { @MainActor in
			defer {
				// A retired transfer must not reappear when cleanup releases its lock.
				updateRows(rows.filter { $0.id != rowID })
				cancellingRows.remove(rowID)
			}
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				DownloadManager.shared.deleteDownload(download) { continuation.resume() }
			}
		}
	}
	func delete(_ targets: [UnifiedImportEntry]) {
		let lineage = LibraryArtifactIndex.shared.lineage
		// Menus can outlive the snapshot used to construct their actions.
		let currentTargets = targets.compactMap { target in
			rows.first(where: { $0.id == target.id })?.reconciled(with: AppInstallationManager.shared.installationCards)
		}
		let deletable = currentTargets.filter { !deletingRows.contains($0.id) && !cancellingRows.contains($0.id) && !isProtected($0) }
		guard !deletable.isEmpty else { return }
		let deletingSigned = Set(deletable.compactMap { $0.app?.isSigned == true ? $0.app?.uuid : nil })
		let existingSigned = Set(visibleRows.compactMap { $0.app?.isSigned == true ? $0.app?.uuid : nil })
		let originalsToDelete = lineage.originalUUIDsToDelete(deletingSigned: deletingSigned, existingSigned: existingSigned)
		var artifacts: [String: AppSnapshot] = [:]
		for row in deletable {
			if let app = row.app, let uuid = app.uuid {
				artifacts["\(app.isSigned)|\(uuid)"] = AppSnapshot(app)
			}
			if let original = row.original, let originalUUID = original.uuid, originalsToDelete.contains(originalUUID) {
				artifacts["false|" + originalUUID] = AppSnapshot(original)
			}
		}
		let snapshots = Array(artifacts.values)
		let downloads = deletable.compactMap { $0.download }
		let exports = deletable.compactMap { $0.export }
		let rowIDs = Set(deletable.map(\.id))
		deletingRows.formUnion(rowIDs)
		Task { @MainActor in
			defer {
				deletingRows.subtract(rowIDs)
			}
			await Task.yield()
			for export in exports { ExportManager.shared.cancel(export) }
			for download in downloads {
				await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
					DownloadManager.shared.deleteDownload(download) { continuation.resume() }
				}
				await Task.yield()
			}
			var retained = targets.count != deletable.count
			var removalCommitted = true
			for app in snapshots {
				if !(await Storage.shared.deleteAppAsync(for: app)) { retained = true; removalCommitted = false }
				await Task.yield()
			}
			// Discard committed rows before releasing their masks, even if the
			// fetch request has not delivered its next snapshot yet.
			if removalCommitted { updateRows(rows.filter { !rowIDs.contains($0.id) }) }
			if retained {
				DebugLogManager.shared.log("Row deletion retained an artifact still in use.", category: "Library", level: .notice)
			}
		}
	}

	var manualURL: URL? {
		guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
			["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return nil }
		return url
	}
}

/// Observe the catalog on the persistent list, even when it has no sections.
struct UnifiedImportsDataSource: ViewModifier {
	@ObservedObject var controller: UnifiedImportsController
	@ObservedObject private var downloads = DownloadManager.shared
	@ObservedObject private var installations = AppInstallationManager.shared
	@ObservedObject private var exports = ExportManager.shared
	@ObservedObject private var index = LibraryArtifactIndex.shared
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]) private var imported: FetchedResults<Imported>
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]) private var signed: FetchedResults<Signed>

    private struct ArtifactInput: Equatable {
        let uuid: String?
        let signed: Bool
        let name: String?
        let identifier: String?
        let version: String?
        let date: Date?
        init(_ app: AppInfoPresentable) {
            uuid = app.uuid; signed = app.isSigned; name = app.name
            identifier = app.identifier; version = app.version; date = app.date
        }
    }
    private struct Inputs: Equatable {
        let artifacts: [ArtifactInput]
        let downloads: [String]
        let committedImports: [String]
        let operations: [String]
        let exports: [UUID]
        let lineage: LibraryArtifactLineage
    }
    private var inputs: Inputs {
        let artifacts: [AppInfoPresentable] = Array(imported).map { $0 as AppInfoPresentable } + Array(signed).map { $0 as AppInfoPresentable }
        return Inputs(artifacts: artifacts.map { ArtifactInput($0) },
            downloads: downloads.downloads.map { $0.id },
            committedImports: downloads.committedImports.keys.sorted(),
            operations: installations.installationCards.map { "\($0.id)|\($0.appKey)|\($0.app.name ?? "")|\($0.app.version ?? "")" },
            exports: exports.exports.map(\.id), lineage: index.lineage)
    }
    func body(content: Content) -> some View {
        content.onChange(of: inputs, initial: true) { _, _ in
            controller.updateRows(projectedRows)
            let retired = downloads.committedImports.keys.filter { index.lineage.originalDates[$0] == nil }
            downloads.acknowledgeImports(Set(imported.compactMap(\.uuid)).union(retired))
        }
    }

	private var projectedRows: [UnifiedImportEntry] {
		let originals: [String: Imported] = Dictionary(imported.compactMap { app in app.uuid.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
		let lineage = index.lineage
		var linkedOriginals = Set(signed.compactMap { app in app.uuid.flatMap { lineage.signedOrigins[$0]?.originalUUID } })
		let transferringOriginals = Set(downloads.downloads.map(\.importIdentifier))
		var rows = signed.compactMap { app -> UnifiedImportEntry? in
			guard let uuid = app.uuid else { return nil }
			let original = (lineage.signedOrigins[uuid]?.originalUUID).flatMap { originals[$0] }
			let date = (original?.uuid).flatMap { lineage.originalDates[$0] } ?? original?.date ?? app.date
			return UnifiedImportEntry(id: lineage.rowID(forSigned: uuid), app: app, original: original, date: date)
		}
		let fetchedSignedIDs = Set(signed.compactMap(\.uuid))
		// A completed sign-only operation can retire before its fetched record arrives.
		// Retain only its committed snapshot, not an arbitrary removed/stale row.
		for previous in controller.rows {
			guard let app = previous.app as? AppSnapshot, app.isSigned, let uuid = app.uuid,
				!fetchedSignedIDs.contains(uuid), let origin = lineage.signedOrigins[uuid] else { continue }
			let original = origin.originalUUID.flatMap { originals[$0] }
			if let uuid = original?.uuid { linkedOriginals.insert(uuid) }
			rows.append(UnifiedImportEntry(id: origin.rowID, app: app, original: original, date: previous.date))
		}

		for app in imported {
			guard let uuid = app.uuid, !transferringOriginals.contains(uuid),
				!linkedOriginals.contains(uuid) || lineage.revealedOriginals.contains(uuid) else { continue }
			rows.append(UnifiedImportEntry(id: "app:" + uuid, app: app, date: lineage.originalDates[uuid] ?? app.date))
		}
		for (uuid, app) in downloads.committedImports {
			guard lineage.originalDates[uuid] != nil, originals[uuid] == nil, !transferringOriginals.contains(uuid),
				!linkedOriginals.contains(uuid) || lineage.revealedOriginals.contains(uuid) else { continue }
			rows.append(UnifiedImportEntry(id: "app:" + uuid, app: app,
				date: lineage.originalDates[uuid] ?? app.date))
		}

		for download in downloads.downloads {
			rows.append(UnifiedImportEntry(id: "app:" + download.importIdentifier, app: originals[download.importIdentifier], download: download,
				date: lineage.originalDates[download.importIdentifier]))
		}
		for request in installations.installationCards {
			let exact = rows.firstIndex { row in
				guard let app = row.app else { return false }
				return AppInstallationManager.InstallationRequest.appKey(for: app) == request.appKey
			}
			// The signed snapshot can arrive before @FetchRequest delivers its record.
			// Resolve through lineage in that interval instead of inserting an operation row.
			let rowID = request.app.uuid.map { uuid in
				request.app.isSigned ? lineage.rowID(forSigned: uuid) : "app:" + uuid
			} ?? "operation:" + request.id.uuidString
			let inherited = rows.firstIndex { $0.id == rowID }
			if let position = exact ?? inherited {
				if request.app.isSigned, rows[position].app?.isSigned != true {
					rows[position].original = rows[position].app as? Imported
					rows[position].app = request.app
				}
				rows[position].operation = request
			} else {
				let previousDate = controller.rows.first(where: { $0.id == rowID })?.date
				rows.append(UnifiedImportEntry(id: rowID, app: request.app,
					operation: request, date: previousDate ?? request.app.date))
			}
		}
		for export in exports.exports {
			if let position = rows.firstIndex(where: { row in
				row.app?.uuid == export.snapshot.uuid && row.app?.isSigned == export.snapshot.isSigned
			}) { rows[position].export = export }
		}
		// Fetch results, lineage and operation snapshots publish independently.
		// Keep exactly one owner for each stable list identity during a handoff.
		var merged: [String: UnifiedImportEntry] = [:]
		for row in rows {
			if var existing = merged[row.id] {
				if let app = row.app, existing.app == nil || app.isSigned { existing.app = app }
				existing.original = row.original ?? existing.original
				existing.download = row.download ?? existing.download
				existing.operation = row.operation ?? existing.operation
				existing.export = row.export ?? existing.export
				existing.date = existing.date ?? row.date
				merged[row.id] = existing
			} else { merged[row.id] = row }
		}
		return merged.values.sorted {
			let left = $0.date ?? .distantFuture, right = $1.date ?? .distantFuture
			return left == right ? $0.id < $1.id : left > right
		}
	}
}

/// The parent List owns section membership; this view only supplies stable rows.
struct UnifiedImportsRows: View {
	let entries: [UnifiedImportEntry]
	let controller: UnifiedImportsController
	var visibleOperation: (UUID, String, Bool) -> Void

	var body: some View {
		ForEach(entries) { entry in
			UnifiedImportRow(entry: entry, controller: controller)
				.id(entry.id)
				.onChange(of: entry.operation?.id, initial: true) { old, new in
					if let old { visibleOperation(old, entry.id, false) }
					if let new { visibleOperation(new, entry.id, true) }
				}
				.onAppear { if let operation = entry.operation { visibleOperation(operation.id, entry.id, true) } }
				.onDisappear { if let operation = entry.operation { visibleOperation(operation.id, entry.id, false) } }
		}
	}
}

private struct UnifiedImportRow: View {
	let snapshot: UnifiedImportEntry
	init(entry: UnifiedImportEntry, controller: UnifiedImportsController) {
		self.snapshot = entry
		self.controller = controller
	}
	private var entry: UnifiedImportEntry { snapshot.reconciled(with: installations.installationCards) }
	@ObservedObject var controller: UnifiedImportsController
	@ObservedObject private var installations = AppInstallationManager.shared
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .standard
	@State private var retainedIconURL: URL?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	var body: some View {
		HStack(spacing: NBRowMetrics.contentSpacing) {
			FRAppIconView(app: displayApp, size: rowIconSize.points, remoteIconURL: retainedIconURL ?? entry.download?.sourceProvenance?.sourceAppIconURL, usesDefaultApp: false, retainsPreviousImage: true)
				.overlay(alignment: .bottomTrailing) {
					if displayApp?.isSigned == true {
						Circle()
							.fill(.green)
							.frame(width: 9, height: 9)
							.padding(2)
							.background(Color(uiColor: .systemBackground), in: .circle)
							.offset(x: 3, y: 3)
							.accessibilityLabel(String.localized("Signed"))
							.transition(reduceMotion ? .identity : .opacity)
					}
				}
				.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: displayApp?.isSigned == true)
			UnifiedImportMetadata(entry: entry, model: activeModel)
			UnifiedImportAccessory(entry: entry, model: activeModel, controller: controller)
		}
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: entry.signature)
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: entry.signOnlyCompleted(model: activeModel))
		.padding(horizontalSizeClass == .compact ? 0 : 12)
		.background {
			if horizontalSizeClass != .compact {
				RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.quaternarySystemFill))
			}
		}
		.onChange(of: entry.download?.sourceProvenance?.sourceAppIconURL, initial: true) { _, url in
			if let url { retainedIconURL = url }
		}
		.sheet(isPresented: serverPresentation) {
			if let installer = installations.installer {
				SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
			}
		}
		.contentShape(Rectangle())
		.swipeActions {
			UnifiedImportActions(entry: entry, controller: controller, forSwipe: true)
		}
		.contextMenu {
			UnifiedImportActions(entry: entry, controller: controller)
		}
	}

	private var serverPresentation: Binding<Bool> {
		Binding(get: {
			entry.operation != nil && installations.currentRequest?.id == entry.operation?.id && installations.isWebviewPresenting
		}, set: { presented in
			guard entry.operation != nil, installations.currentRequest?.id == entry.operation?.id else { return }
			installations.isWebviewPresenting = presented
		})
	}

	private var displayApp: AppInfoPresentable? {
		entry.app ?? entry.operation?.app ?? entry.export?.app
	}

	private var activeModel: InstallerStatusViewModel? {
		installations.currentRequest?.id == entry.operation?.id ? installations.viewModel : nil
	}


}

/// Shared actions for each row's context menu and native swipe.
struct UnifiedImportActions: View {
	let snapshot: UnifiedImportEntry
	@ObservedObject var controller: UnifiedImportsController
	let forSwipe: Bool
	init(entry: UnifiedImportEntry, controller: UnifiedImportsController, forSwipe: Bool = false) {
		self.snapshot = entry
		self.controller = controller
		self.forSwipe = forSwipe
	}
	private var entry: UnifiedImportEntry { snapshot.reconciled(with: installations.installationCards) }
	@ObservedObject private var installations = AppInstallationManager.shared
	private var protected: Bool { controller.isProtected(entry) }

	var body: some View {
		if forSwipe {
            removalAction(forSwipe: true)
            if entry.app?.isSigned == true, let original = entry.original, let uuid = original.uuid,
                !LibraryArtifactIndex.shared.lineage.revealedOriginals.contains(uuid) {
                Button(.localized("Unsign"), systemImage: "doc.on.doc") {
                    LibraryArtifactIndex.shared.reveal(originalUUID: uuid)
                }.tint(.orange).disabled(protected)
            }
        }
		else { contextActions }
	}

	@ViewBuilder private var contextActions: some View {
		if let app = entry.app {
			Button(.localized("Get Info"), systemImage: "info.circle") { controller.infoApp = AnyApp(base: app) }
			if app.isSigned, let identifier = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") { UIApplication.openApp(with: identifier) }
			}
			Button(installations.installActionTitle(for: app), systemImage: "square.and.arrow.down") {
				if installations.startInstall(app: app) { HapticManager.shared.impact() }
			}.disabled(protected)
			Button(app.isSigned ? .localized("Re-sign") : .localized("Sign"), systemImage: "signature") {
				controller.signingApp = AnyApp(base: app)
			}.disabled(protected)
			if app.isSigned {
				Button(.localized("Export"), systemImage: "square.and.arrow.up") { ExportManager.shared.startExport(app: app) }.disabled(protected)
				if let original = entry.original, let uuid = original.uuid {
					Button(.localized("Show Unsigned IPA"), systemImage: "doc.on.doc") { LibraryArtifactIndex.shared.reveal(originalUUID: uuid) }
						.disabled(protected || LibraryArtifactIndex.shared.lineage.revealedOriginals.contains(uuid))
				}
			}
		}
		if let request = entry.operation, installations.currentRequest?.id == request.id,
			case .broken = installations.viewModel?.status {
			if entry.app != nil { Divider() }
			Button(.localized("Retry"), systemImage: "arrow.clockwise") { installations.retryActiveInstall() }
		}
		if entry.app != nil || entry.operation != nil { Divider() }
		removalAction()
	}

	// The model owns row removal. Native destructive swipe roles would also
	// optimistically remove the cell before asynchronous cleanup commits.
	@ViewBuilder private func removalAction(forSwipe: Bool = false) -> some View {
		if let request = entry.operation {
			let isCurrent = installations.currentRequest?.id == request.id
			let completed = isCurrent && installations.viewModel?.isCompleted == true
			Button(completed ? .localized("Dismiss") : .localized("Cancel"), systemImage: "xmark", role: forSwipe ? nil : .destructive) {
				installations.cancelRequest(id: request.id)
			}
			.tint(.red)
			.disabled(isCurrent && installations.isFinishingInstallation)
		} else if let download = entry.download {
			Button(.localized("Cancel"), systemImage: "xmark", role: forSwipe ? nil : .destructive) {
				controller.cancelDownload(download, rowID: entry.id)
			}.tint(.red).disabled(controller.cancellingRows.contains(entry.id))
		} else if let export = entry.export {
			Button(.localized("Cancel"), systemImage: "xmark", role: forSwipe ? nil : .destructive) { ExportManager.shared.cancel(export) }
				.tint(.red)
		} else {
			Button(.localized("Delete"), systemImage: "trash", role: forSwipe ? nil : .destructive) { controller.delete([entry]) }.tint(.red).disabled(protected)
		}
	}
}

/// Only metadata and controls observe frequent progress changes. The row and icon
/// keep their SwiftUI identity while the backing artifact changes lifecycle stage.
@MainActor
private final class UnifiedImportActivity: ObservableObject {
	private var subscriptions = Set<AnyCancellable>()

	init(entry: UnifiedImportEntry, model: InstallerStatusViewModel?) { bind(entry: entry, model: model) }

	func bind(entry: UnifiedImportEntry, model: InstallerStatusViewModel?) {
		subscriptions.removeAll()
		let publishers = [entry.download?.objectWillChange.eraseToAnyPublisher(), entry.export?.objectWillChange.eraseToAnyPublisher(), model?.objectWillChange.eraseToAnyPublisher()].compactMap { $0 }
		for publisher in publishers {
			publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
		}
		objectWillChange.send()
	}

}

private extension UnifiedImportEntry {
	func signOnlyCompleted(model: InstallerStatusViewModel?) -> Bool {
		guard let operation, !operation.installRequested else { return false }
		// A committed sign-only request retains its signed snapshot after the
		// status model retires. Never fall back to a queued ring in that interval.
		if operation.signing == nil, operation.app.isSigned { return true }
		if case .completed(.success) = model?.status { return app?.isSigned == true }
		return false
	}
}

private struct UnifiedImportMetadata: View {
	let entry: UnifiedImportEntry
	let model: InstallerStatusViewModel?
	@StateObject private var activity: UnifiedImportActivity
	@State private var showsErrorDetails = false

	init(entry: UnifiedImportEntry, model: InstallerStatusViewModel?) {
		self.entry = entry
		self.model = model
		_activity = StateObject(wrappedValue: UnifiedImportActivity(entry: entry, model: model))
	}

	private var app: AppInfoPresentable? { entry.app ?? entry.operation?.app ?? entry.export?.app }

	private var status: (text: String?, failed: Bool) {
		if entry.operation != nil, !entry.signOnlyCompleted(model: model) {
			guard let model = model else { return (.localized("Queued"), false) }
			if case .broken(let error) = model.status {
				return (AppRowFailure.text(for: error, stage: entry.operation?.signing != nil ? .signing : .installation), true)
			}
			return (AppInstallationManager.shared.isFinishingInstallation ? .localized("Finishing Installation") : model.statusLabel, false)
		}
		if let export = entry.export {
			switch export.state {
			case .exporting: return ("\(String.localized("Processing")) \(Int(export.progress * 100))%", false)
			case .failed(let message): return (AppRowFailure.text(message: message, stage: .export), true)
			}
		}
		if let download = entry.download {
			switch download.state {
			case .downloading:
				return (download.totalBytes > 0 ? "\(download.bytesDownloaded.formattedByteCount) / \(download.totalBytes.formattedByteCount)" : .localized("Downloading"), false)
			case .pausing: return (.localized("Pausing"), false)
			case .paused: return (.localized("Paused"), false)
			case .resuming: return (.localized("Resuming"), false)
			case .processing:
				if download.waitingForForeground { return (.localized("Open Aether to resume"), false) }
				if download.isPreparingSource { return (.localized("Preparing Import"), false) }
				return ("\(String.localized("Processing")) \(Int(download.overallProgress * 100))%", false)
			case .failed(let message, _): return (AppRowFailure.text(message: message, stage: download.onlyArchiving || download.stagedFileName != nil ? .processing : .download), true)
			}
		}
		return (nil, false)
	}

	private var failureDetails: String? {
		if entry.operation != nil, case .broken(let error) = model?.status { return error.localizedDescription }
		if let export = entry.export, case .failed(let message) = export.state { return message }
		if let download = entry.download, case .failed(let message, _) = download.state { return message }
		return nil
	}

	/// Progress values update in place; only changes of phase animate the status.
	private var numericProgressPhase: String? {
		if entry.operation != nil, !entry.signOnlyCompleted(model: model) { return nil }
		if let export = entry.export {
			if case .exporting = export.state { return "export-processing" }
			return nil
		}
		if let download = entry.download {
			switch download.state {
			case .downloading: return "downloading"
			case .processing where !download.waitingForForeground:
					return download.isPreparingSource ? "download-preparing" : "download-processing"
			default: return nil
			}
		}
		return nil
	}

	private var showsTaskStatus: Bool {
		(entry.operation != nil && !entry.signOnlyCompleted(model: model)) || entry.download != nil || entry.export != nil
	}


	var body: some View {
		let status = status
		LibraryRowDetails(
			name: entry.displayName,
			version: app?.version ?? entry.download?.sourceProvenance?.sourceAppVersion,
			identifier: app?.identifier ?? entry.download?.sourceProvenance?.sourceAppIdentifier,
			secondaryStatus: showsTaskStatus ? nil : status.text,
			isFailed: !showsTaskStatus && status.failed,
			animatesStatus: true,
			thirdLineStatus: showsTaskStatus ? status.text : nil,
			thirdLineAnimationKey: numericProgressPhase ?? status.text,
			crossfadesStatus: true
		)
		.onTapGesture { if failureDetails != nil { showsErrorDetails = true } }
		.alert(String.localized("Error Details"), isPresented: $showsErrorDetails) {
			Button(String.localized("OK"), role: .cancel) {}
		} message: { Text(failureDetails ?? "") }
		.onChange(of: entry.signature) { _, _ in activity.bind(entry: entry, model: model) }
		.onChange(of: model.map { ObjectIdentifier($0) }) { _, _ in activity.bind(entry: entry, model: model) }
	}
}

/// Reserve enough room for every ready action, including localized labels.
/// Only the first subview is visible; the others supply intrinsic measurements.
private struct ImportAccessoryLayout: Layout {
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
		return CGSize(width: max(44, sizes.map(\.width).max() ?? 44),
			height: max(44, sizes.map(\.height).max() ?? 44))
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			view.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
				proposal: ProposedViewSize(width: size.width, height: size.height))
		}
	}
}

/// A single shape owns the progress track and the pill throughout the morph.
private struct ImportAccessorySurface: Shape {
	var expansion: CGFloat
	var animatableData: CGFloat {
		get { expansion }
		set { expansion = newValue }
	}

	func path(in rect: CGRect) -> Path {
		let width = 31 + (rect.width - 31) * expansion
		let height = 31 + 4 * expansion
		let trailingInset = 6.5 * (1 - expansion)
		return Capsule().path(in: CGRect(x: rect.maxX - trailingInset - width,
			y: rect.midY - height / 2, width: width, height: height))
	}
}

/// A value snapshot keeps the departing progress visual alive without retaining
/// a completed download, export or installation model.
private struct ImportAccessoryProgress: Equatable {
	var amount: Double?
	var symbol: String
	var failed = false
	var preparing = false
}

/// Geometry and content derive from the same spring sample, not separate fades.
private struct ImportAccessoryMorph: AnimatableModifier {
	var expansion: CGFloat
	let progress: ImportAccessoryProgress?
	let reduceMotion: Bool

	var animatableData: CGFloat {
		get { expansion }
		set { expansion = newValue }
	}

	private func ramp(_ start: CGFloat, _ end: CGFloat) -> Double {
		let t = min(1, max(0, (expansion - start) / (end - start)))
		return Double(t * t * (3 - 2 * t))
	}

	func body(content: Content) -> some View {
		let geometry = min(1.08, max(0, expansion))
		let tint: Color = progress?.failed == true ? .red : .accentColor
		content
			.opacity(ramp(0.45, 0.95))
			.background {
				ImportAccessorySurface(expansion: geometry)
					.fill(Color(uiColor: .quaternarySystemFill).opacity(ramp(0.05, 0.9)))
					.overlay {
						ImportAccessorySurface(expansion: geometry)
							.stroke(tint.opacity(0.2 * (1 - ramp(0.3, 1))), lineWidth: 2.3)
					}
			}
			.overlay {
				GeometryReader { bounds in
					if let progress {
						ZStack {
							if let amount = progress.amount {
								Circle().trim(from: 0, to: min(1, max(0, amount)))
									.stroke(tint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
									.rotationEffect(.degrees(-90))
									.animation(reduceMotion ? nil : .smooth, value: amount)
							}
							if progress.preparing {
								ProgressView().controlSize(.small).tint(tint)
							} else {
								Image(systemName: progress.symbol)
									.font(.footnote.bold()).foregroundStyle(tint)
									.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
									.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progress.symbol)
							}
						}
						.frame(width: 31, height: 31)
						// Follow the center of the widening surface rather than leaving
						// the old symbol stranded at the circle's original position.
						.position(x: bounds.size.width - 6.5 * (1 - geometry)
							- (31 + (bounds.size.width - 31) * geometry) / 2,
							y: bounds.size.height / 2)
						.opacity(1 - ramp(0.2, 0.7))
					}
				}
				.allowsHitTesting(false).accessibilityHidden(true)
			}
	}
}

private struct UnifiedImportAccessory: View {
	let entry: UnifiedImportEntry
	let model: InstallerStatusViewModel?
	@ObservedObject var controller: UnifiedImportsController
	@StateObject private var activity: UnifiedImportActivity
	@State private var retainedProgress: ImportAccessoryProgress?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	init(entry: UnifiedImportEntry, model: InstallerStatusViewModel?, controller: UnifiedImportsController) {
		self.entry = entry
		self.model = model
		self.controller = controller
		_activity = StateObject(wrappedValue: UnifiedImportActivity(entry: entry, model: model))
	}

	private var actionTitle: String {
		guard let app = entry.app, app.isSigned else { return .localized("Sign") }
		return AppInstallationManager.shared.installActionTitle(for: app)
	}

	private var stage: String {
		if let operation = entry.operation, !entry.signOnlyCompleted(model: model) { return operation.id.uuidString }
		if let export = entry.export { return "export:" + export.id.uuidString }
		if let download = entry.download { return "download:" + download.id }
		return "ready"
	}

	private var isBusy: Bool { stage != "ready" }

	private var morphAnimation: Animation? {
		reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.12)
	}

	var body: some View {
		ImportAccessoryLayout {
			Button {
				guard !isBusy, let app = entry.app, !controller.isProtected(entry) else { return }
				if app.isSigned {
					if AppInstallationManager.shared.startInstall(app: app) { HapticManager.shared.impact() }
				} else { controller.signingApp = AnyApp(base: app) }
			} label: {
				NBButton(actionTitle, style: .text, showsBackground: false)
					.foregroundStyle(Color.accentColor)
					.contentTransition(reduceMotion ? .identity : .opacity)
			}
			.buttonStyle(.borderless)
			.disabled(isBusy || controller.isProtected(entry))
			.accessibilityHidden(isBusy)
			.modifier(ImportAccessoryMorph(expansion: isBusy ? 0 : 1,
				progress: progressPresentation ?? retainedProgress, reduceMotion: reduceMotion))
			.animation(morphAnimation, value: isBusy)
			ForEach(Array([String.localized("Sign"), String.localized("Install"), String.localized("Reinstall")].enumerated()), id: \.offset) { _, title in
				NBButton(title, style: .text).hidden().accessibilityHidden(true)
			}
		}
		.overlay(alignment: .trailing) {
			ZStack {
				// Existing controls retain their native actions and accessibility;
				// the shared morph above owns all visible drawing.
				progressControl
			}
				.allowsHitTesting(isBusy)
				.accessibilityHidden(!isBusy)
		}
		.tint(Color.accentColor)
		.foregroundStyle(Color.accentColor)
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: actionTitle)
		.onChange(of: progressPresentation, initial: true) { _, presentation in
			if let presentation { retainedProgress = presentation }
		}
		.onChange(of: entry.signature) { _, _ in activity.bind(entry: entry, model: model) }
		.onChange(of: model.map { ObjectIdentifier($0) }) { _, _ in activity.bind(entry: entry, model: model) }
	}

	@ViewBuilder private var progressControl: some View {
		if entry.operation != nil, !entry.signOnlyCompleted(model: model) {
			ZStack {
				Color.clear.frame(width: 44, height: 44)
					.accessibilityLabel(model?.statusLabel ?? String.localized("Queued"))
					.accessibilityValue(model.map { Text(progress($0), format: .percent.precision(.fractionLength(0))) } ?? Text(""))
					.accessibilityHidden(canRetry)
				if canRetry {
					Button { AppInstallationManager.shared.retryActiveInstall() } label: {
						Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
					}
					.buttonStyle(.borderless)
					.accessibilityLabel(String.localized("Retry"))
				}
			}
		} else if let export = entry.export { ExportProgressButton(export: export, showsContent: false) }
		else if let download = entry.download { DownloadProgressButton(download: download, showsContent: false) }
	}

	private var progressPresentation: ImportAccessoryProgress? {
		guard isBusy else { return nil }
		if entry.operation != nil {
			return ImportAccessoryProgress(amount: operationRingProgress, symbol: operationRingSymbol)
		}
		if let export = entry.export {
			if case .failed = export.state { return .init(amount: nil, symbol: "arrow.clockwise", failed: true) }
			return .init(amount: export.progress, symbol: "xmark")
		}
		if let download = entry.download {
			let symbol: String
			let amount: Double?
			switch download.state {
			case .downloading: symbol = "pause.fill"; amount = download.overallProgress
			case .pausing, .resuming: symbol = "hourglass"; amount = download.overallProgress
			case .paused: symbol = "play.fill"; amount = nil
			case .processing:
				symbol = download.waitingForForeground ? "hourglass" : "archivebox"
				amount = download.overallProgress
			case .failed: symbol = "arrow.clockwise"; amount = nil
			}
			return .init(amount: amount, symbol: symbol,
				preparing: download.isPreparingSource && !download.waitingForForeground)
		}
		return nil
	}

	private var canRetry: Bool {
		if case .broken = model?.status { return true }
		return false
	}

	private var operationRingProgress: Double? {
		guard let model, !canRetry else { return nil }
		return progress(model)
	}

	private var operationRingSymbol: String {
		canRetry ? "arrow.clockwise" : (model?.statusImage ?? "clock")
	}

	private func progress(_ model: InstallerStatusViewModel) -> Double { model.operationProgress }

}

struct UnifiedImportsPresentation: ViewModifier {
	@ObservedObject var controller: UnifiedImportsController
	func body(content: Content) -> some View {
		content
			.sheet(item: $controller.infoApp) { LibraryInfoView(app: $0.base) }
			.fullScreenCover(item: $controller.signingApp) { SigningView(app: $0.base) }
			.sheet(isPresented: $controller.importing) {
				LibraryImportPickerView { urls in
					controller.importing = false
					for url in urls {
						let download = DownloadManager.shared.startArchive(from: url, id: "AetherManualDownload_" + UUID().uuidString)
						DownloadManager.shared.retryProcessing(download)
					}
				}.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $controller.importingURL) {
				TextField(.localized("URL"), text: $controller.urlText)
					.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
				Button(.localized("Cancel"), role: .cancel) { controller.urlText = "" }
				Button(.localized("Download")) {
					guard let url = controller.manualURL else { return }
					controller.urlText = ""
					Task { _ = await DownloadManager.shared.startDownload(from: url, id: "AetherManualDownload_" + UUID().uuidString) }
				}.disabled(controller.manualURL == nil)
			} message: { Text(.localized("Enter a direct HTTP or HTTPS link to an IPA file.")) }
	}
}
