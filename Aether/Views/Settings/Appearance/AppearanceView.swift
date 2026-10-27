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
	@AppStorage("Aether.rowHorizontalInset") private var _rowHorizontalInset: RowHorizontalInset = .standard
	@AppStorage("Aether.rowIconSize") private var _rowIconSize: RowIconSize = .standard
	@AppStorage("Aether.allReposIcon") private var _allReposIcon: AllReposIcon = .appStore
	@AppStorage("Aether.overviewIconStyle") private var _overviewIconStyle: OverviewIconStyle = .standalone
	@AppStorage("Aether.launchTab") private var _launchTab: LaunchTab = .sources
	@AppStorage("Aether.settingsRowIconStyle") private var _settingsRowIconStyle: SettingsRowIconStyle = .colored
	@AppStorage("Aether.deviceControlsStyle") private var _deviceControlsStyle: DeviceControlsStyle = .standard
	@AppStorage("Aether.actionButtonStyle") private var _actionButtonSurfaceStyle: NBButtonSurfaceStyle = .standard
	@AppStorage("Aether.ambientBackgroundEnabled") private var _ambientBackgroundEnabled = false
	@AppStorage("Aether.ambientBackgroundVerticalReach") private var _ambientBackgroundVerticalReach = 0.0
	@AppStorage("Aether.mutedSectionHeaders") private var _mutedSectionHeaders = false
	@AppStorage("Aether.userInterfaceStyle")
	private var _userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

	@AppStorage("Aether.shouldTintIcons")
	private var _shouldTintIcons: Bool = false

	@AppStorage("Aether.searchPlacement")
	private var _searchPlacement: SearchPlacement = .right
	@AppStorage("Aether.pageTitlePlacement") private var _pageTitlePlacement: RootPageTitlePlacement = .center
	@AppStorage("Aether.boldPageAndSectionTitles") private var _boldPageAndSectionTitles = false
	@AppStorage("Aether.statusUnderPageTitle") private var _statusUnderPageTitle = false
	@AppStorage("Aether.mutedPageTitles") private var _mutedPageTitles = false

	@AppStorage("Aether.shouldChangeIconsBasedOffStyle")
	private var _shouldChangeIconsBasedOffStyle: Bool = false

	@AppStorage("Aether.showRepoDownloadButtons")
	private var _showRepoDownloadButtons = true

	@AppStorage("Aether.storeCellAppearance")
	private var _storeCellAppearance: Int = 0
	private let _storeCellAppearanceOptions = [
		.localized("Standard"),
		.localized("Large")
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

			NBSection(.localized("Background")) {
				Toggle(isOn: $_ambientBackgroundEnabled) {
					SettingsRowLabel(.localized("Ambient Background"), systemImage: "circle.lefthalf.filled", backgroundColor: .indigo)
				}
				Slider(value: $_ambientBackgroundVerticalReach, in: 0...1) {
					SettingsRowLabel(.localized("Glow Reach"), systemImage: "sun.max", backgroundColor: .orange)
				}
				.disabled(!_ambientBackgroundEnabled)
			} footer: {
				Text(.localized("Adds a subtle theme-colored glow in dark mode. Adjust Glow Reach to extend the top glow toward the bottom of the screen."))
			}

			NBSection(.localized("Settings")) {
				Picker(selection: $_settingsRowIconStyle) {
					ForEach(SettingsRowIconStyle.allCases) { style in
						Text(style.title).tag(style)
					}
				} label: {
					SettingsRowLabel(.localized("Row Icons"), systemImage: "square.grid.2x2", backgroundColor: .blue)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
				Picker(selection: $_deviceControlsStyle) {
					ForEach(DeviceControlsStyle.allCases) { style in
						Text(style.title).tag(style)
					}
				} label: {
					SettingsRowLabel(.localized("Card Style"), systemImage: "rectangle.on.rectangle", backgroundColor: .purple)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
			}

			NBSection(.localized("App Rows")) {
				Picker(selection: $_rowIconSize) {
					ForEach(RowIconSize.allCases) { size in
						Text(size.title).tag(size)
					}
				} label: {
					SettingsRowLabel(.localized("Row Icon Size"), systemImage: "square.resize", backgroundColor: .orange)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
			}

			NBSection(.localized("Action Buttons")) {
				Picker(selection: $_actionButtonSurfaceStyle) {
					ForEach(NBButtonSurfaceStyle.allCases) { style in
						Text(style.title).tag(style)
					}
				} label: {
					SettingsRowLabel(.localized("Action Button Style"), systemImage: "capsule", backgroundColor: .indigo)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
			}

			NBSection(.localized("Overview Rows")) {
				Picker(selection: $_overviewIconStyle) {
					ForEach(OverviewIconStyle.allCases) { style in
						Text(style.title).tag(style)
					}
				} label: {
					SettingsRowLabel(.localized("Overview Icons"), systemImage: "square.stack.3d.up", backgroundColor: .indigo)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
				Picker(selection: $_allReposIcon) {
					ForEach(AllReposIcon.allCases) { icon in
						Image(systemName: icon.systemImage)
							.accessibilityLabel(icon.title)
							.tag(icon)
					}
				} label: {
					SettingsRowLabel(.localized("All Repos Icon"), systemImage: "appstore", backgroundColor: .cyan)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
			} footer: {
				Text(.localized("Overview styles apply to All Apps, All Repos, and individual repo artwork."))
			}

			NBSection(.localized("Section Headers")) {
				Toggle(isOn: $_mutedSectionHeaders) {
					SettingsRowLabel(.localized("Muted Section Headers"), systemImage: "textformat", backgroundColor: .teal)
				}
			}

			NBSection(.localized("Navigation")) {
				Picker(selection: $_launchTab) {
					ForEach(LaunchTab.allCases) { tab in
						Text(tab.title).tag(tab)
					}
				} label: {
					SettingsRowLabel(.localized("Launch Tab"), systemImage: "rectangle.on.rectangle", backgroundColor: .blue)
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

				Picker(selection: $_pageTitlePlacement) {
					ForEach(RootPageTitlePlacement.allCases) { placement in
						Text(placement.title)
							.tag(placement)
							.disabled(placement == .hidden && _searchPlacement == .pageTitle)
					}
				} label: {
					SettingsRowLabel(.localized("Page Title Position"), systemImage: "text.aligncenter", backgroundColor: .blue)
				}
				.pickerStyle(.menu)
				.tint(.secondary)

				Picker(selection: $_boldPageAndSectionTitles) {
					Text(.localized("Current")).tag(false)
					Text(.localized("Bold")).tag(true)
				} label: {
					SettingsRowLabel(.localized("Title Weight"), systemImage: "textformat", backgroundColor: .gray)
				}
				.pickerStyle(.menu)
				.tint(.secondary)

				Toggle(isOn: $_statusUnderPageTitle) {
					SettingsRowLabel(.localized("Status on Navigation Bar"), systemImage: "textformat", backgroundColor: .blue)
				}

				Toggle(isOn: $_mutedPageTitles) {
					SettingsRowLabel(.localized("Muted Page Titles"), systemImage: "textformat.size.smaller", backgroundColor: .gray)
				}
			} footer: {
				Text(.localized("Choose search placement, page title alignment, and status placement."))
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
				Picker(selection: $_rowHorizontalInset) {
					ForEach(RowHorizontalInset.allCases) { inset in
						Text(inset.title).tag(inset)
					}
				} label: {
					SettingsRowLabel(.localized("Horizontal Inset"), systemImage: "arrow.left.and.right", backgroundColor: .teal)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
				Picker(selection: $_storeCellAppearance) {
					ForEach(0..<_storeCellAppearanceOptions.count, id: \.self) { index in
						Text(_storeCellAppearanceOptions[index]).tag(index)
					}
				} label: {
					SettingsRowLabel(.localized("Description Size"), systemImage: "text.alignleft", backgroundColor: .blue)
				}
				.pickerStyle(.menu)
				.tint(.secondary)
			}

			NBSection(.localized("Feedback")) {
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
		.aetherAmbientScrollBackground(base: .grouped)
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
		.onAppear {
			if _searchPlacement == .pageTitle && _pageTitlePlacement == .hidden {
				_pageTitlePlacement = .center
			}
		}
		.onChange(of: _searchPlacement) { _, placement in
			if placement == .pageTitle && _pageTitlePlacement == .hidden {
				_pageTitlePlacement = .center
			}
		}
	}
}
