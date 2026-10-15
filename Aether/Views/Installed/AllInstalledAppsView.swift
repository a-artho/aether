import SwiftUI
import NimbleViews

/// The device root pushes the collection; individual apps open Info sheets.
enum InstalledAppsRoute: Hashable {
	case allApps
	case updates(String)
}

@MainActor
struct AllInstalledAppsView<Placeholder: View>: View {
	@ObservedObject var store: InstalledAppsStore
	@ObservedObject private var installations = AppInstallationManager.shared
	let loadsIcons: Bool
	let placeholder: Placeholder
	@State private var searchText: String
	@State private var searchPresented: Bool
	@State private var searchFocused = false
	@State private var width: CGFloat = 320
	@State private var isVisible = false
	@State private var selectedInfoApp: InstalledApp?
	@State private var pendingUninstall: InstalledApp?
	@State private var deletingIDs = Set<String>()
	@State private var deletionError: String?

	init(store: InstalledAppsStore, loadsIcons: Bool,
		initialSearch: String, placeholder: Placeholder) {
		self.store = store
		self.loadsIcons = loadsIcons
		self.placeholder = placeholder
		_searchText = State(initialValue: initialSearch)
		_searchPresented = State(initialValue: !initialSearch.isEmpty)
	}

	private var filteredApps: [InstalledApp] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		return store.apps.filter { app in
			query.isEmpty || [app.name, app.bundleIdentifier, app.version, app.build]
				.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
		}
	}

	var body: some View {
		let apps = filteredApps
		List {
			Section {
				ForEach(apps) { app in
					Button {
						searchFocused = false
						HapticManager.shared.impact()
						selectedInfoApp = app
					} label: {
						InstalledAppCellView(app: app, loadsIcon: loadsIcons)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.disabled(deletingIDs.contains(app.id))
					.id(app.id)
					.listRowSeparator(app.id == apps.first?.id ? .hidden : .visible, edges: .top)
					.listRowSeparator(app.id == apps.last?.id ? .hidden : .visible, edges: .bottom)
					.swipeActions(edge: .trailing) {
						// Wait for the device to confirm uninstallation before removing the row.
						Button(String.localized("Uninstall"), systemImage: "trash") {
							searchFocused = false
							pendingUninstall = app
						}
						.tint(.red)
						.disabled(deletingIDs.contains(app.id) || installations.blocksUninstall(bundleIdentifier: app.bundleIdentifier))
					}
				}
			}
			.listSectionSeparator(.hidden)
		}
		.listStyle(.plain)
		.overlay {
			if store.apps.isEmpty { placeholder }
			else if filteredApps.isEmpty {
				TabPlaceholderView(title: .localized("No Results"), description: .localized("Try another search."), systemImage: "magnifyingglass")
			}
		}
		.refreshable { await store.refresh(force: true) }
		.onAppear { isVisible = true }
		.onDisappear { isVisible = false; searchFocused = false }
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
		.modifier(SearchToolbarModifier(text: $searchText, isPresented: $searchPresented,
			focus: $searchFocused, title: .localized("All Apps"), width: width,
			isScreenActive: isVisible && selectedInfoApp == nil && pendingUninstall == nil, hasTitleMenu: false) { EmptyView() })
		.onChange(of: searchPresented) { _, presented in
			if !presented { searchText = ""; searchFocused = false }
		}
		.sheet(item: $selectedInfoApp) { app in
			NBNavigationView(String.localized("Info"), displayMode: .inline) {
				InstalledAppInformationView(app: store.apps.first(where: { $0.id == app.id }) ?? app)
					.toolbar {
						ToolbarItem(placement: .topBarTrailing) {
							Button(String.localized("Close"), systemImage: "xmark") { selectedInfoApp = nil }
								.tint(.primary)
						}
					}
			}
		}
		.onChange(of: store.apps.map(\.id)) { _, ids in
			if let app = selectedInfoApp, !ids.contains(app.id) { selectedInfoApp = nil }
			if let app = pendingUninstall, !ids.contains(app.id) { pendingUninstall = nil }
		}
		.confirmationDialog(String.localized("Uninstall App?"), isPresented: Binding(
			get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }
		), titleVisibility: .visible, presenting: pendingUninstall) { app in
			Button(String.localized("Uninstall"), role: .destructive) {
				pendingUninstall = nil
				Task { await delete(app) }
			}
			.disabled(installations.blocksUninstall(bundleIdentifier: app.bundleIdentifier))
			Button(String.localized("Cancel"), role: .cancel) { pendingUninstall = nil }
		} message: { app in
			Text(String.localized("Uninstall %@ and remove its data?", arguments: app.displayName))
		}
		.alert(String.localized("Couldn’t Uninstall"), isPresented: Binding(
			get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
		)) {
			Button(String.localized("OK"), role: .cancel) {}
		} message: { Text(deletionError ?? "") }
	}

	private func delete(_ app: InstalledApp) async {
		guard deletingIDs.insert(app.id).inserted else { return }
		defer { deletingIDs.remove(app.id) }
		do { try await store.delete(app: app) }
		catch {
			deletionError = error.localizedDescription
			DebugLogManager.shared.log("Uninstall failed for \(app.bundleIdentifier): \(error.localizedDescription)", category: "Device", level: .error)
		}
	}
}
