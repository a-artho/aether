//
//  ContentView.swift
//  Feather
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
	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting

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
				if
					downloadManager.downloads.isEmpty,
					_filteredSignedApps.isEmpty,
					_filteredImportedApps.isEmpty
				{
					TabPlaceholderView(
						title: .localized("No Apps"),
						description: .localized("Get started by importing your first IPA file."),
						systemImage: "questionmark.app.fill"
					) {
						Menu {
							_importActions()
						} label: {
							NBButton(.localized("Import"), style: .text)
						}
						.buttonStyle(.borderless)
					}
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
						.frame(width: min(500, UIScreen.main.bounds.width - 74))
						.background(Color(UIColor.secondarySystemFill), in: Capsule())
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
						Menu {
							_importActions()
						} label: {
							Image(systemName: "plus")
						}
						.accessibilityLabel(.localized("Add"))
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.animation(.spring(response: 0.35, dampingFraction: 0.82), value: _isSearchPresented)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					initialDirectory: URL.downloadsDirectory,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }

						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							downloadManager.retryProcessing(dl)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				if let latest = _signedApps.first {
					AppInstallationManager.shared.startInstall(app: latest)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openSearch"))) { _ in
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.closeSearch"))) { _ in
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

// MARK: - Extension: View
extension LibraryView {
	@ViewBuilder
	private func _importActions() -> some View {
		Button(.localized("Import from Files"), systemImage: "folder") {
			_isImportingPresenting = true
		}
		Button(.localized("Import from URL"), systemImage: "globe") {
			_isDownloadingPresenting = true
		}
		Divider()
		Button(.localized("Edit Library"), systemImage: "pencil") {
			withAnimation {
				_editMode = .active
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

	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		allApps.append(contentsOf: _filteredSignedApps)
		allApps.append(contentsOf: _filteredImportedApps)
		return allApps
	}
}
