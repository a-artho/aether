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

	var signature: String {
		var components: [String] = [id]
		components.append(app?.uuid ?? "")
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
	@Published var selectedRows: Set<String> = []
	@Published var editMode: EditMode = .inactive
	@Published var infoApp: AnyApp?
	@Published var signingApp: AnyApp?
	@Published var importing = false
	@Published var importingURL = false
	@Published var urlText = ""
	@Published var confirmingDeleteAll = false
	@Published private(set) var showsDeletionProgress = false
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
		selectedRows.formIntersection(visibleRows.map(\.id))
	}

	func select() { withAnimation { editMode = .active } }
	func finishSelection() { withAnimation { editMode = .inactive; selectedRows.removeAll() } }
	func toggle(_ id: String) {
		if selectedRows.contains(id) { selectedRows.remove(id) }
		else { selectedRows.insert(id) }
	}

	func isProtected(_ row: UnifiedImportEntry) -> Bool {
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

	func deleteSelected() { delete(visibleRows.filter { selectedRows.contains($0.id) }, showProgress: true) }
	func deleteAll() { delete(visibleRows, showProgress: true); finishSelection() }
	func cancelDownload(_ download: Download, rowID: String) {
		guard !cancellingRows.contains(rowID) else { return }
		cancellingRows.insert(rowID)
		Task { @MainActor in
			defer { cancellingRows.remove(rowID) }
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				DownloadManager.shared.deleteDownload(download) { continuation.resume() }
			}
			selectedRows.remove(rowID)
		}
	}
	func delete(_ targets: [UnifiedImportEntry], showProgress: Bool = false) {
		guard !showsDeletionProgress else { return }
		let lineage = LibraryArtifactIndex.shared.lineage
		let deletable = targets.filter { !deletingRows.contains($0.id) && !cancellingRows.contains($0.id) && !isProtected($0) }
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
		if showProgress { showsDeletionProgress = true }
		deletingRows.formUnion(rowIDs)
		selectedRows.subtract(rowIDs)
		Task { @MainActor in
			defer {
				deletingRows.subtract(rowIDs)
				if showProgress { showsDeletionProgress = false }
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
			selectedRows.subtract(targets.map(\.id))
			if retained {
				if showProgress {
					UIAlertController.showAlertWithOk(title: .localized("Apps In Use"),
						message: .localized("Apps required by an installation or update were kept. Cancel those operations before deleting them."))
				} else {
					DebugLogManager.shared.log("Row deletion retained an artifact still in use.", category: "Library", level: .notice)
				}
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

	func body(content: Content) -> some View {
		let preparedRows = projectedRows
		return content.onChange(of: preparedRows.map { $0.signature }, initial: true) { _, _ in
			controller.updateRows(preparedRows)
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
		for download in downloads.downloads {
			rows.append(UnifiedImportEntry(id: "app:" + download.importIdentifier, download: download,
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
		return rows.sorted {
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
	let entry: UnifiedImportEntry
	@ObservedObject var controller: UnifiedImportsController
	@ObservedObject private var installations = AppInstallationManager.shared
	@State private var retainedIconURL: URL?
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	private var editing: Bool { controller.editMode.isEditing }
	private var protected: Bool { controller.isProtected(entry) }

	var body: some View {
		HStack(spacing: 18) {
			if editing {
				Button { controller.toggle(entry.id) } label: {
					Image(systemName: controller.selectedRows.contains(entry.id) ? "checkmark.circle.fill" : "circle")
						.font(.title2).foregroundStyle(protected ? Color.secondary : Color.accentColor)
				}
				.buttonStyle(.borderless).disabled(protected)
				.accessibilityLabel(String.localized("Select"))
			}
			FRAppIconView(app: displayApp, size: 50, remoteIconURL: retainedIconURL ?? entry.download?.sourceProvenance?.sourceAppIconURL, usesDefaultApp: false)
				.overlay(alignment: .bottomTrailing) {
					if displayApp?.isSigned == true {
						Circle()
							.fill(.green)
							.frame(width: 9, height: 9)
							.padding(2)
							.background(Color(uiColor: .systemBackground), in: .circle)
							.offset(x: 3, y: 3)
							.accessibilityLabel(String.localized("Signed"))
					}
				}
			UnifiedImportMetadata(entry: entry, model: activeModel)
			if !editing {
				UnifiedImportAccessory(entry: entry, model: activeModel, controller: controller)
					.transition(.opacity)
			}
		}
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
		.onTapGesture { if editing && !protected { controller.toggle(entry.id) } }
		.swipeActions {
			if !editing { removalAction(forSwipe: true) }
		}
		.contextMenu { if !editing { contextActions } }
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

	@ViewBuilder private var contextActions: some View {
		if let app = entry.app {
			Button(.localized("Get Info"), systemImage: "info.circle") { controller.infoApp = AnyApp(base: app) }
			if app.isSigned, let identifier = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") { UIApplication.openApp(with: identifier) }
			}
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
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

	// A destructive swipe optimistically removes the cell. Canceling work on a
	// stored artifact keeps that row, so only actual removals use that swipe role.
	@ViewBuilder private func removalAction(forSwipe: Bool = false) -> some View {
		if let request = entry.operation {
			let isCurrent = installations.currentRequest?.id == request.id
			let completed = isCurrent && activeModel?.isCompleted == true
			Button(completed ? .localized("Dismiss") : .localized("Cancel"), systemImage: "xmark", role: forSwipe && !entry.id.hasPrefix("operation:") ? nil : .destructive) {
				if isCurrent { installations.cancel() }
				else { installations.cancelQueuedInstall(id: request.id) }
			}
			.tint(.red)
			.disabled(isCurrent && installations.isFinishingInstallation)
		} else if let download = entry.download {
			Button(.localized("Cancel"), systemImage: "xmark", role: .destructive) {
				controller.cancelDownload(download, rowID: entry.id)
			}
		} else if let export = entry.export {
			Button(.localized("Cancel"), systemImage: "xmark", role: forSwipe && entry.app != nil ? nil : .destructive) { ExportManager.shared.cancel(export) }
				.tint(.red)
		} else {
			Button(.localized("Delete"), systemImage: "trash", role: .destructive) { controller.delete([entry]) }.disabled(protected)
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
		guard operation?.installRequested == false else { return false }
		if case .completed(.success) = model?.status { return true }
		return false
	}
}

private struct UnifiedImportMetadata: View {
	let entry: UnifiedImportEntry
	let model: InstallerStatusViewModel?
	@StateObject private var activity: UnifiedImportActivity

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
				return (error is InstallationBackgroundError ? .localized("iOS interrupted background installation") : error.localizedDescription, true)
			}
			return (AppInstallationManager.shared.isFinishingInstallation ? .localized("Finishing Installation") : model.statusLabel, false)
		}
		if let export = entry.export {
			switch export.state {
			case .exporting: return ("\(String.localized("Processing")) \(Int(export.progress * 100))%", false)
			case .failed(let message): return (message.isEmpty ? .localized("Error") : message, true)
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
			case .failed(let message, _): return (message.isEmpty ? .localized("Download Failed") : message, true)
			}
		}
		return (nil, false)
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
			case .processing where !download.waitingForForeground: return "download-processing"
			default: return nil
			}
		}
		return nil
	}

	private var showsTaskStatus: Bool {
		(entry.operation != nil && !entry.signOnlyCompleted(model: model)) || entry.download != nil || entry.export != nil
	}

	private var statusColor: Color {
		if entry.operation != nil, !entry.signOnlyCompleted(model: model) {
			guard let model else { return .secondary }
			if case .broken = model.status { return .red }
			return AppInstallationManager.shared.isFinishingInstallation ? .accentColor : model.statusColor
		}
		if let export = entry.export {
			if case .failed = export.state { return .red }
			return .accentColor
		}
		if let download = entry.download {
			switch download.state {
			case .failed: return .red
			case .paused, .pausing: return .orange
			case .processing: return download.waitingForForeground ? .red : .accentColor
			default: return .accentColor
			}
		}
		return .secondary
	}

	var body: some View {
		let status = status
		LibraryRowDetails(
			name: app?.name ?? entry.download?.sourceProvenance?.sourceAppName ?? entry.download?.fileName ?? .localized("Unknown"),
			version: app?.version ?? entry.download?.sourceProvenance?.sourceAppVersion,
			identifier: app?.identifier ?? entry.download?.sourceProvenance?.sourceAppIdentifier,
			secondaryStatus: showsTaskStatus ? nil : status.text,
			isFailed: !showsTaskStatus && status.failed,
			animatesStatus: true,
			thirdLineStatus: showsTaskStatus ? status.text : nil,
			thirdLineAnimationKey: numericProgressPhase ?? status.text,
			showsNumericProgress: numericProgressPhase != nil,
			statusColor: statusColor
		)
		.onChange(of: entry.signature) { _, _ in activity.bind(entry: entry, model: model) }
		.onChange(of: model.map { ObjectIdentifier($0) }) { _, _ in activity.bind(entry: entry, model: model) }
	}
}

private struct UnifiedImportAccessory: View {
	let entry: UnifiedImportEntry
	let model: InstallerStatusViewModel?
	@ObservedObject var controller: UnifiedImportsController
	@StateObject private var activity: UnifiedImportActivity
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	init(entry: UnifiedImportEntry, model: InstallerStatusViewModel?, controller: UnifiedImportsController) {
		self.entry = entry
		self.model = model
		self.controller = controller
		_activity = StateObject(wrappedValue: UnifiedImportActivity(entry: entry, model: model))
	}

	private var stage: String {
		if let operation = entry.operation, !entry.signOnlyCompleted(model: model) { return operation.id.uuidString }
		if let export = entry.export { return "export:" + export.id.uuidString }
		if let download = entry.download { return "download:" + download.id }
		return entry.app?.isSigned == true ? "signed" : "imported"
	}

	var body: some View {
		ZStack(alignment: .trailing) {
			Group {
			if entry.operation != nil, !entry.signOnlyCompleted(model: model) {
				if let model = model {
					if case .broken = model.status {
						Button { AppInstallationManager.shared.retryActiveInstall() } label: {
							InstallationProgressRing(progress: nil, systemImage: "arrow.clockwise")
						}.buttonStyle(.borderless).accessibilityLabel(String.localized("Retry"))
					} else {
						InstallationProgressRing(progress: progress(model), systemImage: model.statusImage)
							.accessibilityLabel(model.statusLabel)
							.accessibilityValue(Text(progress(model), format: .percent.precision(.fractionLength(0))))
					}
				} else { InstallationProgressRing(progress: nil, systemImage: "clock") }
			} else if let export = entry.export { ExportProgressButton(export: export) }
			else if let download = entry.download { DownloadProgressButton(download: download) }
			else if let app = entry.app {
				Button {
					if app.isSigned {
						if AppInstallationManager.shared.startInstall(app: app) { HapticManager.shared.impact() }
					} else { controller.signingApp = AnyApp(base: app) }
				} label: { NBButton(app.isSigned ? .localized("Install") : .localized("Sign"), style: .text) }
				.buttonStyle(.borderless)
			}
		}
			.id(stage)
			.transition(.opacity)
		}
		.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: stage)
		.onChange(of: entry.signature) { _, _ in activity.bind(entry: entry, model: model) }
		.onChange(of: model.map { ObjectIdentifier($0) }) { _, _ in activity.bind(entry: entry, model: model) }
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
			.alert(.localized("Delete All Apps?"), isPresented: $controller.confirmingDeleteAll) {
				Button(.localized("Cancel"), role: .cancel) {}
				Button(.localized("Delete All"), role: .destructive) { controller.deleteAll() }
			} message: { Text(.localized("This removes downloads and signed and unsigned imports. Sideloaded apps are kept.")) }
			.disabled(controller.showsDeletionProgress)
			.overlay {
				if controller.showsDeletionProgress {
					ProgressView(.localized("Deleting…")).padding(24)
						.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
				}
			}
	}
}
