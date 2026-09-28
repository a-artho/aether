//
//  DeviceConnectionManager.swift
//  Feather
//
//  Created by samara on 28.09.2026.
//

import Combine
import Foundation
import IDeviceSwift
import Network
import QuartzCore
import UIKit

public enum DeviceConnectionState: Equatable {
	case disconnected
	case connecting
	case connected
	case disconnecting
}

public enum DeviceDiagnosticStatus: Equatable {
	case ready
	case tunnelUnavailable
	case pairingMissing
	case invalidPairing
	case checking
	case error(String)

	public var localizedDescription: String {
		switch self {
		case .ready:
			return .localized("Connected and ready.")
		case .tunnelUnavailable:
			return .localized("Device tunnel unavailable. Make sure LocalDevVPN is connected.")
		case .pairingMissing:
			return .localized("Pairing file is missing. Import one in Installation settings.")
		case .invalidPairing:
			return .localized("Pairing file is invalid.")
		case .checking:
			return .localized("Checking connection...")
		case .error(let message):
			return message
		}
	}
}

public enum DeviceConnectionError: LocalizedError {
	case pairingMissing
	case tunnelUnavailable(String)
	case invalidPairing
	case serviceUnavailable(String)

	public var errorDescription: String? {
		switch self {
		case .pairingMissing:
			return .localized("Pairing file is missing. Import one in Installation settings.")
		case .tunnelUnavailable(let reason):
			return .localized("Device tunnel unavailable: %@. Make sure LocalDevVPN is connected.", arguments: reason)
		case .invalidPairing:
			return .localized("Pairing file is invalid.")
		case .serviceUnavailable(let reason):
			return reason
		}
	}
}

@MainActor
public final class DeviceConnectionManager: ObservableObject {
	public static let shared = DeviceConnectionManager()

	@Published public private(set) var state: DeviceConnectionState = .disconnected
	@Published public private(set) var diagnostic: DeviceDiagnosticStatus = .tunnelUnavailable
	@Published public private(set) var hasPairingFile: Bool = false

	public var isConnected: Bool {
		state == .connected
	}

	public var isUpdating: Bool {
		state == .connecting || state == .disconnecting
	}

	private let pathMonitor = NWPathMonitor()
	private let monitorQueue = DispatchQueue(label: "feather.network.monitor")
	private var didBecomeActiveObserver: NSObjectProtocol?
	private var transitionTask: Task<Void, Never>?
	private var transitionGeneration: UUID?
	private var transitionExpectedState: Bool?
	private var transitionDeadline: TimeInterval = 0

	public init() {
		hasPairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())

