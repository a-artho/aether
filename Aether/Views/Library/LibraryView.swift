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
	@State private var _isSearchPresented = false
	@FocusState private var _isSearchFocused: Bool


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
		NBNavigationView(_isSearchPresented ? "" : .localized("Library"), displayMode: .inline) {
			NBListAdaptable {
				if !exportManager.exports.isEmpty {
					NBSection(.localized("Exports")) {
						ForEach(exportManager.exports) { export in
							ExportLibraryCellView(export: export)
						}
					}
				}

				if !downloadManager.downloads.isEmpty {
					NBSection(.localized("Downloads")) {
						ForEach(downloadManager.downloads) { download in
							DownloadLibraryCellView(download: download)
						}
					}
				}

				if !_filteredSignedApps.isEmpty {
					NBSection(.localized("Signed")) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
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

				if !_filteredImportedApps.isEmpty {
					NBSection(.localized("Imported")) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
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
			.scrollDismissesKeyboard(.interactively)
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
				} else if _isSearchPresented {
					ToolbarItem(placement: .principal) {
						HStack(spacing: 8) {
							Image(systemName: "magnifyingglass")
								.font(.system(size: 15, weight: .semibold))
								.foregroundColor(.secondary)
								.padding(.leading, 12)
							
							TextField(.localized("Search"), text: $_searchText)
								.font(.system(size: 16))
								.focused($_isSearchFocused)
								.textInputAutocapitalization(.never)
								.disableAutocorrection(true)
								.onAppear {
									_isSearchFocused = true
								}
							
							if !_searchText.isEmpty {
								Button {
									_searchText = ""
								} label: {
									Image(systemName: "xmark.circle.fill")
										.font(.system(size: 14))
										.foregroundColor(.secondary)
								}
								.buttonStyle(.plain)
								.padding(.trailing, 8)
							}
						}
						.frame(height: 36)
						.frame(maxWidth: 500)
						.background {
							Color.clear
								.glassEffect(.regular, in: .capsule)
						}
					}

					ToolbarItem(placement: .topBarTrailing) {
						Button {
							_isSearchFocused = false
							withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
								_isSearchPresented = false
								_searchText = ""
							}
						} label: {
							Image(systemName: "xmark")
						}
						.accessibilityLabel(.localized("Cancel"))
					}
				} else {
					ToolbarItem(placement: .topBarLeading) {
						Button {
							withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
								_isSearchPresented = true
							}
						} label: {
							Image(systemName: "magnifyingglass")
						}
						.accessibilityLabel(.localized("Search"))
					}

					ToolbarItem(placement: .topBarTrailing) {
						Button {
							_isImportingPresenting = true
						} label: {
							Image(systemName: "plus")
						}
						.accessibilityLabel(.localized("Add"))
					}

					ToolbarTitleMenu {
						Button {
							withAnimation {
								_editMode = .active
							}
						} label: {
							Label {
								Text(.localized("Select"))
							} icon: {
								Image(systemName: "checkmark.circle")
							}
						}

						Divider()

						Button(role: .destructive) {
							_isDeleteAllAlertPresented = true
						} label: {
							Label {
								Text(.localized("Delete All"))
							} icon: {
								Image(systemName: "trash")
							}
						}
						.disabled(_signedApps.isEmpty && _importedApps.isEmpty)
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.animation(.spring(response: 0.35, dampingFraction: 0.82), value: _isSearchPresented)
			.animation(.snappy(duration: 0.25), value: _searchText)
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openSearch"))) { _ in
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.closeSearch"))) { _ in
				_isSearchFocused = false
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = false
					_searchText = ""
				}
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
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
