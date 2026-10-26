//
//  Heartbeat+start.swift
//  Aether
//

import Foundation
import UIKit
import OSLog
import IDevice

// MARK: - Class extension: start
extension HeartbeatManager {
	// MARK: - RSD Tunnel

	func withRSDServiceConnection(
		_ connect: (AdapterHandle, RsdHandshakeHandle) -> UnsafeMutablePointer<IdeviceFfiError>?
	) throws {
		try withRSDServiceConnection(discoveryTimeout: nil, connect)
	}

	func withRSDServiceConnection(
		discoveryTimeout: TimeInterval?,
		_ connect: (AdapterHandle, RsdHandshakeHandle) -> UnsafeMutablePointer<IdeviceFfiError>?
	) throws {
		for attempt in 0..<3 {
			try Task.checkCancellation()
			do {
				try connectRSDServiceOnce(discoveryTimeout: discoveryTimeout, connect)
				return
			} catch let error as IDeviceSwiftError {
				guard Self.shouldRetryRSDService(error), attempt < 2,
					(error.code != 21 || attempt == 0) else { throw error }
				// Backoff must not hold the shared adapter lock. Another service can
				// establish a healthy connection during this wait, which we then reuse.
				Thread.sleep(forTimeInterval: attempt == 0 ? 0.2 : 0.4)
			}
		}
	}

	static func shouldRetryRSDService(_ error: IDeviceSwiftError) -> Bool {
		// Pinned idevice error codes: socket/TLS, inactive session, missing
		// connection/service registry entry, timeout. Locked/unsupported services
		// and pairing rejection do not warrant rebuilding the shared transport.
		[1, 3, 4, 17, 19, 21, 109].contains(error.code)
	}

	private func connectRSDServiceOnce(discoveryTimeout: TimeInterval?,
		_ connect: (AdapterHandle, RsdHandshakeHandle) -> UnsafeMutablePointer<IdeviceFfiError>?
	) throws {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }
		try Task.checkCancellation()
		try _ensureRSDTunnelLocked(discoveryTimeout: discoveryTimeout)
		try Task.checkCancellation()
		guard let adapter = rsdAdapter, let handshake = rsdHandshake else {
			throw IDeviceConnectionError.rsdTunnelUnavailable("The adapter or handshake is missing.")
		}
		if let pointer = connect(adapter, handshake) {
			let error = IDeviceSwiftError(pointer)
			if Self.shouldRetryRSDService(error) { _invalidateRSDTunnelLocked() }
			throw error
		}
	}

	private func _ensureRSDTunnelLocked(discoveryTimeout: TimeInterval? = nil) throws {
		try Task.checkCancellation()
		if rsdAdapter != nil, rsdHandshake != nil {
			return
		}

		_invalidateRSDTunnelLocked()
		let pairingFile = try getPairingRsd()
		defer { rp_pairing_file_free(pairingFile) }

		var address = sockaddr_in()
		memset(&address, 0, MemoryLayout.size(ofValue: address))
		address.sin_family = sa_family_t(AF_INET)

		guard inet_pton(AF_INET, ipAddress, &address.sin_addr) == 1 else {
			throw IDeviceConnectionError.rsdEndpointInvalid
		}

		var ports: [UInt16] = []
		if let lastSuccessfulRSDPort { ports.append(lastSuccessfulRSDPort) }
		if !ports.contains(port_rsd) { ports.append(port_rsd) }
		var failures: [String] = []
		var attemptedPorts = Set<UInt16>()

		func tryPort(_ port: UInt16) throws -> Bool {
			try Task.checkCancellation()
			guard attemptedPorts.insert(port).inserted else { return false }

			address.sin_port = CFSwapInt16HostToBig(port)
			var newAdapter: AdapterHandle?
			var newHandshake: RsdHandshakeHandle?
			let result = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { ptr in
					tunnel_create_rppairing(
						ptr,
						socklen_t(MemoryLayout<sockaddr_in>.size),
						"IdeviceKit",
						pairingFile,
						nil,
						nil,
						&newAdapter,
						&newHandshake
					)
				}
			}

			if let result {
				if let newHandshake { rsd_handshake_free(newHandshake) }
				if let newAdapter { adapter_free(newAdapter) }
				let error = IDeviceSwiftError(result)
				try Task.checkCancellation()
				// Preserve explicit authentication rejection instead of wrapping it
				// in a generic endpoint error or retrying another port.
				if DeviceConnectionCheck(isConnected: false, errorCode: error.code, errorSubCode: error.subCode).rejectsPairingRecord {
					throw error
				}
				failures.append("\(ipAddress):\(port) — \(error.localizedDescription)")
				return false
			}

			guard let newAdapter, let newHandshake else {
				if let newHandshake { rsd_handshake_free(newHandshake) }
				if let newAdapter { adapter_free(newAdapter) }
				failures.append("\(ipAddress):\(port) — The tunnel returned incomplete handles.")
				return false
			}
			guard !Task.isCancelled else {
				rsd_handshake_free(newHandshake)
				adapter_free(newAdapter)
				throw CancellationError()
			}

			rsdAdapter = newAdapter
			rsdHandshake = newHandshake
			lastSuccessfulRSDPort = port
			return true
		}
		for port in ports { if try tryPort(port) { return } }
		var discoveryError: Error?
		_ = RSDPortDiscovery.resolvePorts(timeout: discoveryTimeout ?? 6, stopWhen: { candidates in
			for port in candidates where !attemptedPorts.contains(port) {
				if !ports.contains(port) { ports.append(port) }
				do { if try tryPort(port) { return true } }
				catch { discoveryError = error; return true }
			}
			return false
		})
		if let discoveryError { throw discoveryError }
		if rsdAdapter != nil, rsdHandshake != nil { return }

		let detail = failures.last ?? "No tunnel handles were returned."
		throw IDeviceConnectionError.rsdTunnelUnavailable(
			"Tried ports \(ports.map(String.init).joined(separator: ", ")). Last error: \(detail)"
		)
	}

	public func resetRSDTunnel() {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }
		// A lifecycle owner may retire this cleanup while it waits for a native
		// connection. It must not subsequently reset a newer session's handles.
		guard !Task.isCancelled else { return }
		_invalidateRSDTunnelLocked()
	}

	private func _invalidateRSDTunnelLocked() {
		rsdGeneration &+= 1
		if let rsdHandshake {
			rsd_handshake_free(rsdHandshake)
		}
		if let rsdAdapter {
			adapter_free(rsdAdapter)
		}
		rsdHandshake = nil
		rsdAdapter = nil
	}

}
