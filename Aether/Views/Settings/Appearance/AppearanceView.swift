//
//  AppearanceView.swift
//  Aether
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
// dear god help me
struct AppearanceView: View {
	@AppStorage("Aether.settingsPlacement") private var _settingsPlacement: SettingsPlacement = .header
	@AppStorage("Aether.userInterfaceStyle")
	private var _userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

	@AppStorage("Aether.shouldTintIcons")
	private var _shouldTintIcons: Bool = false

	@AppStorage("Aether.hideTabBarLabels")
	private var _hideTabBarLabels: Bool = false

	@AppStorage("Aether.searchPlacement")
	private var _searchPlacement: SearchPlacement = .right
	@AppStorage("Aether.hideTitleSearchIcon")
	private var _hideTitleSearchIcon = false

	@AppStorage("Aether.controlsInHeader")
	private var _controlsInHeader: Bool = false

	@AppStorage("Aether.liquidGlassTiles")
	private var _liquidGlassTiles: Bool = true

	@AppStorage("Aether.shouldChangeIconsBasedOffStyle")
	private var _shouldChangeIconsBasedOffStyle: Bool = false

	@AppStorage("Aether.showRepoDownloadButtons")
	private var _showRepoDownloadButtons = true

	@AppStorage("Aether.storeCellAppearance")
	private var _storeCellAppearance: Int = 0
	private let _storeCellAppearanceMethods: [(name: String, desc: String)] = [
		(.localized("Standard"), .localized("Default style for the app, only includes subtitle.")),
		(.localized("Big Description"), .localized("Adds the localized description of the app."))
	]

	@AppStorage("Aether.userTintColor")
	private var _selectedColorHex: String = "#848ef9"

	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName

	private var _tintColorBinding: Binding<Color> {
		Binding(
			get: { Color(hex: _selectedColorHex) },
			set: { _selectedColorHex = $0.toHex() }
		)
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Appearance")) {
			Section {
				Picker(.localized("Appearance"), selection: $_userInterfaceStyle) {
					ForEach(UIUserInterfaceStyle.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { style in
						Text(style.label).tag(style.rawValue)
					}
				}
				.pickerStyle(.segmented)
			}

			NBSection(.localized("Theme")) {
				AppearanceTintColorView()
					.listRowInsets(EdgeInsets())
					.listRowBackground(EmptyView())
			}

			Section {
				ColorPicker(selection: _tintColorBinding, supportsOpacity: false) {
					SettingsRowLabel(.localized("Custom Theme Color"), systemImage: "eyedropper.halffull", backgroundColor: .blue)
				}
			}

			Section {
				NavigationLink(destination: AppIconView(currentIcon: $_currentIcon)) {
					SettingsRowLabel(.localized("App Icon"), systemImage: "app.badge.fill", backgroundColor: .indigo)
				}
			}

			NBSection(.localized("Tab Bar")) {
				Toggle(isOn: $_hideTabBarLabels) {
					SettingsRowLabel(.localized("Hide Labels"), systemImage: "rectangle.bottomthird.inset.filled", backgroundColor: .blue)
				}
			} footer: {
				Text(.localized("Show only icons in the bottom tab bar."))
			}

			NBSection(.localized("Navigation")) {
				Picker(selection: $_settingsPlacement) {
					ForEach(SettingsPlacement.allCases) { placement in
						Text(placement.label).tag(placement)
					}
				} label: {
					SettingsRowLabel(String.localized("Settings Placement"), systemImage: "gearshape", backgroundColor: .gray)
				}
				.pickerStyle(.menu)
				.tint(.secondary)

				Picker(selection: $_searchPlacement) {
					ForEach(SearchPlacement.allCases) { placement in
						Text(placement.label).tag(placement)
					}
				} label: {
					SettingsRowLabel(.localized("Search Placement"), systemImage: "magnifyingglass", backgroundColor: .blue)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
				if _searchPlacement == .pageTitle {
					Toggle(isOn: $_hideTitleSearchIcon) {
						SettingsRowLabel(.localized("Hide Search Icon"), systemImage: "magnifyingglass", backgroundColor: .blue)
					}
				}
			} footer: {
				Text(.localized("Choose where Settings and search controls appear. Hold Settings for installation mode, selection, and deletion options."))
			}

			NBSection(.localized("Device Controls")) {
				Toggle(isOn: $_controlsInHeader) {
					SettingsRowLabel(.localized("Controls in Header"), systemImage: "rectangle.topthird.inset.filled", backgroundColor: .blue)
				}
				Toggle(isOn: $_liquidGlassTiles) {
					SettingsRowLabel(.localized("Liquid Glass Tiles"), systemImage: "square.grid.2x2.fill", backgroundColor: .cyan)
				}
				.disabled(_controlsInHeader)
			} footer: {
				Text(.localized("Move device controls into the header. Liquid Glass Tiles applies when controls are shown as tiles."))
			}

			NBSection(.localized("Library")) {
				Toggle(isOn: $_shouldChangeIconsBasedOffStyle) {
					SettingsRowLabel(.localized("Dynamic Icons"), systemImage: "app.badge.fill", backgroundColor: .indigo)
				}
				Toggle(isOn: $_shouldTintIcons) {
					SettingsRowLabel(.localized("Tinted Icons"), systemImage: "paintpalette.fill", backgroundColor: .purple)
				}
			}

			NBSection(.localized("Sources")) {
				Toggle(isOn: $_showRepoDownloadButtons) {
					SettingsRowLabel(.localized("Show Download Buttons"), systemImage: "icloud.and.arrow.down", backgroundColor: .blue)
				}
				Picker(.localized("Store Cell Appearance"), selection: $_storeCellAppearance) {
					ForEach(0..<_storeCellAppearanceMethods.count, id: \.self) { index in
						let method = _storeCellAppearanceMethods[index]
						NBTitleWithSubtitleView(
							title: method.name,
							subtitle: method.desc
						)
						.tag(index)
					}

				}
				.labelsHidden()
				.pickerStyle(.inline)
			}

			Section {
				Picker(selection: Binding(
					get: { HapticManager.shared.currentStrength },
					set: { newValue in
						UserDefaults.standard.set(newValue.rawValue, forKey: HapticManager.preferenceKey)
						HapticManager.shared.impact(newValue)
					}
				)) {
					ForEach(HapticStrength.allCases) { strength in
						Text(strength.title).tag(strength)
					}
				} label: {
					SettingsRowLabel(
						.localized("Haptics"),
						systemImage: "waveform",
						backgroundColor: .pink
					)
				}
			}
		}
		.onChange(of: _userInterfaceStyle) { _, value in
			if let style = UIUserInterfaceStyle(rawValue: value) {
				for scene in UIApplication.shared.connectedScenes {
					if let windowScene = scene as? UIWindowScene {
						for window in windowScene.windows {
							window.overrideUserInterfaceStyle = style
						}
					}
				}
			}
		}
	}
}
