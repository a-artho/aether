//
//  Server+Compute.swift
//  aether
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR AETHER
//

import Foundation
import UIKit

extension ServerInstaller {
	var plistEndpoint: URL {
		_endpoint(path: "/\(id).plist")
	}

	var payloadEndpoint: URL {
		_endpoint(path: "/\(id).ipa")
	}
	
	var pageEndpoint: URL {
		_endpoint(path: "/install")
	}
	
	var externalServerLink: String {
		let identifier = app.identifier ?? Bundle.main.bundleIdentifier ?? "unknown.app"
		let name = app.name ?? identifier
		let version = app.version ?? "1"
		var url = URLComponents(string: "https://api.palera.in/genPlist")!
		url.queryItems = [URLQueryItem(name: "bundleid", value: identifier), URLQueryItem(name: "name", value: name),
			URLQueryItem(name: "version", value: version), URLQueryItem(name: "fetchurl", value: payloadEndpoint.absoluteString)]
		url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		return url.url?.absoluteString ?? ""
	}

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}

	@MainActor
	func launchSemiLocalInstall(fallback: @escaping @MainActor @Sendable () -> Void) {
		guard let installURL = URL(string: iTunesLinkExternal) else {
			fallback()
			return
		}

		UIApplication.shared.open(installURL, options: [:]) { didOpen in
			guard !didOpen else { return }
			Task { @MainActor in
				fallback()
			}
		}
	}
	
	private func _iTunesLink(with url: String) -> String {
		var link = URLComponents()
		link.scheme = "itms-services"
		link.host = ""
		link.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: url)]
		link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		return link.url?.absoluteString ?? ""
	}

	var displayImageSmallEndpoint: URL {
		_endpoint(path: "/app57x57.png", scheme: "https")
	}

	var displayImageLargeEndpoint: URL {
		_endpoint(path: "/app512x512.png", scheme: "https")
	}

	private func _endpoint(path: String, scheme: String? = nil) -> URL {
		var comps = URLComponents()
		comps.scheme = scheme ?? (getServerMethod() == 1 ? "http" : "https")
		comps.host = sni()
		comps.path = path
		comps.port = port
		if let url = comps.url {
			return url
		}

		comps.host = "127.0.0.1"
		return comps.url ?? URL(fileURLWithPath: path)
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData() ?? Data()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLinkExternal)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": displayImageSmallEndpoint.absoluteString,
				],
				[
					"kind": "full-size-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": app.identifier ?? Bundle.main.bundleIdentifier ?? "unknown.app",
				"bundle-version": app.version ?? "1",
				"kind": "software",
				"title": app.name ?? app.identifier ?? "App",
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
