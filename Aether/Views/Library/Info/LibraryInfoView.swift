//
//  LibraryInfoView.swift
//  Aether
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign

// MARK: - View
struct LibraryInfoView: View {
	var app: AppInfoPresentable
	@Environment(\.nbStickySectionHeaders) private var stickySectionHeaders
	
	// MARK: Body
	var body: some View {
		NBNavigationView(app.name ?? "", displayMode: .inline) {
			List {
				if stickySectionHeaders {
					Section {} header: { appIconHeader }
				} else {
					Section {
						appIconHeader
							.listRowSeparator(.hidden)
							.listRowBackground(Color.clear)
					}
				}
				
				_infoSection(for: app)
				_certSection(for: app)
				_bundleSection(for: app)
				_executableSection(for: app)
				
				Section {
					Button(.localized("Open in Files"), systemImage: "folder") {
						if let dir = Storage.shared.getUuidDirectory(for: app), let sharedURL = dir.toSharedDocumentsURL() {
							UIApplication.open(sharedURL)
						}
					}
				}
			}
			.aetherAmbientScrollBackground(base: .grouped)
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
	}

	private var appIconHeader: some View {
		FRAppIconView(app: app)
			.frame(maxWidth: .infinity, alignment: .center)
	}
}

// MARK: - Extension: View
extension LibraryInfoView {
	@ViewBuilder
	private func _infoSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Info")) {
			if let name = app.name {
				_infoCell(.localized("Name"), desc: name)
			}
			
			if let ver = app.version {
				_infoCell(.localized("Version"), desc: ver)
			}
			
			if let id = app.identifier {
				_infoCell(.localized("Identifier"), desc: id)
			}
			
			if let date = app.date {
				_infoCell(.localized("Date Added"), desc: date.formatted())
			}
			
			if
				app.name != nil,
				let appDirectory = Storage.shared.getAppDirectory(for: app),
				let appMinimumOS = Bundle(url: appDirectory)?.minimumOSVersion
			{
				_infoCell(.localized("Minimum OS"), desc: appMinimumOS)
			}
		}
	}
	
	@ViewBuilder
	private func _certSection(for app: AppInfoPresentable) -> some View {
		if let cert = Storage.shared.getCertificate(from: app) {
			NBSection(.localized("Certificate")) {
				CertificatesCellView(
					cert: cert
				)
			}
		}
	}
	
	@ViewBuilder
	private func _bundleSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Bundle")) {
			NavigationLink(.localized("Alternative Icons")) {
				SigningAlternativeIconView(app: app, appIcon: .constant(nil), isModifing: .constant(false))
			}
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _executableSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Executable")) {
			NavigationLink(.localized("Dylibs")) {
				SigningDylibView(app: app, options: .constant(nil))
			}
			NavigationLink(.localized("Entitlements")) {
				if 
					let appDir = Storage.shared.getAppDirectory(for: app),
					let path = Bundle(url: appDir)?.executableURL?.path,
					let data = LCGetMachOEntitlements(path),
					let rawDict = (try? PropertyListSerialization.propertyList(
						from: data,
						options: [],
						format: nil
					)) as? [String: Any] 
				{
					let binaryEntitlementsDict = rawDict.mapValues { AnyCodable($0) }
					CertificatesInfoEntitlementView(entitlements: binaryEntitlementsDict)
				} else {
					Text(.localized("No Entitlements listed."))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}
}

