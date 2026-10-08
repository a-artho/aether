//
//  ServerView.swift
//  Aether
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleJSON
import NimbleViews

// MARK: - Extension: Model
extension ServerView {
	struct ServerPackModel: Decodable {
		var cert: String
		var ca: String
		var key: String
		var info: ServerPackInfo
		
		private enum CodingKeys: String, CodingKey {
			case cert, ca, key1, key2, info
		}
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			cert = try container.decode(String.self, forKey: .cert)
			ca = try container.decode(String.self, forKey: .ca)
			let key1 = try container.decode(String.self, forKey: .key1)
			let key2 = try container.decode(String.self, forKey: .key2)
			key = key1 + key2
			info = try container.decode(ServerPackInfo.self, forKey: .info)
		}
		
		struct ServerPackInfo: Decodable {
			var issuer: Domains
			var domains: Domains
		}
		
		struct Domains: Decodable {
			var commonName: String
			
			private enum CodingKeys: String, CodingKey {
				case commonName = "commonName"
			}
		}
	}
}

// MARK: - View
struct ServerView: View {
	@AppStorage("Aether.ipFix") private var _ipFix: Bool = true
	@AppStorage("Aether.serverMethod") private var _serverMethod: Int = 1
	private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]
	private let _embedInList: Bool

	init(embedInList: Bool = true) {
		self._embedInList = embedInList
	}
	
	private let _dataService = NBFetchService()
	private let _serverPackUrl = "https://backloop.dev/pack.json"
	
	// MARK: Body
	var body: some View {
		if _embedInList {
			NBList(.localized("Server Config"), displayMode: .inline) {
				_content
			}
		} else {
			_content
		}
	}

	@ViewBuilder
	private var _content: some View {
		Section {
				Picker(selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				} label: {
					SettingsRowLabel(.localized("Server Type"), systemImage: "server.rack", backgroundColor: .blue)
				}
				Toggle(isOn: $_ipFix) {
					SettingsRowLabel(.localized("Only use localhost address"), systemImage: "lifepreserver.fill", backgroundColor: .orange)
				}
				.disabled(_serverMethod != 1)
			} footer: {
				if _serverMethod == 1 {
					Text(.localized("Semi Local uses an online manifest service over HTTPS and serves the application locally over HTTP. Using localhost (127.0.0.1) prevents Wi-Fi network address mismatches. No SSL certificates are required."))
				} else {
					Text(.localized("Fully Local hosts both the manifest and application on-device using a local HTTPS server. Requires trusted SSL certificates."))
				}
			}
			
			if _serverMethod == 0 {
				Section {
					Button {
						FR.downloadSSLCertificates(from: _serverPackUrl) { success in
							if success {
								DispatchQueue.main.async {
									UIAlertController.showAlertWithOk(
										title: .localized("SSL Certificates"),
										message: .localized("Certificates updated successfully.")
									)
								}
							} else {
								DispatchQueue.main.async {
									UIAlertController.showAlertWithOk(
										title: .localized("SSL Certificates"),
										message: .localized("Failed to download, check your internet connection and try again.")
									)
								}
							}
						}
					} label: {
						SettingsRowLabel(
							.localized("Update SSL Certificates"),
							systemImage: "arrow.down.doc.fill",
							backgroundColor: .green
						)
					}
				} footer: {
					Text(.localized("Download the local server SSL certificates and profiles needed for Fully Local HTTPS mode."))
				}
			}
		}
}
