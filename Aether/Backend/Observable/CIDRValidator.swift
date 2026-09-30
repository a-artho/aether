//
//  CIDRValidator.swift
//  Aether
//
//  Created by samara on 29.09.2026.
//

import Foundation

public enum IPCategory: String, Sendable, Equatable {
	case unicast
	case defaultRoute
	case loopback
	case multicast
	case broadcast
	case unspecified
	case linkLocal
}

public struct CIDREndpoint: Equatable, Sendable {
	public let raw: String
	public let ip: String
	public let prefix: Int
	public let subnetMask: String

	public var formattedCIDR: String {
		"\(ip)/\(prefix)"
	}

	public init(_ input: String, defaultPrefix: Int = 32) {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		self.raw = trimmed
		let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)

		let ipPart = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
		self.ip = ipPart.isEmpty ? "0.0.0.0" : ipPart

		if parts.count == 2, let parsedPrefix = Int(parts[1].trimmingCharacters(in: .whitespaces)), (0...32).contains(parsedPrefix) {
			self.prefix = parsedPrefix
		} else {
			self.prefix = defaultPrefix
		}

		self.subnetMask = Self.prefixToSubnetMask(self.prefix)
	}

	public init(ip: String, prefix: Int, subnetMask: String? = nil, raw: String? = nil) {
		self.ip = ip
		self.prefix = prefix
		self.subnetMask = subnetMask ?? Self.prefixToSubnetMask(prefix)
		self.raw = raw ?? "\(ip)/\(prefix)"
	}

	public static func prefixToMaskRaw(_ prefix: Int) -> UInt32 {
		guard prefix > 0 else { return 0 }
		guard prefix < 32 else { return 0xFFFFFFFF }
		return ~((1 << (32 - prefix)) - 1)
	}

	public static func prefixToSubnetMask(_ prefix: Int) -> String {
		guard (0...32).contains(prefix) else { return "255.255.255.255" }
		let mask = prefixToMaskRaw(prefix)
		let b1 = (mask >> 24) & 0xFF
		let b2 = (mask >> 16) & 0xFF
		let b3 = (mask >> 8) & 0xFF
		let b4 = mask & 0xFF
		return "\(b1).\(b2).\(b3).\(b4)"
	}
}

public struct CIDRParseResult: Equatable, Sendable {
	public let endpoint: CIDREndpoint
	public let networkBaseIP: String
	public let broadcastIP: String
	public let isCanonicalBase: Bool
	public let totalAddresses: UInt64
	public let category: IPCategory
	public let warnings: [String]

	public var raw: String { endpoint.raw }
	public var ip: String { endpoint.ip }
	public var prefix: Int { endpoint.prefix }
	public var subnetMask: String { endpoint.subnetMask }
	public var formattedCIDR: String { endpoint.formattedCIDR }

	public var canonicalCIDR: String {
		"\(networkBaseIP)/\(prefix)"
	}

	public var rangeSummary: String {
		if prefix == 32 {
			return "\(ip) (Single Host /32)"
		}
		if prefix == 0 {
			return "0.0.0.0 - 255.255.255.255 (Full-Tunnel / All IPv4)"
		}
		return "\(networkBaseIP) - \(broadcastIP) (\(totalAddresses) addresses)"
	}
}

public enum CIDRError: Error, LocalizedError, Equatable, Sendable {
	case emptyInput
	case missingCIDRPrefix(String)
	case invalidFormat(String)
	case invalidOctetCount(ip: String, count: Int)
	case invalidOctetLeadingZero(octet: String, ip: String)
	case invalidOctetRange(octet: String, ip: String)
	case invalidOctetNonNumeric(octet: String, ip: String)
	case missingPrefixNumber
	case invalidPrefix(String)
	case reservedUnspecifiedHost
	case nonCanonicalBase(ip: String, canonicalBase: String, prefix: Int)
	case identicalEndpoints(String)

