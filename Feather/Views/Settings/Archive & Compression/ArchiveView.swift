//
//  ArchiveView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import Zip
import NimbleViews

// MARK: - View
struct ArchiveView: View {
	@AppStorage("Feather.compressionLevel") private var _compressionLevel: Int = ZipCompression.DefaultCompression.rawValue
	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Archive & Compression")) {
			Section {
				Picker(selection: $_compressionLevel) {
					ForEach(ZipCompression.allCases, id: \.rawValue) { level in
						Text(level.label).tag(level.rawValue)
					}
				} label: {
					SettingsRowLabel(.localized("Compression Level"), systemImage: "archivebox.fill", backgroundColor: .cyan)
				}
			}
			
			Section {
				Toggle(isOn: $_useShareSheet) {
					SettingsRowLabel(.localized("Show Sheet when Exporting"), systemImage: "square.and.arrow.up", backgroundColor: .blue)
				}
			} footer: {
				Text(.localized("Toggling show sheet will present a share sheet after exporting to your files."))
			}
		}
	}
}
