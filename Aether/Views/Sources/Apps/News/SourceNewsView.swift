//
//  SourceNewsView.swift
//  Aether
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews

// MARK: - View
struct SourceNewsView: View {
	@State var isLoading = true
	@State var hasLoadedInitialData = false

	@State private var _selectedNewsPresenting: ASRepository.News?

	@Namespace private var _namespace

	var news: [ASRepository.News]?

	// MARK: Body
	var body: some View {
		Group {
			if
				let news,
				!news.isEmpty
			{
				ScrollView(.horizontal, showsIndicators: false) {
					LazyHStack(spacing: 10) {
						ForEach(news.reversed(), id: \.id) { new in
							Button {
								_selectedNewsPresenting = new
							} label: {
								SourceNewsCardView(new: new)
									.matchedTransitionSource(id: new.id, in: _namespace)
							}
						}
					}
					.padding(.horizontal, 16)
				}
				.frame(height: 150)
				.opacity(isLoading ? 0 : 1)
				.transition(.opacity)
			}
		}
		.onAppear {
			if !hasLoadedInitialData && news?.isEmpty == false {
				_load()
				hasLoadedInitialData = true
			}
		}
		.fullScreenCover(item: $_selectedNewsPresenting) { new in
			SourceNewsCardInfoView(new: new)
				.navigationTransition(.zoom(sourceID: new.id, in: _namespace))
		}
	}

	private func _load() {
		withAnimation(.easeIn(duration: 0.3)) {
			isLoading = false
		}
	}
}
