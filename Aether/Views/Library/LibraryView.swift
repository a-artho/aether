//
//  ContentView.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var exportManager = ExportManager.shared

	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _downloadURLText = ""
	@State private var _isDeleteAllAlertPresented = false
	@State private var _isDeleting = false

	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _selectedDownloadIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive

	@State private var _searchText = ""
	@State private var _toolbarWidth: CGFloat = 320
	@State private var _isSearchFocused = false
	@ObservedObject private var tabManager = AppTabManager.shared

	@Environment(\.accessibilityReduceMotion) private var _reduceMotion

	private var _manualDownloadURL: URL? {
		guard let url = URL(string: _downloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
			let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
			let host = url.host, !host.isEmpty else { return nil }
		return url
	}

	private enum LibrarySection: String, Identifiable {
		case exports, downloads, signed, imported
		var id: Self { self }
	}

	@Namespace private var _namespace

	private func matchesSearch(_ name: String?, identifier: String? = nil) -> Bool {
		_searchText.isEmpty || [name, identifier].compactMap { $0 }.contains {
			$0.localizedCaseInsensitiveContains(_searchText)
		}
	}

	private var _filteredDownloads: [Download] {
		downloadManager.downloads.filter { matchesSearch($0.sourceProvenance?.sourceAppName ?? $0.fileName, identifier: $0.sourceProvenance?.sourceAppIdentifier) }
	}

	private var _filteredExports: [AppExport] {
		exportManager.exports.filter { matchesSearch($0.snapshot.name, identifier: $0.snapshot.identifier) }
	}
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			matchesSearch($0.value(forKey: "name") as? String, identifier: $0.value(forKey: "identifier") as? String)
		}
	}

	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}

	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}

	private var _libraryIsEmpty: Bool {
		exportManager.exports.isEmpty &&
		downloadManager.downloads.isEmpty &&
		_signedApps.isEmpty &&
		_importedApps.isEmpty
	}

	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	// MARK: Body
	var body: some View {
		let signedApps = _filteredSignedApps
		let importedApps = _filteredImportedApps
		let exports = _filteredExports
		let downloads = _filteredDownloads
		let sections: [LibrarySection] = [
			exports.isEmpty ? nil : .exports,
			downloads.isEmpty ? nil : .downloads,
			signedApps.isEmpty ? nil : .signed,
			importedApps.isEmpty ? nil : .imported
		].compactMap { $0 }
		let searchHasNoResults = !_searchText.isEmpty && sections.isEmpty

		NBNavigationView(.localized("Library"), displayMode: .inline) {
			NBListAdaptable {
				ForEach(sections) { section in
					switch section {
					case .exports:
						NBSection(.localized("Exports")) {
							ForEach(exports) { export in
								ExportLibraryCellView(export: export)
							}
						}

					case .downloads:
						NBSection(.localized("Downloads")) {
							ForEach(downloads) { download in
								DownloadLibraryCellView(download: download, selectedDownloadIDs: $_selectedDownloadIDs)
							}
						}

					case .signed:
						NBSection(.localized("Signed")) {
							ForEach(signedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedAppUUIDs: $_selectedAppUUIDs
								)
								.matchedTransitionSource(id: app.uuid ?? "", in: _namespace)
							}
						}

					case .imported:
						NBSection(.localized("Imported")) {
							ForEach(importedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedAppUUIDs: $_selectedAppUUIDs
								)
								.matchedTransitionSource(id: app.uuid ?? "", in: _namespace)
							}
						}
					}
				}
			}
			// Only section membership changes animate the list, never transfer progress.
			.animation(_reduceMotion ? nil : .snappy, value: sections)
			.scrollDismissesKeyboard(.immediately)
			.overlay {
				if _libraryIsEmpty {
					TabPlaceholderView(
						title: .localized("No Apps"),
						description: .localized("Get started by importing your first IPA file."),
						systemImage: "questionmark.app.fill"
					) {
						Button {
							_isImportingPresenting = true
						} label: {
							NBButton(.localized("Import"), style: .text)
						}
						.buttonStyle(.borderless)
					}
					.transition(.opacity.animation(.easeInOut(duration: 0.2)))
				} else if searchHasNoResults {
					TabPlaceholderView(
						title: .localized("No Results"),
						description: .localized("Try another search."),
						systemImage: "magnifyingglass"
					)
					.transition(.opacity.animation(.easeInOut(duration: 0.2)))
				}
			}
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _toolbarWidth = $0 }
			.toolbar {
				if _editMode.isEditing {
					ToolbarItem(placement: .topBarLeading) {
						Button(.localized("Done")) {
							withAnimation {
								_editMode = .inactive
								_selectedAppUUIDs.removeAll()
								_selectedDownloadIDs.removeAll()
							}
						}
					}

					ToolbarItem(placement: .topBarTrailing) {
						Button(role: .destructive) {
							_bulkDeleteSelectedApps()
						} label: {
							Image(systemName: "trash")
						}
						.disabled(_selectedAppUUIDs.isEmpty && _selectedDownloadIDs.isEmpty)
						.accessibilityLabel(.localized("Delete"))
					}
				}
			}
			.modifier(SearchToolbarModifier(
				text: $_searchText, isPresented: $tabManager.isLibrarySearchPresented,
				focus: $_isSearchFocused, title: .localized("Library"), width: _toolbarWidth,
				enabled: !_editMode.isEditing,
				secondaryAction: { _isImportingPresenting = true },
				secondaryURLAction: { _downloadURLText = ""; _isDownloadingPresenting = true }
			) { _titleMenuActions() })

			.environment(\.editMode, $_editMode)
			.onChange(of: tabManager.isLibrarySearchPresented) { _, presented in
				if !presented {
					_isSearchFocused = false
					_searchText = ""
				}
			}
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.navigationTransition(.zoom(sourceID: app.base.uuid ?? "", in: _namespace))
			}
			.sheet(isPresented: $_isImportingPresenting) {
				LibraryImportPickerView(
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }

						for url in urls {
							let id = "AetherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							downloadManager.retryProcessing(dl)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_downloadURLText)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
				Button(.localized("Cancel"), role: .cancel) { _downloadURLText = "" }
				Button(.localized("Download")) {
					guard let url = _manualDownloadURL else { return }
					_downloadURLText = ""
					Task { _ = await downloadManager.startDownload(from: url, id: "AetherManualDownload_\(UUID().uuidString)") }
				}
				.disabled(_manualDownloadURL == nil)
			} message: {
				Text(.localized("Enter a direct HTTP or HTTPS link to an IPA file."))
			}
			.alert(.localized("Delete All Apps?"), isPresented: $_isDeleteAllAlertPresented) {
				Button(.localized("Cancel"), role: .cancel) {}
				Button(.localized("Delete All"), role: .destructive) {
					_deleteAllApps()
				}
			} message: {
				Text(.localized("This permanently removes all signed and imported apps from your library."))
			}
			.onChange(of: downloadManager.downloads.map(\.id)) { _, ids in
				// Completed or otherwise removed transfers cannot remain selected.
				_selectedDownloadIDs.formIntersection(ids)
			}
			.onChange(of: _editMode) { _, mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
					_selectedDownloadIDs.removeAll()
				}
			}
			.onAppear { _consumeLibraryAction() }
			.onChange(of: tabManager.requestedLibraryAction) { _, _ in _consumeLibraryAction() }
		}
		.disabled(_isDeleting)
		.overlay {
			if _isDeleting {
				ZStack {
					Color.black.opacity(0.15).ignoresSafeArea()
					ProgressView(.localized("Deleting…"))
						.padding(24)
						.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
				}
			}
		}
	}
	@ViewBuilder
	private func _titleMenuActions() -> some View {
		Button {
			withAnimation { _editMode = .active }
		} label: {
			Label(.localized("Select"), systemImage: "checkmark.circle")
		}
		Divider()
		Button(role: .destructive) {
			_isDeleteAllAlertPresented = true
		} label: {
			Label(.localized("Delete All"), systemImage: "trash")
		}
		.disabled(_signedApps.isEmpty && _importedApps.isEmpty)
	}

	private func _consumeLibraryAction() {
		guard let action = tabManager.requestedLibraryAction else { return }
		tabManager.requestedLibraryAction = nil
		switch action {
		case .select: withAnimation { _editMode = .active }
		case .deleteAll: _isDeleteAllAlertPresented = true
		}
	}

}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}

		let selectedDownloads = downloadManager.downloads.filter { _selectedDownloadIDs.contains($0.id) }
		_deleteAvailableApps(selectedApps, downloads: selectedDownloads, leaveEditing: false)
	}

	private func _deleteAllApps() {
		_deleteAvailableApps(_getAllApps(), downloads: [], leaveEditing: true)
	}

	@MainActor
	private func _deleteAvailableApps(_ apps: [AppInfoPresentable], downloads: [Download], leaveEditing: Bool) {
		guard !_isDeleting else { return }
		// Snapshot before deleting: fetched managed objects change as each row is removed.
		let snapshots = apps.map { AppSnapshot($0) }
		_isDeleting = true
		Task { @MainActor in
			defer { _isDeleting = false }
			// Give SwiftUI a chance to display the loading state before starting work.
			await Task.yield()
			for download in downloads {
				downloadManager.deleteDownload(download)
				await Task.yield()
			}
			var retained = false
			for app in snapshots {
				if !(await Storage.shared.deleteAppAsync(for: app)) { retained = true }
				await Task.yield()
			}
			_selectedAppUUIDs.removeAll()
			_selectedDownloadIDs.removeAll()
			if leaveEditing { _editMode = .inactive }
			if retained {
				UIAlertController.showAlertWithOk(title: .localized("Apps In Use"), message: .localized("Apps required by an installation or update were kept. Cancel those operations before deleting them."))
			}
		}
	}

	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		allApps.append(contentsOf: Array(_signedApps))
		allApps.append(contentsOf: Array(_importedApps))
		return allApps
	}
}