	public var errorDescription: String? {
		switch self {
		case .emptyInput:
			return .localized("IP / CIDR address cannot be empty.")
		case .missingCIDRPrefix(let raw):
			return .localized("Missing CIDR prefix in '\(raw)'. Format must be 'IP/prefix' (e.g. 10.7.0.0/24).")
		case .invalidFormat(let raw):
			return .localized("Invalid CIDR format: '\(raw)'. Expected 'IP/prefix' (e.g. 10.7.0.1/32 or 10.7.0.0/24).")
		case .invalidOctetCount(let ip, let count):
			return .localized("IPv4 address '\(ip)' must contain exactly 4 octets (found \(count)).")
		case .invalidOctetLeadingZero(let octet, let ip):
			return .localized("Invalid octet '\(octet)' in '\(ip)': leading zeros are not allowed.")
		case .invalidOctetRange(let octet, let ip):
			return .localized("Octet '\(octet)' in '\(ip)' is out of range (must be 0-255).")
		case .invalidOctetNonNumeric(let octet, let ip):
			return .localized("Octet '\(octet)' in '\(ip)' is not a valid number.")
		case .missingPrefixNumber:
			return .localized("Please specify a prefix length after '/' (e.g. /24 or /32).")
		case .invalidPrefix(let prefix):
			return .localized("Invalid CIDR prefix '/\(prefix)'. Prefix length must be a number between 0 and 32.")
		case .reservedUnspecifiedHost:
			return .localized("0.0.0.0 cannot be used as a specific host endpoint.")
		case .nonCanonicalBase(let ip, let base, let prefix):
			return .localized("'\(ip)/\(prefix)' is an intermediate address, not the network base. The canonical network base is '\(base)/\(prefix)'.")
		case .identicalEndpoints(let ip):
			return .localized("Tunnel Interface IP and Peer IP cannot be the same address (\(ip)).")
		}
	}
}

public final class CIDRValidator: Sendable {
	public static let shared = CIDRValidator()

	public init() {}

	public func parseCIDR(
		_ input: String,
		isRouteDestination: Bool = true,
		requireExplicitCIDR: Bool = false,
		defaultPrefix: Int = 32
	) throws -> CIDRParseResult {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw CIDRError.emptyInput
		}

		if requireExplicitCIDR && !trimmed.contains("/") {
			throw CIDRError.missingCIDRPrefix(trimmed)
		}

		let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
		guard parts.count == 1 || parts.count == 2 else {
			throw CIDRError.invalidFormat(trimmed)
		}

		let ipString = String(parts[0]).trimmingCharacters(in: .whitespaces)
		try validateIPv4String(ipString)

		guard let ipRaw = ipToUInt32(ipString) else {
			throw CIDRError.invalidFormat(ipString)
		}

		let prefix: Int
		if parts.count == 2 {
			let prefixStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
			guard !prefixStr.isEmpty else {
				throw CIDRError.missingPrefixNumber
			}
			guard let parsedPrefix = Int(prefixStr), (0...32).contains(parsedPrefix) else {
				throw CIDRError.invalidPrefix(prefixStr)
			}
			prefix = parsedPrefix
		} else {
			guard (0...32).contains(defaultPrefix) else {
				throw CIDRError.invalidPrefix(String(defaultPrefix))
			}
			prefix = defaultPrefix
		}

		if ipRaw == 0 && prefix > 0 {
			throw CIDRError.reservedUnspecifiedHost
		}

		let endpoint = CIDREndpoint(ip: ipString, prefix: prefix, raw: trimmed)
		let category = categorizeIPv4(ipRaw, prefix: prefix)
		let maskRaw = CIDREndpoint.prefixToMaskRaw(prefix)

		let baseRaw = ipRaw & maskRaw
		let broadcastRaw = prefix == 32 ? ipRaw : (baseRaw | ~maskRaw)

		let networkBaseIP = uint32ToIP(baseRaw)
		let broadcastIP = uint32ToIP(broadcastRaw)
		let isCanonicalBase = (ipRaw == baseRaw)

		let totalAddresses: UInt64 = prefix == 0 ? (UInt64(1) << 32) : (UInt64(1) << (32 - prefix))

		var warnings: [String] = []
		if isRouteDestination && !isCanonicalBase && prefix < 32 {
			warnings.append("Note: Network base is '\(networkBaseIP)/\(prefix)' (\(networkBaseIP) - \(broadcastIP)).")
		}