		// 1. Monitor network changes (NWPathMonitor is an event trigger, not source of truth)
		pathMonitor.pathUpdateHandler = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.networkPathChanged()
			}
		}
		pathMonitor.start(queue: monitorQueue)

		// 2. Foreground reconciliation (fires when returning from LocalDevVPN or app switcher)
		didBecomeActiveObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.reconcile()
			}
		}

		// Initial check
		Task {
			await reconcile()
		}
	}

	deinit {
		pathMonitor.cancel()
		if let didBecomeActiveObserver {
			NotificationCenter.default.removeObserver(didBecomeActiveObserver)
		}
		transitionTask?.cancel()
	}

	// MARK: - Event Triggers

	public func networkPathChanged() {
		Task { @MainActor [weak self] in
			await self?.reconcile()
		}
	}

	public func refresh() async {
		await reconcile()
	}

	// MARK: - Toggle Connection

	public func setConnection(enabled: Bool) {
		guard !isUpdating else { return }
		guard (enabled && state != .connected) || (!enabled && state != .disconnected) else { return }

		let action = enabled ? "enable" : "disable"
		guard let url = URL(string: "localdevvpn://\(action)?scheme=feather") else { return }

		let generation = UUID()
		transitionGeneration = generation
		transitionExpectedState = enabled
		transitionDeadline = CACurrentMediaTime() + 6.0
		state = enabled ? .connecting : .disconnecting
		diagnostic = .checking

		// Invalidate stale RSD handles on transition start
		HeartbeatManager.shared.resetRSDTunnel()

		if enabled {
			// On older iOS, start legacy heartbeat thread
			HeartbeatManager.shared.start(true)
		}

		_startTransitionPolling(generation: generation, expectedState: enabled)

		UIApplication.shared.open(url, options: [:]) { [weak self] didOpen in
			Task { @MainActor [weak self] in
				guard let self else { return }
				guard didOpen else {
					self._cancelTransition()
					await self.reconcile(force: true)
					return
				}
			}
		}
	}

	// MARK: - Ensure Connected (for Installation & Operations)

	@discardableResult
	public func ensureConnected() async throws -> Bool {
		hasPairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			throw DeviceConnectionError.pairingMissing
		}

		let isRsd = HeartbeatManager.shared.isRsd
		let probe: (isConnected: Bool, error: String?) = await Task.detached(priority: .userInitiated) {
			if isRsd {
				return HeartbeatManager.shared.checkRSDEndpoint(timeoutInSeconds: 0.5)
			} else {
				return HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 0.5)
			}
		}.value

		guard probe.isConnected else {
			HeartbeatManager.shared.resetRSDTunnel()
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
			throw DeviceConnectionError.tunnelUnavailable(probe.error ?? "Port unreachable")
		}

		let checkResult = await Task.detached(priority: .userInitiated) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1.5)
		}.value

		if checkResult.isConnected {
			_finishTransition(to: .connected, diagnostic: .ready)
			return true
		} else {
			HeartbeatManager.shared.resetRSDTunnel()
			if checkResult.errorCode == -9 {
				_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
				throw DeviceConnectionError.invalidPairing
			} else {
				let message = checkResult.error ?? "Device service unavailable"
				_finishTransition(to: .disconnected, diagnostic: .error(message))
				throw DeviceConnectionError.serviceUnavailable(message)
			}
		}
	}

	// MARK: - Ground Truth Reconciliation

	public func reconcile(force: Bool = false) async {
		let reconciliationGeneration = transitionGeneration
		hasPairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return
		}

		let expectedState = transitionExpectedState
		let now = CACurrentMediaTime()
		let isExpired = now >= transitionDeadline

		// Step 1: Fast non-blocking endpoint probe (under 0.5s)
		let isRsd = HeartbeatManager.shared.isRsd
		let probe: (isConnected: Bool, error: String?) = await Task.detached(priority: .utility) {
			if isRsd {
				return HeartbeatManager.shared.checkRSDEndpoint(timeoutInSeconds: 0.5)
			} else {
				return HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 0.5)
			}
		}.value

		guard
			!Task.isCancelled,
			reconciliationGeneration == transitionGeneration
		else {
			return
		}

		if !probe.isConnected {
			if expectedState == true && !force && !isExpired {
				// During active connection attempt that hasn't timed out, wait for retries
				return
			}
			HeartbeatManager.shared.resetRSDTunnel()
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
			return
		}

		// Step 2: Full Installation Proxy check (validates pairing + transport)
		let checkResult = await Task.detached(priority: .userInitiated) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1.5)
		}.value

		guard
			!Task.isCancelled,
			reconciliationGeneration == transitionGeneration
		else {
			return
		}

		if checkResult.isConnected {
			if expectedState == false && !force && !isExpired {
				// LocalDevVPN can remain reachable briefly after a disconnect request.
				// Keep polling instead of cancelling the transition on that stale result.
				return
			}
			_finishTransition(to: .connected, diagnostic: .ready)
		} else {
			if expectedState == true && !force && !isExpired {
				return
			}
			HeartbeatManager.shared.resetRSDTunnel()
			if checkResult.errorCode == -9 {
				_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
			} else {
				let message = checkResult.error ?? "Device connection failed"
				_finishTransition(to: .disconnected, diagnostic: .error(message))
			}
		}
	}

	// MARK: - Private Helpers

	private func _startTransitionPolling(generation: UUID, expectedState: Bool) {
		transitionTask?.cancel()
		transitionTask = Task { [weak self] in
			let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 1_500_000_000, 2_000_000_000]

			for delay in delays {
				try? await Task.sleep(nanoseconds: delay)
				guard !Task.isCancelled else { return }

				guard let self, self.transitionGeneration == generation else { return }
				await self.reconcile()

				if (expectedState && self.state == .connected) || (!expectedState && self.state == .disconnected) {
					return
				}
			}

			// Final attempt after delays complete
			guard let self, self.transitionGeneration == generation else { return }
			await self.reconcile(force: true)
		}
	}

	private func _cancelTransition() {
		transitionGeneration = nil
		transitionExpectedState = nil
		transitionDeadline = 0
		transitionTask?.cancel()
		transitionTask = nil
	}

	private func _finishTransition(to newState: DeviceConnectionState, diagnostic newDiagnostic: DeviceDiagnosticStatus) {
		transitionGeneration = nil
		transitionExpectedState = nil
		transitionDeadline = 0
		transitionTask?.cancel()
		transitionTask = nil
		state = newState
		diagnostic = newDiagnostic
	}
}
