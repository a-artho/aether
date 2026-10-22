//
//  FRIconCellView.swift
//  NimbleKit
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import Nuke
import NukeUI
import NimbleViews

// MARK: - View
struct FRIconCellView<Subtitle: View>: View {
	@Environment(\.displayScale) private var displayScale
	var title: String
	var subtitleView: Subtitle
	var badgeURL: URL? = nil
	var iconUrl: URL?
	var size: CGFloat = 50
	var isCircle: Bool = false
	
	init(
		title: String,
		subtitle: String,
		iconUrl: URL? = nil,
		badgeURL: URL? = nil,
		size: CGFloat = 50,
		isCircle: Bool = false
	) where Subtitle == Text {
		self.title = title
		self.subtitleView = Text(subtitle)
		self.iconUrl = iconUrl
		self.badgeURL = badgeURL
		self.size = size
		self.isCircle = isCircle
	}
	
	init(
		title: String,
		iconUrl: URL? = nil,
		badgeURL: URL? = nil,
		size: CGFloat = 50,
		isCircle: Bool = false,
		@ViewBuilder subtitle: () -> Subtitle
	) {
		self.title = title
		self.subtitleView = subtitle()
		self.iconUrl = iconUrl
		self.badgeURL = badgeURL
		self.size = size
		self.isCircle = isCircle
	}
	
	// MARK: Body
	var body: some View {
		HStack(spacing: 18) {
			Group {
			if let iconURL = iconUrl {
				LazyImage(request: ImageRequest(url: iconURL, userInfo: [
					.thumbnailKey: ImageRequest.ThumbnailOptions(maxPixelSize: Float(size * displayScale))
				])) { state in
					if let image = state.image {
						image.appIconStyle(size: size, isCircle: isCircle)
					} else {
						AppIconSkeleton(size: size, isCircle: isCircle, isLoading: state.isLoading)
					}
				}
			} else {
				standardIcon
			}
			
            }
            .overlay(alignment: .bottomTrailing) {
                if let badgeURL {
                    LazyImage(url: badgeURL) { state in
                        if let image = state.image {
                            image.appIconStyle(size: 18, isCircle: true, background: Color(uiColor: .secondarySystemBackground))
                                .offset(x: 4, y: 4)
                        }
                    }.processors([.resize(width: 18 * displayScale)])
                    .frame(width: 18, height: 18)
                }
            }
			VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
				Text(title)
					.nbRowTitle()
					.foregroundColor(.primary)
					.lineLimit(1)
				subtitleView
					.nbRowSubtitle()
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			.padding(.vertical, 2)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
	
	var standardIcon: some View {
		AppIconSkeleton(size: size, isCircle: isCircle, isLoading: false)
	}
}

/// Loading feedback stays local to visible icons; no timers or row-wide animation.
struct AppIconSkeleton: View {
	let size: CGFloat
	var isCircle = false
	var isLoading = true
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.scenePhase) private var scenePhase
	@State private var isVisible = false

	private var shape: some View {
		RoundedRectangle(cornerRadius: isCircle ? size / 2 : size * 0.2677, style: .continuous)
			.fill(Color(uiColor: .tertiarySystemFill))
			.frame(width: size, height: size)
	}

	var body: some View {
		Group {
			if isLoading && isVisible && scenePhase == .active && !reduceMotion {
				shape.phaseAnimator([false, true]) { content, dimmed in
					content.opacity(dimmed ? 0.5 : 1)
				} animation: { _ in .easeInOut(duration: 1) }
			} else { shape }
		}
		.accessibilityHidden(true)
		.onAppear { isVisible = true }
		.onDisappear { isVisible = false }
	}
}