		return CIDRParseResult(
			endpoint: endpoint,
			networkBaseIP: networkBaseIP,
			broadcastIP: broadcastIP,
			isCanonicalBase: isCanonicalBase,
			totalAddresses: totalAddresses,
			category: category,
			warnings: warnings
		)
	}

	public func validateCIDR(
		_ input: String,
		isRouteDestination: Bool = true,
		allowIntermediateAddresses: Bool = false,
		requireExplicitCIDR: Bool = false,
		defaultPrefix: Int = 32
	) throws -> CIDRParseResult {
		let result = try parseCIDR(
			input,
			isRouteDestination: isRouteDestination,
			requireExplicitCIDR: requireExplicitCIDR,
			defaultPrefix: defaultPrefix
		)

		if isRouteDestination && !allowIntermediateAddresses && !result.isCanonicalBase && result.prefix < 32 {
			throw CIDRError.nonCanonicalBase(
				ip: result.ip,
				canonicalBase: result.networkBaseIP,
				prefix: result.prefix
			)
		}

		return result
	}

	public func validatePair(
		tunnelIfaceInput: String,
		tunnelPeerInput: String,
		allowIntermediateAddresses: Bool = false,
		requireExplicitCIDR: Bool = false
	) throws -> (iface: CIDRParseResult, peer: CIDRParseResult) {
		let iface = try validateCIDR(
			tunnelIfaceInput,
			isRouteDestination: false,
			allowIntermediateAddresses: true,
			requireExplicitCIDR: requireExplicitCIDR,
			defaultPrefix: 32
		)
		let peer = try validateCIDR(
			tunnelPeerInput,
			isRouteDestination: true,
			allowIntermediateAddresses: allowIntermediateAddresses,
			requireExplicitCIDR: requireExplicitCIDR,
			defaultPrefix: 32
		)

		if iface.ip == peer.ip {
			throw CIDRError.identicalEndpoints(iface.ip)
		}

		return (iface, peer)
	}

	public func validateIPv4String(_ ip: String) throws {
		let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
		guard octets.count == 4 else {
			throw CIDRError.invalidOctetCount(ip: ip, count: octets.count)
		}

		for octet in octets {
			let str = String(octet)
			guard !str.isEmpty else {
				throw CIDRError.invalidOctetNonNumeric(octet: str, ip: ip)
			}
			guard let val = UInt32(str) else {
				throw CIDRError.invalidOctetNonNumeric(octet: str, ip: ip)
			}
			if str.count > 1 && str.starts(with: "0") {
				throw CIDRError.invalidOctetLeadingZero(octet: str, ip: ip)
			}
			if val > 255 {
				throw CIDRError.invalidOctetRange(octet: str, ip: ip)
			}
		}
	}

	public func isValidIPv4(_ ip: String) -> Bool {
		(try? validateIPv4String(ip)) != nil
	}

	public func ipToUInt32(_ ip: String) -> UInt32? {
		let octets = ip.split(separator: ".")
		guard octets.count == 4 else { return nil }
		var result: UInt32 = 0
		for octet in octets {
			guard let val = UInt32(octet), val <= 255 else { return nil }
			result = (result << 8) | val
		}
		return result
	}

	public func uint32ToIP(_ val: UInt32) -> String {
		let b1 = (val >> 24) & 0xFF
		let b2 = (val >> 16) & 0xFF
		let b3 = (val >> 8) & 0xFF
		let b4 = val & 0xFF
		return "\(b1).\(b2).\(b3).\(b4)"
	}

	public func categorizeIPv4(_ ipRaw: UInt32, prefix: Int = 32) -> IPCategory {
		if ipRaw == 0 {
			return prefix == 0 ? .defaultRoute : .unspecified
		}
		let b1 = (ipRaw >> 24) & 0xFF
		let b2 = (ipRaw >> 16) & 0xFF

		if b1 == 127 { return .loopback }
		if b1 >= 224 && b1 <= 239 { return .multicast }
		if ipRaw == 0xFFFFFFFF { return .broadcast }
		if b1 == 169 && b2 == 254 { return .linkLocal }
		return .unicast
	}
}
