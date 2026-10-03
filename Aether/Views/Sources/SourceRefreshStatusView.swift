import SwiftUI

/// The timestamp represents the last successful check of all configured sources.
struct SourceRefreshStatusView: View {
	let lastUpdated: Date?
	let isRefreshing: Bool
	let hasFailures: Bool

	var body: some View {
		TimelineView(.periodic(from: .now, by: 60)) { context in
			Text(status(at: context.date))
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}

	private func status(at now: Date) -> String {
		if isRefreshing { return .localized("Updating…") }
		if hasFailures { return .localized("Refresh incomplete") }
		guard let lastUpdated else { return .localized("Not updated yet") }
		if now.timeIntervalSince(lastUpdated) < 60 { return .localized("Updated now") }
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return .localized("Updated %@", arguments: formatter.localizedString(for: lastUpdated, relativeTo: now))
	}
}
