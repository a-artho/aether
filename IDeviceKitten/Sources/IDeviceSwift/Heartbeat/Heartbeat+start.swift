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
	// MARK: - Start

	public func start(_ forceRestart: Bool = false) {
		guard !isRsd else {
			return
		}

		restartLock.lock()
		defer { restartLock.unlock() }

		restartWorkItem?.cancel()
		restartWorkItem = nil

		if isRestartInProgress && !forceRestart {
			Logger.heartbeat.debug("Restart already in progress, ignoring call")
			return
		}

		let existingThreadIsActive = heartbeatThread?.isExecuting ?? false

		if forceRestart {
			sessionId = arc4random()
			Logger.heartbeat.info("Forcing heartbeat restart with new session ID")
		} else if existingThreadIsActive {
			Logger.heartbeat.info("Heartbeat thread already running")
			return
		}

		if heartbeatThread != nil && !existingThreadIsActive {
			heartbeatThread = nil
		}

		isRestartInProgress = true

		heartbeatThread = Thread { [weak self] in
			guard let self = self else { return }

			self._establishHeartbeat { [weak self] error in
				guard let self = self else { return }

				self.restartLock.lock()
				defer { self.restartLock.unlock() }

				if let error = error {
					Logger.heartbeat.error("Heartbeat error: \(error.localizedDescription)")
					self._scheduleRestart()
				} else {
					self.restartBackoffTime = 1.0
					self.isRestartInProgress = false
				}
			}
		}

		if let thread = heartbeatThread {
			thread.name = "idevice-heartbeat"
			thread.qualityOfService = .background
			thread.start()
			Logger.heartbeat.info("Started new heartbeat thread")
		}
	}

	// MARK: - Restart

	private func _scheduleRestart() {
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }

			self.restartLock.lock()
			self.isRestartInProgress = false
			self.restartWorkItem = nil
			self.restartLock.unlock()

			self.start()
		}

		restartWorkItem = workItem
		restartBackoffTime = min(restartBackoffTime * 1.5, 30.0)

		Logger.heartbeat.info("Scheduling restart in \(self.restartBackoffTime) seconds")

		DispatchQueue.main.asyncAfter(
			deadline: .now() + restartBackoffTime,
			execute: workItem
		)
	}

	// MARK: - Establish

	func _establishHeartbeat(
		completion: @escaping (Error?) -> Void
	) {
		let pairingFile: IdevicePairingFile
		do {
			pairingFile = try getPairing()
		} catch {
			completion(error)
			return
		}

		sessionId = arc4random()

		if !isRsd {
			let connection = checkSocketConnection()
			guard connection.isConnected else {
				Logger.heartbeat.error("Socket connection failed")
				idevice_pairing_file_free(pairingFile)
				completion(IDeviceConnectionError.legacyEndpointUnavailable(connection.error))
				return
			}
		}

		_startHeartbeat(
			pairingFile: pairingFile,
			provider: &provider,
			sessionId: sessionId,
			completion: completion
		)
	}

	// MARK: - RSD Tunnel

	internal func ensureRSDTunnel() -> Bool {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }

		do {
			try _ensureRSDTunnelLocked()
			return true
		} catch {
			Logger.heartbeat.error("RSD establishment failed: \(error.localizedDescription)")
			return false
		}
	}

	func withRSDServiceConnection(
		_ connect: (AdapterHandle, RsdHandshakeHandle) -> UnsafeMutablePointer<IdeviceFfiError>?
	) throws {
		try withRSDServiceConnection(discoveryTimeout: nil, connect)
	}

	func withRSDServiceConnection(
		discoveryTimeout: TimeInterval?,
		_ connect: (AdapterHandle, RsdHandshakeHandle) -> UnsafeMutablePointer<IdeviceFfiError>?
	) throws {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }

		for attempt in 0..<3 {
			try _ensureRSDTunnelLocked(discoveryTimeout: discoveryTimeout)
			guard let adapter = rsdAdapter, let handshake = rsdHandshake else {
				throw IDeviceConnectionError.rsdTunnelUnavailable("The adapter or handshake is missing.")
			}

			if let errorPointer = connect(adapter, handshake) {
				let error = IDeviceSwiftError(errorPointer)
				_invalidateRSDTunnelLocked()
				if attempt < 2 {
					// The tunnel can be reachable before every CoreDevice service has
					// appeared in its RSD handshake. Give that registry a moment before
					// rebuilding the connection instead of surfacing a transient
					// ServiceNotFound error to the user.
					Thread.sleep(forTimeInterval: attempt == 0 ? 0.2 : 0.4)
					continue
				}
				throw error
			}
			return
		}
	}

	private func _ensureRSDTunnelLocked(discoveryTimeout: TimeInterval? = nil) throws {
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
		var didDiscoverPorts = false

		while true {
			for port in ports where attemptedPorts.insert(port).inserted {
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
					failures.append("\(ipAddress):\(port) — \(error.localizedDescription)")
					continue
				}

				guard let newAdapter, let newHandshake else {
					if let newHandshake { rsd_handshake_free(newHandshake) }
					if let newAdapter { adapter_free(newAdapter) }
					failures.append("\(ipAddress):\(port) — The tunnel returned incomplete handles.")
					continue
				}

				rsdAdapter = newAdapter
				rsdHandshake = newHandshake
				lastSuccessfulRSDPort = port
				return
			}

			guard !didDiscoverPorts else { break }
			didDiscoverPorts = true
			for port in RSDPortDiscovery.resolvePorts(timeout: discoveryTimeout ?? 6) where !ports.contains(port) {
				ports.append(port)
			}
		}

		let detail = failures.last ?? "No tunnel handles were returned."
		throw IDeviceConnectionError.rsdTunnelUnavailable(
			"Tried ports \(ports.map(String.init).joined(separator: ", ")). Last error: \(detail)"
		)
	}

	public func resetRSDTunnel() {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }
		_invalidateRSDTunnelLocked()
	}

	private func _invalidateRSDTunnelLocked() {
		if let rsdHandshake {
			rsd_handshake_free(rsdHandshake)
		}
		if let rsdAdapter {
			adapter_free(rsdAdapter)
		}
		rsdHandshake = nil
		rsdAdapter = nil
	}

	// MARK: - Start Heartbeat

	private func _startHeartbeat(
		pairingFile: IdevicePairingFile,
		provider: inout TcpProviderHandle?,
		sessionId: UInt32?,
		completion: @escaping (Error?) -> Void
	) {
		let currentSession = sessionId

		var addr = sockaddr_in()
		memset(&addr, 0, MemoryLayout.size(ofValue: addr))
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = CFSwapInt16HostToBig(port)

		guard inet_pton(AF_INET, ipAddress, &addr.sin_addr) == 1 else {
			Logger.heartbeat.error("Invalid IP address")
			idevice_pairing_file_free(pairingFile)
			completion(IDeviceConnectionError.legacyEndpointUnavailable("Invalid IP address."))
			return
		}

		let result = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				idevice_tcp_provider_new(sockaddrPtr, pairingFile, "SS-Provider", &provider)
			}
		}

		if result != nil {
			Logger.heartbeat.error("Failed to create TCP provider")
			idevice_pairing_file_free(pairingFile)
			completion(IDeviceSwiftError(result))
			return
		}

		var heartbeatClient: HeartbeatClientHandle?
		let hbConnectResult = heartbeat_connect(provider, &heartbeatClient)

		if hbConnectResult != nil {
			Logger.heartbeat.error("Failed to start heartbeat client")
			completion(IDeviceSwiftError(hbConnectResult))
			return
		}
		guard let heartbeatClient else {
			completion(IDeviceConnectionError.tcpProviderUnavailable)
			return
		}

		completion(nil)

		_runHeartbeatLoop(
			heartbeatClient: heartbeatClient,
			expectedSession: currentSession
		)
	}

	// MARK: - Loop

	private func _runHeartbeatLoop(
		heartbeatClient: HeartbeatClientHandle,
		expectedSession: UInt32?
	) {
		var currentInterval: UInt64 = 15

		while true {
			if self.sessionId != expectedSession {
				break
			}

			var nextInterval: UInt64 = 0

			let marcoResult = heartbeat_get_marco(
				heartbeatClient,
				currentInterval,
				&nextInterval
			)

			if marcoResult != nil {
				let error = IDeviceSwiftError(marcoResult)
				Logger.heartbeat.error("heartbeat_get_marco failed: \(error.localizedDescription)")
				heartbeat_client_free(heartbeatClient)
				return
			}

			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .heartbeat, object: nil)
			}

			currentInterval = nextInterval + 5

			let poloResult = heartbeat_send_polo(heartbeatClient)

			if poloResult != nil {
				let error = IDeviceSwiftError(poloResult)
				Logger.heartbeat.error("heartbeat_send_polo failed: \(error.localizedDescription)")
				heartbeat_client_free(heartbeatClient)
				return
			}
		}

		heartbeat_client_free(heartbeatClient)
	}
}
