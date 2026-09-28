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

	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting

	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive

	@State private var _searchText = ""
	@State private var _isSearchPresented = false
	@State private var _selectedScope: Scope = .all
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
		NBNavigationView("", displayMode: .inline) {
			VStack(spacing: 0) {
				if _isSearchPresented {
					Picker("", selection: $_selectedScope) {
						ForEach(Scope.allCases, id: \.self) { scope in
							Text(scope.displayName).tag(scope)
						}
					}
					.pickerStyle(.segmented)
					.padding(.horizontal)
					.padding(.top, 4)
					.padding(.bottom, 6)
					.transition(.move(edge: .top).combined(with: .opacity))
				}

				NBListAdaptable {
				if !downloadManager.downloads.isEmpty {
					NBSection(
						.localized("Downloads"),
						secondary: downloadManager.downloads.count.description
					) {
						ForEach(downloadManager.downloads) { download in
							DownloadLibraryCellView(download: download)
						}
					}
				}

				if
					!_filteredSignedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Signed"),
						secondary: _filteredSignedApps.count.description
					) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}

				if
					!_filteredImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					NBSection(
						.localized("Imported"),
						secondary: _filteredImportedApps.count.description
					) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
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
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
						} description: {
							Text(.localized("Get started by importing your first IPA file."))
						} actions: {
							Menu {
								_importActions()
							} label: {
								NBButton(.localized("Import"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .principal) {
					HStack(spacing: 8) {
						if _editMode.isEditing {
							Button(.localized("Done")) {
								withAnimation {
									_editMode = .inactive
									_selectedAppUUIDs.removeAll()
								}
							}
							.transition(.opacity)

							Spacer()

							Text(.localized("Library"))
								.font(.headline)
								.lineLimit(1)
								.transition(.opacity)

							Spacer()

							Button(role: .destructive) {
								_bulkDeleteSelectedApps()
							} label: {
								Image(systemName: "trash")
									.font(.system(size: 17, weight: .medium))
									.frame(width: 36, height: 36)
									.contentShape(Rectangle())
							}
							.disabled(_selectedAppUUIDs.isEmpty)
							.accessibilityLabel(.localized("Delete"))
							.transition(.opacity)
						} else {
							HStack(spacing: 8) {
								Image(systemName: "magnifyingglass")
									.font(.system(size: 15, weight: .medium))
									.foregroundColor(_isSearchPresented ? .secondary : .primary)
									.frame(width: 36, height: 36)
								
								if _isSearchPresented {
									TextField(.localized("Search"), text: $_searchText)
										.font(.system(size: 16))
										.focused($_isSearchFocused)
										.textInputAutocapitalization(.never)
										.disableAutocorrection(true)
										.onAppear {
											_isSearchFocused = true
										}
										.transition(.opacity)
									
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
							}
							.frame(height: 36)
							.frame(maxWidth: _isSearchPresented ? .infinity : 36)
							.background(
								_isSearchPresented
									? Color(UIColor.secondarySystemFill)
									: Color.clear,
								in: Capsule()
							)
							.contentShape(Capsule())
							.onTapGesture {
								if !_isSearchPresented {
									withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
										_isSearchPresented = true
									}
								}
							}

							if !_isSearchPresented {
								Spacer()

								Text(.localized("Library"))
									.font(.headline)
									.lineLimit(1)
									.transition(.opacity)

								Spacer()

								Menu {
									_importActions()
								} label: {
									Image(systemName: "plus")
										.font(.system(size: 17, weight: .medium))
										.foregroundColor(.accentColor)
										.frame(width: 36, height: 36)
										.contentShape(Rectangle())
								}
								.transition(.opacity)
							} else {
								Button {
									_isSearchFocused = false
									withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
										_isSearchPresented = false
										_searchText = ""
									}
								} label: {
									Image(systemName: "xmark")
										.font(.system(size: 14, weight: .semibold))
										.foregroundColor(.primary)
										.frame(width: 36, height: 36)
										.background(Color(UIColor.secondarySystemFill), in: Circle())
								}
								.buttonStyle(.plain)
								.transition(.scale.combined(with: .opacity))
								.accessibilityLabel(.localized("Cancel"))
							}
						}
					}
					.frame(width: UIScreen.main.bounds.width - 32)
				}
			}
			.environment(\.editMode, $_editMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
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
					_selectedInstallAppPresenting = AnyApp(base: latest)
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

		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedApps)
		}

		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _filteredImportedApps)
		}

		return allApps
	}

}

// MARK: - Extension: View (Sort)
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported

		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Imported")
			}
		}
	}
}
