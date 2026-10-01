//
//  SpoofingFeatureView.swift
//  Aether
//

import SwiftUI

/// Aether's host for the Locus-inspired location spoofing experience.
/// Its state intentionally lives for one pushed presentation, while pairing
/// and tunnel readiness remain owned by Aether's shared device services.
struct SpoofingFeatureView: View {
	@StateObject private var session = SpoofSession()

	var body: some View {
		SpoofingRootView()
			.environmentObject(session)
			.navigationBarBackButtonHidden()
			.toolbar(.hidden, for: .navigationBar)
	}
}

struct SpoofingEntryView: View {
	var body: some View {
		SpoofingFeatureView()
	}
}
