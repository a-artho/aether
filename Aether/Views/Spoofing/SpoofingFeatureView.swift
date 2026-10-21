//
//  SpoofingFeatureView.swift
//  Aether
//

import SwiftUI

/// Aether's host for the Locus-inspired location spoofing experience.
/// The shared session outlives map presentation while spoofing is active;
/// pairing and tunnel readiness remain owned by Aether's shared device services.
struct SpoofingFeatureView: View {
	@StateObject private var session = SpoofSession.shared

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
