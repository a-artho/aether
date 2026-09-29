//
//  SpoofingFeatureView.swift
//  Feather
//

import SwiftUI

/// Feather's host for the Locus-inspired location spoofing experience.
/// Its state intentionally lives for one pushed presentation, while pairing
/// and tunnel readiness remain owned by Feather's shared device services.
@available(iOS 17.0, *)
struct SpoofingFeatureView: View {
	@StateObject private var session = SpoofSession()

	var body: some View {
		SpoofingRootView()
			.environmentObject(session)
			.navigationBarBackButtonHidden()
			.toolbar(.hidden, for: .navigationBar)
			.ignoresSafeArea()
	}
}

struct SpoofingEntryView: View {
	var body: some View {
		Group {
			if #available(iOS 17.0, *) {
				SpoofingFeatureView()
			} else {
				VStack(spacing: 12) {
					Image(systemName: "location.slash")
						.font(.largeTitle)
						.foregroundStyle(.secondary)
					Text("Spoofing Requires iOS 17")
						.font(.headline)
					Text("Update this device to use Feather’s map and location controls.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.padding(24)
			}
		}
	}
}
