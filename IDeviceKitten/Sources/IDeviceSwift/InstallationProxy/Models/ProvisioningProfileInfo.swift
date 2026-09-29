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
	public let name: String?
	public let teamName: String?
	public let creationDate: Date?
	public let uuid: String?

	public init(
		applicationIdentifier: String,
		expirationDate: Date,
		teamIdentifiers: [String] = [],
		entitlementTeamIdentifier: String? = nil,
		provisionedDevices: [String] = [],
		provisionsAllDevices: Bool = false,
		name: String? = nil,
		teamName: String? = nil,
		creationDate: Date? = nil,
		uuid: String? = nil
	) {
		self.applicationIdentifier = applicationIdentifier
		self.expirationDate = expirationDate
		self.teamIdentifiers = teamIdentifiers
		self.entitlementTeamIdentifier = entitlementTeamIdentifier
		self.provisionedDevices = provisionedDevices
		self.provisionsAllDevices = provisionsAllDevices
		self.name = name
		self.teamName = teamName
		self.creationDate = creationDate
		self.uuid = uuid
	}

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
		self.name = plist["Name"] as? String
		self.teamName = plist["TeamName"] as? String
		self.creationDate = plist["CreationDate"] as? Date
		self.uuid = plist["UUID"] as? String
	}

	public var isExpired: Bool {
		expirationDate <= Date()
	}

	public var daysRemaining: Int {
		max(0, Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0)
	}

	public var timeRemainingFormatted: String {
		if isExpired {
			let daysAgo = abs(Calendar.current.dateComponents([.day], from: expirationDate, to: Date()).day ?? 0)
			return daysAgo == 0 ? "Expired today" : "Expired \(daysAgo)d ago"
		}
		let components = Calendar.current.dateComponents([.day, .hour], from: Date(), to: expirationDate)
		let days = components.day ?? 0
		let hours = components.hour ?? 0
		if days > 0 {
			return "\(days) day\(days == 1 ? "" : "s") left"
		} else {
			return "\(max(1, hours)) hr\(hours == 1 ? "" : "s") left"
		}
	}

	public var profileType: String {
		if provisionsAllDevices {
			return "Enterprise / In-House"
		}
		if let creation = creationDate {
			let totalDays = Calendar.current.dateComponents([.day], from: creation, to: expirationDate).day ?? 0
			if totalDays <= 8 {
				return "Free Apple ID (7 Days)"
			} else {
				return "Apple Developer (1 Year)"
			}
		}
		if daysRemaining <= 7 && provisionedDevices.count <= 3 {
			return "Free Apple ID (7 Days)"
		}
		return "Apple Developer Program"
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
