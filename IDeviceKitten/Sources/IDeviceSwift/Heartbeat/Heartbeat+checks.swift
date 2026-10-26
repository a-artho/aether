//
//  Heartbeat+checks.swift
//  Aether
//
//  Created by samara on 29.04.2025.
//

import Foundation
import IDevice

// MARK: - Class extension: socket
extension HeartbeatManager {
	/// Verifies that Aether can reach the paired device's Installation Proxy service.
	/// Unlike a raw TCP probe, this validates the active transport and pairing flow.
	public func checkDeviceConnection(
		timeoutInSeconds: Double = 2.0, includeApps: Bool = false, onVerified: (@Sendable () -> Void)? = nil
	) -> DeviceConnectionCheck {
		return _checkRSDDeviceConnection(timeoutInSeconds: timeoutInSeconds, includeApps: includeApps, onVerified: onVerified)
	}

	private func verifiedClient(_ client: OpaquePointer?, includeApps: Bool, onVerified: (@Sendable () -> Void)? = nil) -> DeviceConnectionCheck {
		guard client != nil else { return .init(isConnected: false, error: "Installation Proxy unavailable") }
		if !Task.isCancelled { onVerified?() }
		guard !Task.isCancelled else { return .init(isConnected: true) }
		guard includeApps else { return .init(isConnected: true) }
		do {
			let apps = try InstallationAppProxy.readApps(client: client, applicationType: "User", lightweight: true)
			return .init(isConnected: true, apps: apps)
		} catch let error as IDeviceSwiftError {
			let check = DeviceConnectionCheck(isConnected: false, error: error.localizedDescription, errorCode: error.code, errorSubCode: error.subCode)
			if check.rejectsPairingRecord { return check }
			return .init(isConnected: true, error: error.localizedDescription)
		} catch { return .init(isConnected: true, error: error.localizedDescription) }
	}

	private func _checkRSDDeviceConnection(timeoutInSeconds: Double, includeApps: Bool, onVerified: (@Sendable () -> Void)?) -> DeviceConnectionCheck {
		var client: OpaquePointer?
		defer { installation_proxy_client_free(client) }

		do {
			try withRSDServiceConnection(discoveryTimeout: timeoutInSeconds) { adapter, handshake in
				installation_proxy_connect_rsd(adapter, handshake, &client)
			}
			return verifiedClient(client, includeApps: includeApps, onVerified: onVerified)
		} catch let error as IDeviceSwiftError {
			return .init(isConnected: false, error: error.localizedDescription, errorCode: error.code, errorSubCode: error.subCode)
		} catch let error as IDeviceConnectionError {
			if case .rsdTunnelUnavailable = error {
				return .init(isConnected: false, error: error.localizedDescription, isTransientTransportFailure: true)
			}
			return .init(isConnected: false, error: error.localizedDescription)
		} catch {
			return .init(isConnected: false, error: error.localizedDescription)
		}
	}

	/// Retrieves and reads pairing file (if any)
	/// - Returns: Pointer to pairing file
	func getPairing() throws -> IdevicePairingFile {
		let pairingFilePath = Self.activePairingFile()
		guard fileManager.fileExists(atPath: pairingFilePath) else {
			throw IDeviceConnectionError.pairingFileMissing
		}

		var pairingFile: IdevicePairingFile?

		if let error = idevice_pairing_file_read(pairingFilePath, &pairingFile) {
			if let pairingFile { idevice_pairing_file_free(pairingFile) }
			throw IDeviceSwiftError(error)
		}

		guard let pairingFile else {
			throw IDeviceConnectionError.pairingFileMissing
		}
		return pairingFile
	}

	func getPairingRsd() throws -> RpPairingFileHandle {
		let pairingFilePath = Self.activePairingFile()
		guard fileManager.fileExists(atPath: pairingFilePath) else {
			throw IDeviceConnectionError.pairingFileMissing
		}

		var pairingFile: RpPairingFileHandle?

		if let error = rp_pairing_file_read(pairingFilePath, &pairingFile) {
			if let pairingFile { rp_pairing_file_free(pairingFile) }
			let reason = IDeviceSwiftError(error).localizedDescription
			throw IDeviceConnectionError.rsdPairingFileUnreadable(reason)
		}

		guard let pairingFile else {
			throw IDeviceConnectionError.rsdPairingFileUnreadable(nil)
		}
		return pairingFile
	}
}
