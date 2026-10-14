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
	var iconUrl: URL?
	var size: CGFloat = 50
	var isCircle: Bool = false
	
	init(
		title: String,
		subtitle: String,
		iconUrl: URL? = nil,
		size: CGFloat = 50,
		isCircle: Bool = false
	) where Subtitle == Text {
		self.title = title
		self.subtitleView = Text(subtitle)
		self.iconUrl = iconUrl
		self.size = size
		self.isCircle = isCircle
	}
	
	init(
		title: String,
		iconUrl: URL? = nil,
		size: CGFloat = 50,
		isCircle: Bool = false,
		@ViewBuilder subtitle: () -> Subtitle
	) {
		self.title = title
		self.subtitleView = subtitle()
		self.iconUrl = iconUrl
		self.size = size
		self.isCircle = isCircle
	}
	
	// MARK: Body
	var body: some View {
		HStack(spacing: 18) {
			if let iconURL = iconUrl {
				LazyImage(request: ImageRequest(url: iconURL, userInfo: [
					.thumbnailKey: ImageRequest.ThumbnailOptions(maxPixelSize: Float(size * displayScale))
				])) { state in
					if let image = state.image {
						image.appIconStyle(size: size, isCircle: isCircle)
					} else {
						standardIcon
					}
				}
			} else {
				standardIcon
			}
			
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.headline)
					.foregroundColor(.primary)
					.lineLimit(1)
				subtitleView
					.nbFont(.subheadline)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			.padding(.vertical, 2)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
	
	var standardIcon: some View {
		Image("App_Unknown")
			.appIconStyle(size: size, isCircle: isCircle)
	}
}
