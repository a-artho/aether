import SwiftUI
import AltSourceKit

/// Restores an existing source after cache eviction while retaining the exact
/// selected app variant. Deleted sources are handled by the router destination.
struct SourceAppDestinationView: View {
	@ObservedObject var source: AltSource
	let app: ASRepository.App
	@ObservedObject var viewModel: SourcesViewModel
	@State private var completedLoadKey: String?
	@State private var attempt = 0

	private var loadKey: String {
		"\(source.objectID.uriRepresentation())|\(viewModel.cacheGeneration)|\(attempt)"
	}

	var body: some View {
		Group {
			if source.isDeleted || source.managedObjectContext == nil {
				TabPlaceholderView(title: .localized("Source Unavailable"),
					description: .localized("This source is no longer available."),
					systemImage: "exclamationmark.triangle")
			} else if let repository = viewModel.repository(for: source) {
				SourceAppsDetailView(sourceURL: source.sourceURL, source: repository, app: app)
			} else if completedLoadKey == loadKey {
				let key = source.objectID.uriRepresentation().absoluteString
				TabPlaceholderView(title: .localized("Unable to Load Repo"),
					description: viewModel.refreshErrors[key] ?? .localized("Unable to load this repo. Try again."),
					systemImage: "exclamationmark.triangle") {
					Button { attempt += 1 } label: { Text(.localized("Retry")) }
				}
			} else {
				ProgressView()
			}
		}
		.navigationTitle(app.currentName)
		.navigationBarTitleDisplayMode(.inline)
		.task(id: loadKey) {
			guard !source.isDeleted, source.managedObjectContext != nil,
				viewModel.repository(for: source) == nil else { return }
			let key = loadKey
			await viewModel.ensureSourcesLoaded([source])
			guard !Task.isCancelled, key == loadKey else { return }
			completedLoadKey = key
		}
	}
}
