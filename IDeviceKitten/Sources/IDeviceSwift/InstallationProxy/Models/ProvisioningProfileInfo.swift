//
//  ProvisioningProfileInfo.swift
//  IDeviceKit
//

import Foundation

public struct ProvisioningProfileInfo: Equatable, Sendable {
	public let applicationIdentifier: String
	public let expirationDate: Date
	public let teamIdentifiers: [String]
	public let entitlementTeamIdentifier: String?
	public let provisionedDevices: [String]
	public let provisionsAllDevices: Bool

	init?(data: Data) {
		guard
			let plist = Self._propertyList(from: data),
			let expirationDate = plist["ExpirationDate"] as? Date,
			let entitlements = plist["Entitlements"] as? [String: Any],
			let applicationIdentifier = entitlements["application-identifier"] as? String
		else {
			return nil
		}

		self.applicationIdentifier = applicationIdentifier
		self.expirationDate = expirationDate
		self.teamIdentifiers = (plist["TeamIdentifier"] as? [String])
			?? (plist["TeamIdentifier"] as? String).map { [$0] }
			?? []
		self.entitlementTeamIdentifier = entitlements["com.apple.developer.team-identifier"] as? String
		self.provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []
		self.provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
	}

	public func matches(
		bundleIdentifier: String,
		appTeamIdentifier: String? = nil,
		appApplicationIdentifier: String? = nil,
		now: Date = Date()
	) -> Bool {
		guard expirationDate > now else { return false }
		guard provisionsAllDevices || !provisionedDevices.isEmpty else { return false }

		let declaredTeams = Set(teamIdentifiers + [entitlementTeamIdentifier].compactMap { $0 })
		guard !declaredTeams.isEmpty else { return false }
		guard let teamIdentifier = declaredTeams.first(where: {
			applicationIdentifier.hasPrefix($0 + ".")
		}) else { return false }
		if let appTeamIdentifier, appTeamIdentifier != teamIdentifier {
			return false
		}
		if let appApplicationIdentifier,
		   appApplicationIdentifier != teamIdentifier + "." + bundleIdentifier {
			return false
		}

		var pattern = applicationIdentifier
		pattern.removeFirst(teamIdentifier.count + 1)

		if pattern == "*" {
			return true
		}
		if pattern.hasSuffix("*") {
			return bundleIdentifier.hasPrefix(String(pattern.dropLast()))
		}
		return bundleIdentifier == pattern
	}

	private static func _propertyList(from data: Data) -> [String: Any]? {
		if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
		   let dictionary = plist as? [String: Any] {
			return dictionary
		}

		let startMarker = Data("<plist".utf8)
		let endMarker = Data("</plist>".utf8)
		guard
			let start = data.range(of: startMarker),
			let end = data.range(of: endMarker, options: [], in: start.lowerBound..<data.endIndex)
		else {
			return nil
		}

		let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
		guard
			let plist = try? PropertyListSerialization.propertyList(
				from: plistData,
				options: [],
				format: nil
			)
		else {
			return nil
		}
		return plist as? [String: Any]
	}
}
