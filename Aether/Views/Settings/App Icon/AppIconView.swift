//
//  AppIconView.swift
//  Aether
//
//  Created by samara on 19.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View extension: Model
extension AppIconView {
	struct AltIcon: Identifiable {
		var displayName: String
		var author: String
		var key: String?
		var image: UIImage
		var id: String { key ?? displayName }
		
		@MainActor
		init(displayName: String, author: String, key: String? = nil, previewImageName: String? = nil) {
			self.displayName = displayName
			self.author = author
			self.key = key
			self.image = previewImageName.flatMap { UIImage(named: $0) } ?? altImage(key)
		}
	}
	
	static func altImage(_ name: String?) -> UIImage {
		let path = Bundle.main.bundleURL.appendingPathComponent((name ?? "AppIcon60x60") + "@2x.png")
		return UIImage(contentsOfFile: path.path) ?? UIImage()
	}
}

// MARK: - View
struct AppIconView: View {
	@Binding var currentIcon: String?
	@State private var changingIcon = false
	@State private var iconError: String?
	
	// dont translate
	@MainActor private static let sections: [String: [AltIcon]] = [
		"Aether": [
			AltIcon(displayName: "Aether", author: "Artho", key: nil),
			AltIcon(displayName: "Aether Glass", author: "Artho", key: "AetherGlassMuted", previewImageName: "AetherGlassMutedPreview")
		],
		"Feather": [
			AltIcon(displayName: "Feather (macOS)", author: "Samara", key: "V2Mac"),
			AltIcon(displayName: "Feather v1", author: "Samara", key: "V1")
		]
	]
	@MainActor private static let sectionOrder = ["Aether", "Feather"]
	@MainActor private static let supportedAlternateIconNames: Set<String> = [
		"AetherGlassMuted", "V2Mac", "V1"
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("App Icon")) {
			ForEach(Self.sectionOrder, id: \.self) { section in
				if let icons = Self.sections[section] {
					NBSection(section) {
						ForEach(icons) { icon in
							_icon(icon: icon)
						}
					}
				}
			}
		}
		.alert(String.localized("Could Not Change Icon"), isPresented: Binding(get: { iconError != nil }, set: { if !$0 { iconError = nil } })) {
			Button(String.localized("OK"), role: .cancel) {}
		} message: { Text(iconError ?? "") }
		.onAppear {
			let activeIcon = UIApplication.shared.alternateIconName
			guard let activeIcon, !Self.supportedAlternateIconNames.contains(activeIcon) else {
				currentIcon = activeIcon
				return
			}

			// If an older build left a now-removed alternate icon active, return to
			// the primary Aether icon when the user opens this picker.
			changingIcon = true
			UIApplication.shared.setAlternateIconName(nil) { error in
				DispatchQueue.main.async {
					changingIcon = false
					if let error {
						iconError = error.localizedDescription
						DebugLogManager.shared.log("Removed app icon reset failed: \(error.localizedDescription)", category: "Appearance", level: .error)
					} else {
						currentIcon = nil
					}
				}
			}
		}
	}
}

// MARK: - View extension
extension AppIconView {
	@ViewBuilder
	private func _icon(
		icon: AppIconView.AltIcon
	) -> some View {
		Button {
			guard !changingIcon else { return }
			changingIcon = true
			let selectedIcon = icon.key
			UIApplication.shared.setAlternateIconName(selectedIcon) { error in
				DispatchQueue.main.async {
					changingIcon = false
					if let error {
						iconError = error.localizedDescription
						DebugLogManager.shared.log("App icon change failed: \(error.localizedDescription)", category: "Appearance", level: .error)
					}
					// UIKit may not have refreshed alternateIconName when its completion
					// runs. The successfully requested key is the source of truth here.
					currentIcon = error == nil ? selectedIcon : UIApplication.shared.alternateIconName
				}
			}
		} label: {
			HStack(spacing: 18) {
				Image(uiImage: icon.image)
					.appIconStyle()
				
				NBTitleWithSubtitleView(
					title: icon.displayName,
					subtitle: icon.author,
					linelimit: 0
				)
				
				if currentIcon == icon.key {
					Image(systemName: "checkmark").bold()
				}
			}
		}.disabled(changingIcon)
	}
}
