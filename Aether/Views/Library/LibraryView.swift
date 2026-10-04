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
	@State private var _isDeleteAllAlertPresented = false

	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive

	@State private var _searchText = ""
	@State private var _toolbarWidth: CGFloat = 320
	@State private var _isSearchFocused = false
	@ObservedObject private var tabManager = AppTabManager.shared

	@Environment(\.accessibilityReduceMotion) private var _reduceMotion

	private enum LibrarySection: String, Identifiable {
		case exports, downloads, signed, imported
		var id: Self { self }
	}

	@Namespace private var _namespace

	// horror
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
				(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
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

	private var _searchHasNoResults: Bool {
		!_searchText.isEmpty &&
		_filteredSignedApps.isEmpty &&
		_filteredImportedApps.isEmpty &&
		exportManager.exports.isEmpty &&
		downloadManager.downloads.isEmpty
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
		let sections: [LibrarySection] = [
			exportManager.exports.isEmpty ? nil : .exports,
			downloadManager.downloads.isEmpty ? nil : .downloads,
			signedApps.isEmpty ? nil : .signed,
			importedApps.isEmpty ? nil : .imported
		].compactMap { $0 }

		NBNavigationView(.localized("Library"), displayMode: .inline) {
			NBListAdaptable {
				ForEach(sections) { section in
					switch section {
					case .exports:
						NBSection(.localized("Exports")) {
							ForEach(exportManager.exports) { export in
								ExportLibraryCellView(export: export)
							}
						}

					case .downloads:
						NBSection(.localized("Downloads")) {
							ForEach(downloadManager.downloads) { download in
								DownloadLibraryCellView(download: download)
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
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
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
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
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
				} else if _searchHasNoResults {
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
							}
						}
					}

					ToolbarItem(placement: .topBarTrailing) {
						Button(role: .destructive) {
							_bulkDeleteSelectedApps()
						} label: {
							Image(systemName: "trash")
						}
						.disabled(_selectedAppUUIDs.isEmpty)
						.accessibilityLabel(.localized("Delete"))
					}
				}
			}
			.modifier(SearchToolbarModifier(
				text: $_searchText, isPresented: $tabManager.isLibrarySearchPresented,
				focus: $_isSearchFocused, title: .localized("Library"), width: _toolbarWidth,
				enabled: !_editMode.isEditing,
				secondaryAction: { _isImportingPresenting = true }
			) { _titleMenuActions() })

			.environment(\.editMode, $_editMode)
			.onChange(of: tabManager.isLibrarySearchPresented) { presented in
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
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
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
			.alert(.localized("Delete All Apps?"), isPresented: $_isDeleteAllAlertPresented) {
				Button(.localized("Cancel"), role: .cancel) {}
				Button(.localized("Delete All"), role: .destructive) {
					_deleteAllApps()
				}
			} message: {
				Text(.localized("This permanently removes all signed and imported apps from your library."))
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
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

}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}

		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}

		_selectedAppUUIDs.removeAll()

		// _editMode = .inactive
	}

	private func _deleteAllApps() {
		var apps: [AppInfoPresentable] = Array(_signedApps)
		apps.append(contentsOf: Array(_importedApps))

		for app in apps {
			Storage.shared.deleteApp(for: app)
		}

		_selectedAppUUIDs.removeAll()
		_editMode = .inactive
	}

	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		allApps.append(contentsOf: _filteredSignedApps)
		allApps.append(contentsOf: _filteredImportedApps)
		return allApps
	}
}
