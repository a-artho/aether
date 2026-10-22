import SwiftUI
import AltSourceKit

/// Uses the repository table unchanged for rows and pinned date groups.
struct InstalledAppUpdatesView: View {
	let contexts: [SourceAppCatalogContext]
	// Subset projections must not replace the full repository's cached projection.
	private let listStore = SourceAppListStore.updates
	@State private var selectedUpdate: SelectedUpdate?

	private struct SelectedUpdate {
		let sourceURL: URL?
		let repository: ASRepository
		let app: ASRepository.App
	}

	var body: some View {
		ZStack {
			if contexts.contains(where: { !$0.repository.apps.isEmpty }) {
				SourceAppsTableRepresentableView(sourceContexts: contexts, searchText: .constant(""),
					sortOption: .constant(.latest), sortAscending: false, showSourceBadge: true, listStore: listStore) { selection in
						guard let context = contexts.first(where: { $0.sourceObjectURI == selection.sourceObjectURI }) else { return }
						var repository = context.repository
						repository.apps = []
						selectedUpdate = SelectedUpdate(sourceURL: context.sourceURL, repository: repository,
							app: selection.appLocator.app)
					}
					.ignoresSafeArea()
			} else {
				TabPlaceholderView(title: .localized("No Updates Available"),
					description: .localized("No newer versions were found in your added sources."), systemImage: "arrow.triangle.2.circlepath")
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.navigationTitle(String.localized("Newer Versions"))
		.navigationBarTitleDisplayMode(.inline)
		.navigationDestination(isPresented: Binding(
			get: { selectedUpdate != nil }, set: { if !$0 { selectedUpdate = nil } }
		)) {
			if let update = selectedUpdate {
				SourceAppsDetailView(sourceURL: update.sourceURL, source: update.repository, app: update.app)
			}
		}
	}
}
