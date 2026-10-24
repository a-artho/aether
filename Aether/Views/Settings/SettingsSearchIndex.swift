import Foundation

struct SettingsSearchEntry: Identifiable {
	enum Destination: Equatable {
		case page(AppTabManager.SettingsPage)
		case sourceCode
	}
	let key: String
	let title: String
	let category: String
	let destination: Destination
	let keywords: String
	var id: String { "\(category)|\(key)" }
}

/// A local navigation index: selecting a result opens a page, never executes its controls.
@MainActor
enum SettingsSearchIndex {
	static let entries: [SettingsSearchEntry] = {
		var entries: [SettingsSearchEntry] = []
		func add(_ page: AppTabManager.SettingsPage, _ category: String, _ items: [(String, String)]) {
			for (key, aliases) in items {
				entries.append(SettingsSearchEntry(key: key, title: String.localized(key), category: String.localized(category),
					destination: .page(page), keywords: "\(category) \(aliases)"))
			}
		}
		add(.installation, "Device", [("Device Mode", "local server installation")])
		add(.tunnel, "Tunneling", [
			("Tunnel", "vpn connection"), ("Tunnel Provider", "in-app LocalDevVPN"),
			("Tunnel IP", "network address in-app"), ("Device IP", "network address in-app"),
			("Allow Intermediate Addresses", "CIDR network in-app"),
			("Connect Automatically", "automatic launch foreground"), ("Disconnect When Idle", "background lifecycle"),
			("Cellular Assist", "mobile data shortcut wifi"), ("Download LocalDevVPN", "vpn provider")
		])
		add(.pairingFile, "Pairing File", [
			("Pairing", "device pair record"), ("On-Device Pairing", "pair phone"),
			("Import Pairing File", "mobiledevicepairing plist"),
			("Use On-Device Pairing", "pair record"), ("Use Imported Pairing File", "pair record")
		])
		add(.spoofing, "Device", [("Spoofing", "location GPS map joystick simulation")])
		add(.certificates, "Certificates", [
			("Certificates", "certificate signing validity expiration"), ("Import", "certificate p12 mobileprovision"),
			("Import Certificate File", "p12 private key"), ("Import Provisioning File", "mobileprovision profile"),
			("Enter Password", "certificate p12 password"), ("Nickname (Optional)", "certificate name rename")
		])
		add(.appearance, "Appearance", [
			("Appearance", "light dark system theme"), ("Theme", "color tint"), ("Custom Theme Color", "colour tint"),
			("Card Style", "settings device controls tunnel pairing certificate default liquid glass native raised card tiles background"),
			("Row Icons", "settings flat colored monochrome white muted gray grey icons"),
			("Overview Icons", "all apps all repos standalone black system surface glass frame border icons"),
			("Match Repo Icons", "sources artwork overview style frame border glass"),
			("All Repos Icon", "app store globe books collection symbol"),
			("Action Buttons", "full width signing pairing news current glass button style"),
			("Row Icon Size", "apps repos artwork default medium large 50 54 58"),
			("Section Header Size", "heading font text size"), ("Muted Section Headers", "headings gray grey"), ("Hide Tab Labels", "tab bar icons hide labels"),
			("Launch Tab", "startup cold launch start sources library default tab"),
			("Search Placement", "page title right navigation"),
			("Left-Aligned Page Titles", "leading left navigation main tabs title alignment"), ("Hide Search Icon", "page title magnifying glass"), ("Dynamic Icons", "app light dark"),
			("Tinted Icons", "app color colour"), ("Show Download Buttons", "repo sources chevron"),
			("Download Icon", "cloud circle arrow save symbol repo rows app details download"),
			("Download Icon Size", "repo small medium large 14 16 18 sizing"), ("Store Cell Appearance", "sources rows description"), ("Standard", "sources description layout"),
			("Big Description", "sources rows layout"), ("Haptics", "click feedback strength")
		])
		add(.appIcon, "Appearance", [("App Icon", "aether dark alternate icon")])
		add(.signing, "Signing Options", [
			("Signing Options", "sign configure defaults"), ("Display Names", "rename app"), ("Identifiers", "bundle id"),
			("PPQ Protection", "bundle identifier protection"), ("Appearance", "signed app light dark"),
			("Minimum Requirement", "minimum ios version"), ("Signing Type", "signing method"),
			("Injection Path", "tweak dylib"), ("Injection Folder", "frameworks tweaks"),
			("Inject into Extensions", "plugins tweaks"), ("File Sharing", "documents files"),
			("iTunes File Sharing", "documents usb"), ("Pro Motion", "promotion 120hz refresh rate"),
			("Game Mode", "gaming"), ("iPad Fullscreen", "tablet"), ("Remove URL Scheme", "links deeplinks"),
			("Remove Provisioning", "mobileprovision profile"), ("Force Localize", "language app name"),
			("Install After Signing", "automatic install"), ("Merge Entitlements", "permissions"),
			("Replace Substrate with ElleKit", "tweak injection"), ("Disable Liquid Glass", "signed app design"),
			("Enable Liquid Glass", "signed app design")
		])
		add(.archive, "Archive & Compression", [
			("Archive & Compression", "packaging export ipa zip"), ("Compression Level", "size speed archive zip"),
			("Show Sheet when Exporting", "share files export")
		])
		add(.logs, "Logs", [
			("Logs", "diagnostics debug"), ("Enable Logging", "diagnostics debug"), ("Level", "log warning error"),
			("Category", "log filter"), ("Copy Filtered Logs", "clipboard"), ("Copy All Logs", "clipboard"),
			("Export Filtered Logs...", "share diagnostics"), ("Export All Logs...", "share diagnostics"),
			("Clear Diagnostics", "delete logs")
		])
		add(.reset, "Reset", [
			("Reset", "clear delete"), ("Reset Ignored Updates", "unignore apps versions updates list"), ("Reset Work Cache", "storage temporary files"),
			("Reset Network Cache", "disk download cache"), ("Reset Pairing", "pair record"),
			("Reset Tunneling", "vpn network"), ("Reset Sources", "repositories"), ("Reset Signed Apps", "library"),
			("Reset Imported Apps", "library"), ("Reset Certificates", "signing profiles"),
			("Reset Settings", "preferences defaults"), ("Reset All", "erase all data")
		])
		entries.append(SettingsSearchEntry(key: "Source Code", title: .localized("Source Code"), category: .localized("Settings"),
			destination: .sourceCode, keywords: "github repository project"))
		return entries
	}()

	static func results(for query: String) -> [SettingsSearchEntry] {
		let normalizedQuery = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
		let words = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
		guard !words.isEmpty else { return [] }
		return entries.filter { entry in
			let text = normalized("\(entry.title) \(entry.key) \(entry.category) \(entry.keywords)")
			return words.allSatisfy { text.contains($0) }
		}.sorted { left, right in
			let query = normalizedQuery
			func rank(_ entry: SettingsSearchEntry) -> Int {
				let title = normalized(entry.title)
				return title == query ? 0 : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3
			}
			let ranks = (rank(left), rank(right))
			if ranks.0 != ranks.1 { return ranks.0 < ranks.1 }
			let comparison = left.title.localizedStandardCompare(right.title)
			return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
		}
	}

	nonisolated private static func normalized(_ text: String) -> String {
		text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
	}
}
