//
//  Heartbeat+checks.swift
//  Feather
//
//  Created by samara on 29.04.2025.
//

import Foundation
import IDevice

// MARK: - Class extension: socket
extension HeartbeatManager {
	/// Verifies that Feather can reach the paired device's Installation Proxy service.
	/// Unlike a raw TCP probe, this validates the active transport and pairing flow.
	public func checkDeviceConnection(
		timeoutInSeconds: Double = 2.0,
		endpointAlreadyValidated: Bool = false
	) -> (isConnected: Bool, error: String?, errorCode: Int32?) {
		if isRsd {
			if !endpointAlreadyValidated {
				let probe = checkRSDEndpoint(timeoutInSeconds: min(timeoutInSeconds, 0.75))
				guard probe.isConnected else {
					return (false, probe.error, nil)
				}
			}
			return _checkRSDDeviceConnection()
		}

		let socketConnection = checkSocketConnection(timeoutInSeconds: timeoutInSeconds)
		guard socketConnection.isConnected else {
			return (false, socketConnection.error, nil)
		}

		guard let provider else {
			return (false, "Heartbeat provider unavailable", nil)
		}

		var client: OpaquePointer?
		defer { installation_proxy_client_free(client) }
		if let error = installation_proxy_connect(provider, &client) {
			let swiftError = IDeviceSwiftError(error)
			return (false, swiftError.localizedDescription, swiftError.code)
		}
		return (client != nil, client == nil ? "Installation Proxy unavailable" : nil, nil)
	}

	private func _checkRSDDeviceConnection() -> (isConnected: Bool, error: String?, errorCode: Int32?) {
		var client: OpaquePointer?
		defer { installation_proxy_client_free(client) }

		do {
			try withRSDServiceConnection { adapter, handshake in
				installation_proxy_connect_rsd(adapter, handshake, &client)
			}
			return (client != nil, client == nil ? "Installation Proxy unavailable" : nil, nil)
		} catch let error as IDeviceSwiftError {
			return (false, error.localizedDescription, error.code)
		} catch {
			return (false, error.localizedDescription, nil)
		}
	}

	/// Check connection to RSD endpoint (port 49152)
	/// - Returns: Tuple for connection status and error message (if any)
	public func checkRSDEndpoint(timeoutInSeconds: Double = 0.5) -> (isConnected: Bool, error: String?) {
		checkPortConnection(port: port_rsd, timeoutInSeconds: timeoutInSeconds)
	}

	/// Check connection to legacy socket/tunnel (port 62078)
	/// - Returns: Tuple for connection status and error message (if any)
	public func checkSocketConnection(timeoutInSeconds: Double = 2.0) -> (isConnected: Bool, error: String?) {
		checkPortConnection(port: port, timeoutInSeconds: timeoutInSeconds)
	}

	/// Check TCP connection to a specific port on the device
	/// - Returns: Tuple for connection status and error message (if any)
	public func checkPortConnection(port targetPort: UInt16, timeoutInSeconds: Double = 0.5) -> (isConnected: Bool, error: String?) {
		let socketFD = socket(AF_INET, SOCK_STREAM, 0)
		if socketFD == -1 {
			return (false, "Failed to create socket")
		}

		defer {
			close(socketFD)
		}

		let flags = fcntl(socketFD, F_GETFL, 0)
		if flags == -1 {
			return (false, "Failed to get socket flags")
		}
		if fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == -1 {
			return (false, "Failed to set socket to non-blocking mode")
		}

		var addr = sockaddr_in()
		memset(&addr, 0, MemoryLayout.size(ofValue: addr))
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = CFSwapInt16HostToBig(targetPort)

		guard inet_pton(AF_INET, ipAddress, &addr.sin_addr) == 1 else {
			return (false, "Invalid IP address format")
		}

		let connectResult = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}

		if connectResult != 0 {
			if errno != EINPROGRESS {
				return (false, "Failed to connect: \(String(cString: strerror(errno)))")
			}

			var writeSet = fd_set()
			__darwin_fd_set(socketFD, &writeSet)

			var timeout = timeval()
			timeout.tv_sec = Int(timeoutInSeconds)
			timeout.tv_usec = __darwin_suseconds_t(Int((timeoutInSeconds - Double(timeout.tv_sec)) * 1_000_000))

			let selectResult = select(socketFD + 1, nil, &writeSet, nil, &timeout)

			if selectResult == 0 {
				return (false, "Connection timed out")
			} else if selectResult == -1 {
				return (false, "Select failed: \(String(cString: strerror(errno)))")
			}

			var error: Int32 = 0
			var len = socklen_t(MemoryLayout<Int32>.size)
			if getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &len) == -1 {
				return (false, "Failed to get socket options")
			}

			if error != 0 {
				return (false, "Connection failed: \(String(cString: strerror(error)))")
			}
		}

		return (true, nil)
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
