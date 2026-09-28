//
//  IDeviceSwiftError.swift
//  IDeviceKit
//
//  Created by samara on 3.06.2025.
//

import Foundation
import IDevice

public struct IDeviceSwiftError: LocalizedError {
	public let message: String
	public let code: Int32

	public init(_ error: UnsafeMutablePointer<IdeviceFfiError>?) {
		if let cMessage = error?.pointee.message {
			self.message = String(cString: cMessage)
		} else {
			self.message = "Unknown device error"
		}
		self.code = error?.pointee.code ?? 0

		if let error {
			idevice_error_free(error)
		}
	}

	public init(
		_ code: Int32 = -7001, // our custom error hehe
		message: String
	) {
		self.message = message
		self.code = code
	}

	public var errorDescription: String? {
		guard code != 0 else { return message }
		return "\(message) (\(code))"
	}
}

enum IDeviceConnectionError: LocalizedError {
	case pairingFileMissing
	case legacyEndpointUnavailable(String?)
	case tcpProviderUnavailable
	case rsdPairingFileUnreadable(String?)
	case rsdEndpointInvalid
	case rsdTunnelUnavailable(String)
	case afcConnectionFailed(String)
	case installationProxyConnectionFailed(String)
	case springboardServicesConnectionFailed(String)
	case misagentConnectionFailed(String)

	var errorDescription: String? {
		switch self {
		case .pairingFileMissing:
			return "The device pairing file is missing."
		case .legacyEndpointUnavailable(let reason):
			return reason.map { "The device connection is unavailable: \($0)" }
				?? "The device connection is unavailable."
		case .tcpProviderUnavailable:
			return "The device TCP provider is unavailable."
		case .rsdPairingFileUnreadable(let reason):
			return reason.map { "The device pairing file could not be read for RSD: \($0)" }
				?? "The device pairing file could not be read for RSD."
		case .rsdEndpointInvalid:
			return "The RSD endpoint address is invalid."
		case .rsdTunnelUnavailable(let reason):
			return "The RSD tunnel is unavailable: \(reason)"
		case .afcConnectionFailed(let reason):
			return "Could not connect to AFC: \(reason)"
		case .installationProxyConnectionFailed(let reason):
			return "Could not connect to Installation Proxy: \(reason)"
		case .springboardServicesConnectionFailed(let reason):
			return "Could not connect to SpringBoard Services: \(reason)"
		case .misagentConnectionFailed(let reason):
			return "Could not connect to the provisioning-profile service: \(reason)"
		}
	}
}
