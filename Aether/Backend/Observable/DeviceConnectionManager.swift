//
//  DeviceConnectionManager.swift
//  Aether
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

public enum PhysicalNetworkState: Equatable {
	case unknown
	case wifiOrWired
	case cellularOnly
	case offline
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
			return .localized("Device tunnel unavailable. Turn on the selected tunneling provider.")
		case .pairingMissing:
			return .localized("Pairing file is missing. Add one in Pairing File settings.")
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
			return .localized("Pairing file is missing. Add one in Pairing File settings.")
		case .tunnelUnavailable(let reason):
			return .localized("Device tunnel unavailable: %@. Turn on the selected tunneling provider.", arguments: reason)
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
	public static let installationMethodKey = "Aether.installationMethod"
	public static let autoTunnelLifecycleKey = "Aether.autoTunnelLifecycle"
	private static let unresolvedSimulationKey = "Aether.spoofing.simulationMayBeActive"

	@Published public private(set) var state: DeviceConnectionState = .disconnected
	@Published public private(set) var diagnostic: DeviceDiagnosticStatus = .tunnelUnavailable
	@Published public private(set) var hasPairingFile: Bool = false
	@Published public private(set) var pairingVerification = PairingVerificationState()
	@Published public private(set) var tunnelMethod: DeviceTunnelMethod
	@Published public private(set) var isAutoTunnelLifecycleEnabled: Bool
	@Published public private(set) var physicalNetworkState: PhysicalNetworkState = .unknown
	@Published public private(set) var requiresInAppTunnelSetup = false

	public var isConnected: Bool {
		state == .connected
	}

	public var isUpdating: Bool {
		state == .connecting || state == .disconnecting
	}

	private let pathMonitor = NWPathMonitor()
	private let monitorQueue = DispatchQueue(label: "aether.network.monitor")
	private var didBecomeActiveObserver: NSObjectProtocol?
	private var didEnterBackgroundObserver: NSObjectProtocol?
	private var transitionTask: Task<Void, Never>?
	private var transitionGeneration: UUID?
	private var transitionExpectedState: Bool?
	private var transitionDeadline: TimeInterval = 0
	private var reconciliationTask: Task<Void, Never>?
	private var reconciliationPending = false
	private var pendingReconciliationForce = false
	private var pendingCellularAssistReconciliation = false

	public init() {
		hasPairingFile = HeartbeatManager.hasPairingFile()
		tunnelMethod = DeviceTunnelMethod(
			rawValue: UserDefaults.standard.string(forKey: "Aether.tunnelMethod") ?? ""
		) ?? .inApp
		isAutoTunnelLifecycleEnabled = UserDefaults.standard.bool(forKey: Self.autoTunnelLifecycleKey)
		HeartbeatManager.shared.ipAddress = EmbeddedTunnelManager.shared.peerIPOnly
		_syncPairingRecord()
		_log(
			"Device connection initialized with \(tunnelMethod.displayName); pairing file \(hasPairingFile ? "available" : "missing")."
		)

		// 1. Monitor network changes (NWPathMonitor is an event trigger, not source of truth)
		pathMonitor.pathUpdateHandler = { [weak self] path in
			Task { @MainActor [weak self] in
				self?.networkPathChanged(path)
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
				guard let self else { return }
				self.handleAppForeground()
				await self.reconcile()
			}
		}

		// 3. Background lifecycle (auto-close tunnel if idle)
		didEnterBackgroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.handleAppBackground()
			}
		}

		// Restore the selected install mode's expected connection state. Server mode
		// deliberately does not launch LocalDevVPN when Aether opens.
		Task { @MainActor [weak self] in
			self?._restoreInstallationMode()
		}
	}

	deinit {
		pathMonitor.cancel()
		if let didBecomeActiveObserver {
			NotificationCenter.default.removeObserver(didBecomeActiveObserver)
		}
		if let didEnterBackgroundObserver {
			NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
		}
		transitionTask?.cancel()
	}

	// MARK: - Event Triggers

	public func networkPathChanged(_ path: NWPath? = nil) {
		if let path {
			let previousNetworkState = physicalNetworkState
			physicalNetworkState = Self.classify(path)
			_log("Physical network is now \(String(describing: physicalNetworkState)).", category: "Cellular Assist")
			if physicalNetworkState != .cellularOnly {
				CellularAssistManager.shared.networkNoLongerNeedsManualRecovery()
				if previousNetworkState == .cellularOnly {
					CellularAssistManager.shared.rearmAutomaticRecovery()
				}
			}
		}
		Task { @MainActor [weak self] in
			await self?.reconcile()
		}
	}

	public func refresh() async {
		await reconcile()
	}

	public func setTunnelMethod(_ method: DeviceTunnelMethod) {
		guard state == .disconnected else { return }
		guard tunnelMethod != method else { return }
		tunnelMethod = method
		requiresInAppTunnelSetup = false
		UserDefaults.standard.set(method.rawValue, forKey: "Aether.tunnelMethod")
		diagnostic = .tunnelUnavailable
		_log("Tunneling provider changed to \(method.displayName).", category: "Tunnel", level: .notice)
		Task { [weak self] in
			self?.reconnectForIDeviceMode()
		}
	}

	// MARK: - Installation Mode

	public var isIDeviceInstallationMode: Bool {
		UserDefaults.standard.integer(forKey: Self.installationMethodKey) == 1
	}

	/// Selects the installation mode and applies its connection policy.
	///
	/// iDevice mode owns the tunnel lifecycle: it connects as soon as a pairing
	/// record is available. Server mode tears the tunnel down. A possibly active
	/// location simulation is a safety boundary because clearing it requires the
	/// developer tunnel to remain available.
	@discardableResult
	public func setInstallationMode(_ method: Int) -> Bool {
		guard !AppInstallationManager.shared.hasPendingInstalls else {
			_log(
				"Ignored installation mode change while an install is active.",
				category: "Install",
				level: .warning
			)
			return false
		}

		let normalizedMethod = method == 1 ? 1 : 0
		if normalizedMethod == 0,
		   UserDefaults.standard.bool(forKey: Self.unresolvedSimulationKey) {
			_log(
				"Kept iDevice mode selected because a simulated location may still be active.",
				category: "Spoofing",
				level: .warning
			)
			return false
		}

		let previousMethod = UserDefaults.standard.integer(forKey: Self.installationMethodKey)
		UserDefaults.standard.set(normalizedMethod, forKey: Self.installationMethodKey)
		guard previousMethod != normalizedMethod else {
			if normalizedMethod == 1 {
				CellularAssistManager.shared.rearmAutomaticRecovery()
				_connectForIDeviceMode()
			}
			return true
		}

		if normalizedMethod == 1 {
			CellularAssistManager.shared.rearmAutomaticRecovery()
			_log("iDevice mode selected; preparing the device tunnel.", category: "Tunnel", level: .notice)
			_connectForIDeviceMode()
		} else {
			_log("Server mode selected; disconnecting the device tunnel.", category: "Tunnel", level: .notice)
			CellularAssistManager.shared.cancelAndRestoreIfNeeded()
			setConnection(enabled: false, force: true)
		}
		return true
	}

	/// Re-attempts the automatic iDevice connection without exposing a separate
	/// manual connection control in the interface.
	public func reconnectForIDeviceMode() {
		guard isIDeviceInstallationMode else { return }
		CellularAssistManager.shared.rearmAutomaticRecovery()
		_connectForIDeviceMode()
	}

	/// Creates the in-app VPN profile only after an explicit user action.
	/// Automatic reconciliation deliberately never calls this path.
	public func setUpInAppTunnel() {
		guard isIDeviceInstallationMode, tunnelMethod == .inApp, !isUpdating else { return }
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return
		}
		requiresInAppTunnelSetup = false
		setConnection(enabled: true)
	}

	/// Checks whether any long-running operation requires the device tunnel to stay open in background.
	public var hasActiveTunnelDependencies: Bool {
		// 1. Location spoofing
		if UserDefaults.standard.bool(forKey: Self.unresolvedSimulationKey) {
			return true
		}
		// 2. Active app installation
		if AppInstallationManager.shared.isInstalling {
			return true
		}
		// 3. Active on-device pairing session
		if OnDevicePairingManager.shared.isActive {
			return true
		}
		if CellularAssistManager.shared.isBusy || CellularAssistManager.shared.isWaitingForManualRecovery {
			return true
		}
		return false
	}

	public func setAutoTunnelLifecycle(_ enabled: Bool) {
		guard isAutoTunnelLifecycleEnabled != enabled else { return }
		isAutoTunnelLifecycleEnabled = enabled
		UserDefaults.standard.set(enabled, forKey: Self.autoTunnelLifecycleKey)
		_log("Auto tunnel lifecycle set to \(enabled).", category: "Tunnel", level: .notice)
		if enabled && isIDeviceInstallationMode && !isConnected && !isUpdating {
			_connectForIDeviceMode()
		}
	}

	public func handleAppForeground() {
		CellularAssistManager.shared.handleApplicationDidBecomeActive()
		guard !CellularAssistManager.shared.isBusy else { return }
		guard isAutoTunnelLifecycleEnabled, isIDeviceInstallationMode else { return }
		guard !isConnected, !isUpdating else { return }
		_log("App foregrounded; automatically starting device tunnel.", category: "Tunnel", level: .notice)
		_connectForIDeviceMode()
	}

	public func handleAppBackground() {
		guard isAutoTunnelLifecycleEnabled, isIDeviceInstallationMode else { return }
		if hasActiveTunnelDependencies {
			_log(
				"App backgrounded; keeping device tunnel active because an operation is in progress (spoofing: \(UserDefaults.standard.bool(forKey: Self.unresolvedSimulationKey)), installing: \(AppInstallationManager.shared.isInstalling), pairing: \(OnDevicePairingManager.shared.isActive), cellular assist: \(CellularAssistManager.shared.isBusy)).",
				category: "Tunnel",
				level: .notice
			)
			return
		}
		guard isConnected, !isUpdating else { return }
		_log("App backgrounded with no active tasks; automatically closing device tunnel.", category: "Tunnel", level: .notice)
		setConnection(enabled: false)
	}

	private func _restoreInstallationMode() {
		guard isIDeviceInstallationMode else {
			state = .disconnected
			diagnostic = .tunnelUnavailable
			return
		}
		_connectForIDeviceMode()
	}

	private func _connectForIDeviceMode() {
		Task { [weak self] in
			guard let self else { return }
			self._syncPairingRecord()
			guard self.hasPairingFile else {
				self._finishTransition(to: .disconnected, diagnostic: .pairingMissing)
				return
			}
			guard await self._hasRequiredTunnelProfile() else {
				self._finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			self.setConnection(enabled: true)
		}
	}

	// MARK: - Toggle Connection

	public func setConnection(enabled: Bool, force: Bool = false) {
		guard !isUpdating else { return }
		guard force || (enabled && state != .connected) || (!enabled && state != .disconnected) else { return }

		let method = tunnelMethod
		let generation = UUID()
		transitionGeneration = generation
		transitionExpectedState = enabled
		transitionDeadline = method == .inApp ? .infinity : CACurrentMediaTime() + 6.0
		state = enabled ? .connecting : .disconnecting
		diagnostic = .checking
		_log("\(enabled ? "Connecting" : "Disconnecting") with \(method.displayName).", category: "Tunnel", level: .notice)

		Task { [weak self] in
			guard let self else { return }
			await self._resetRSDTunnel()
			guard self.transitionGeneration == generation else { return }

			switch method {
			case .localDevVPN:
				self._setLocalDevVPNConnection(
					enabled: enabled,
					generation: generation
				)
			case .inApp:
				await self._setEmbeddedTunnelConnection(
					enabled: enabled,
					generation: generation
				)
			}
		}
	}

	// MARK: - Ensure Connected (for Installation & Operations)

	@discardableResult
	public func ensureConnected() async throws -> Bool {
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			_log("Device action blocked because the pairing file is missing.", level: .warning)
			throw DeviceConnectionError.pairingMissing
		}

		let method = tunnelMethod
		if method == .inApp {
			guard await _hasRequiredTunnelProfile() else {
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				throw DeviceConnectionError.tunnelUnavailable("Set up the Aether VPN profile first")
			}
			await EmbeddedTunnelManager.shared.refresh()
			let embeddedReady = EmbeddedTunnelManager.shared.isConnected
			guard embeddedReady else {
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				_log("Device action blocked because the in-app tunnel is not ready.", category: "Tunnel", level: .warning)
				throw DeviceConnectionError.tunnelUnavailable("In-app tunnel is not ready")
			}

			// Explicit device actions (installation and spoofing) must follow the
			// same cellular policy as background reconciliation. Without this,
			// those actions could probe the device immediately and fail while
			// Cellular Assist is still establishing the usable route.
			if _routeCellularRecoveryIfNeeded() {
				if await _waitForCellularRecovery() {
					return true
				}
				throw DeviceConnectionError.tunnelUnavailable(
					"Waiting for the device connection after Cellular Assist."
				)
			}
		}

		let isRsd = HeartbeatManager.shared.isRsd
		if !isRsd {
			let probe = await Task.detached(priority: .userInitiated) {
				HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 1.5)
			}.value

			guard probe.isConnected else {
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				_log("Device endpoint probe failed: \(probe.error ?? "port unreachable").", level: .warning)
				throw DeviceConnectionError.tunnelUnavailable(probe.error ?? "Port unreachable")
			}
		}

		let checkedRecord = _syncPairingRecord()
		if let checkedRecord { pairingVerification.beginChecking(checkedRecord) }
		let checkResult = await Task.detached(priority: .userInitiated) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1.5)
		}.value

		guard _recordStillMatches(checkedRecord) else {
			throw DeviceConnectionError.serviceUnavailable("Pairing record changed during verification. Retry the connection.")
		}
		if let checkedRecord {
			pairingVerification.finishChecking(checkedRecord, succeeded: checkResult.isConnected)
		}
		switch await _discardRejectedRecord(checkResult, record: checkedRecord) {
		case .discarded, .failed:
			throw DeviceConnectionError.invalidPairing
		case .replaced:
			throw DeviceConnectionError.serviceUnavailable("Pairing record changed during verification. Retry the connection.")
		case .notRejected:
			break
		}
		if checkResult.isConnected {
			_finishTransition(to: .connected, diagnostic: .ready)
			CellularAssistManager.shared.connectionDidSucceed()
			_log("Device transport and pairing were verified.", level: .notice)
			return true
		} else {
			await _resetRSDTunnel()
			if checkResult.rejectsPairingRecord {
				_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
				_log("Device rejected the pairing record.", level: .error)
				throw DeviceConnectionError.invalidPairing
			} else {
				let message = checkResult.error ?? "Device service unavailable"
				_finishTransition(to: .disconnected, diagnostic: .error(message))
				_log("Device service check failed: \(message)", level: .error)
				throw DeviceConnectionError.serviceUnavailable(message)
			}
		}
	}

	// MARK: - Ground Truth Reconciliation

	public func reconcile(force: Bool = false, cellularAssistTransaction: Bool = false) async {
		if reconciliationTask != nil {
			reconciliationPending = true
			pendingReconciliationForce = pendingReconciliationForce || force
			pendingCellularAssistReconciliation = pendingCellularAssistReconciliation || cellularAssistTransaction
			return
		}

		let task = Task { [weak self] in
			guard let self else { return }
			await self._reconcile(force: force, cellularAssistTransaction: cellularAssistTransaction)
		}
		reconciliationTask = task
		await task.value
		reconciliationTask = nil

		guard reconciliationPending else { return }
		let nextForce = pendingReconciliationForce
		let nextCellularAssistTransaction = pendingCellularAssistReconciliation
		reconciliationPending = false
		pendingReconciliationForce = false
		pendingCellularAssistReconciliation = false
		await reconcile(force: nextForce, cellularAssistTransaction: nextCellularAssistTransaction)
	}

	private func _reconcile(force: Bool, cellularAssistTransaction: Bool) async {
		let reconciliationGeneration = transitionGeneration
		let method = tunnelMethod
		guard isIDeviceInstallationMode else {
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
			return
		}
		guard !CellularAssistManager.shared.isAutomaticRecoveryInProgress || cellularAssistTransaction else {
			return
		}
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return
		}

		let expectedState = transitionExpectedState
		let now = CACurrentMediaTime()
		let isExpired = now >= transitionDeadline

		if method == .inApp {
			HeartbeatManager.shared.ipAddress = EmbeddedTunnelManager.shared.peerIPOnly
			guard await _hasRequiredTunnelProfile() else {
				await _resetRSDTunnel()
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			await EmbeddedTunnelManager.shared.refresh()
			let embeddedReady = EmbeddedTunnelManager.shared.isConnected
			guard embeddedReady else {
				if expectedState == true && !force && !isExpired {
					return
				}
				await _resetRSDTunnel()
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			if !cellularAssistTransaction,
				physicalNetworkState == .cellularOnly,
				_beginCellularAssistIfEligible() {
				return
			}
		}

		// The legacy transport needs a socket preflight. RSD is verified by its
		// native Remote Pairing handshake below; a raw probe can fail even when
		// the packet tunnel is ready.
		let isRsd = HeartbeatManager.shared.isRsd
		if !isRsd {
			let probe = await Task.detached(priority: .utility) {
				HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 1.5)
			}.value

			guard
				!Task.isCancelled,
				reconciliationGeneration == transitionGeneration
			else {
				return
			}
			guard !CellularAssistManager.shared.isAutomaticRecoveryInProgress || cellularAssistTransaction else {
				return
			}

			if !probe.isConnected {
				if expectedState == true && !force && !isExpired {
					// During active connection attempt that hasn't timed out, wait for retries.
					return
				}
				if _beginCellularAssistIfEligible() { return }
				await _resetRSDTunnel()
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
		}

		// Step 2: Full Installation Proxy check (validates pairing + transport)
		let checkedRecord = _syncPairingRecord()
		if let checkedRecord { pairingVerification.beginChecking(checkedRecord) }
		let checkResult = await Task.detached(priority: .userInitiated) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1.5)
		}.value

		guard
			!Task.isCancelled,
			reconciliationGeneration == transitionGeneration
		else {
			return
		}
		guard !CellularAssistManager.shared.isAutomaticRecoveryInProgress || cellularAssistTransaction else {
			return
		}

		guard _recordStillMatches(checkedRecord) else { return }
		if let checkedRecord {
			pairingVerification.finishChecking(checkedRecord, succeeded: checkResult.isConnected)
		}
		if await _discardRejectedRecord(checkResult, record: checkedRecord) != .notRejected { return }

		if checkResult.isConnected {
			if expectedState == false && !force && !isExpired {
				// LocalDevVPN can remain reachable briefly after a disconnect request.
				// Keep polling instead of cancelling the transition on that stale result.
				return
			}
			_finishTransition(to: .connected, diagnostic: .ready)
			CellularAssistManager.shared.connectionDidSucceed()
		} else {
			if expectedState == true && !force && !isExpired {
				return
			}
			if !checkResult.rejectsPairingRecord, _beginCellularAssistIfEligible() { return }
			await _resetRSDTunnel()
			if checkResult.rejectsPairingRecord {
				_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
			} else {
				let message = checkResult.error ?? "Device connection failed"
				_finishTransition(to: .disconnected, diagnostic: .error(message))
			}
		}
	}

	// MARK: - Private Helpers

	/// Refresh stored-file status without launching a VPN or adding another probe.
	public func refreshStoredPairingState() {
		_syncPairingRecord()
	}

	@discardableResult
	private func _syncPairingRecord() -> PairingRecordIdentity? {
		hasPairingFile = HeartbeatManager.hasPairingFile()
		let record = hasPairingFile ? PairingRecordIdentity(fileURL: URL(fileURLWithPath: HeartbeatManager.activePairingFile())) : nil
		if pairingVerification.record != record { pairingVerification.select(record) }
		return record
	}

	private func _recordStillMatches(_ record: PairingRecordIdentity?) -> Bool {
		_syncPairingRecord() == record
	}

	private enum PairingRejectionResult { case notRejected, discarded, replaced, failed }

	/// A socket failure is inconclusive. Only a structured authentication
	/// rejection allows us to discard the exact file used by this attempt.
	private func _discardRejectedRecord(_ result: DeviceConnectionCheck, record: PairingRecordIdentity?) async -> PairingRejectionResult {
		guard result.rejectsPairingRecord, let record else { return .notRejected }
		_log("Device rejected the saved pairing identity (code \(result.errorCode ?? 0), subcode \(result.errorSubCode ?? 0)).", category: "Pairing", level: .error)
		do {
			guard try HeartbeatManager.discardRejectedPairingRecord(record) else {
				_syncPairingRecord()
				_log("Rejected pairing record was replaced; kept the current record.", category: "Pairing", level: .notice)
				return .replaced
			}
			_syncPairingRecord()
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			_log("Discarded the rejected pairing record. Pairing is required again.", category: "Pairing", level: .notice)
			await _resetRSDTunnel()
			return .discarded
		} catch {
			_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
			_log("Could not discard the rejected pairing record: \(error.localizedDescription)", category: "Pairing", level: .error)
			return .failed
		}
	}

	private func _resetRSDTunnel() async {
		await Task.detached(priority: .utility) {
			HeartbeatManager.shared.resetRSDTunnel()
		}.value
	}

	private func _hasRequiredTunnelProfile() async -> Bool {
		guard tunnelMethod == .inApp else {
			requiresInAppTunnelSetup = false
			return true
		}
		let hasProfile = await EmbeddedTunnelManager.shared.hasSavedConfiguration()
		requiresInAppTunnelSetup = !hasProfile
		return hasProfile
	}

	/// Routes one ordinary reconciliation through cellular recovery only after
	/// the in-app tunnel is running and the active physical route is cellular.
	private func _beginCellularAssistIfEligible() -> Bool {
		guard tunnelMethod == .inApp, physicalNetworkState == .cellularOnly else { return false }
		let tunnelIsRunning: Bool
		tunnelIsRunning = EmbeddedTunnelManager.shared.isConnected
		let started = CellularAssistManager.shared.beginBootstrapIfPossible(
			cellularOnly: true,
			tunnelIsRunning: tunnelIsRunning
		)
		if started {
			return true
		}
		return CellularAssistManager.shared.beginManualRecoveryIfNeeded(
			cellularOnly: true,
			tunnelIsRunning: tunnelIsRunning
		)
	}

	/// Returns true whenever cellular recovery owns the route, including an
	/// already-running automatic or manual recovery. This prevents an explicit
	/// action from falling through to a socket probe during the transition.
	private func _routeCellularRecoveryIfNeeded() -> Bool {
		guard tunnelMethod == .inApp, physicalNetworkState == .cellularOnly else { return false }
		if CellularAssistManager.shared.isAutomaticRecoveryInProgress
			|| CellularAssistManager.shared.isWaitingForManualRecovery {
			return true
		}
		return _beginCellularAssistIfEligible()
	}

	/// Cellular Assist can briefly background Aether while the helper changes
	/// Mobile Data. Keep the initiating action alive across that handoff instead
	/// of reporting an immediate transport error. A bounded wait still gives the
	/// caller a useful failure if the user never completes manual recovery.
	private func _waitForCellularRecovery() async -> Bool {
		let deadline = CACurrentMediaTime() + 60
		while !Task.isCancelled, CACurrentMediaTime() < deadline {
			if isConnected { return true }
			try? await Task.sleep(nanoseconds: 500_000_000)
			guard !Task.isCancelled else { return false }
			await reconcile(force: true)
		}
		return isConnected
	}

	private static func classify(_ path: NWPath) -> PhysicalNetworkState {
		guard path.status == .satisfied else { return .offline }
		if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
			return .wifiOrWired
		}
		if path.usesInterfaceType(.cellular) {
			return .cellularOnly
		}
		return .unknown
	}

	private func _setLocalDevVPNConnection(enabled: Bool, generation: UUID) {
		let action = enabled ? "enable" : "disable"
		guard let url = URL(string: "localdevvpn://\(action)?scheme=aether") else {
			_cancelTransition()
			_log("Could not create the LocalDevVPN connection URL.", category: "Tunnel", level: .error)
			return
		}

		if enabled {
			// On older iOS, start the legacy heartbeat alongside LocalDevVPN.
			HeartbeatManager.shared.start(true)
		}
		_startTransitionPolling(generation: generation, expectedState: enabled)

		UIApplication.shared.open(url, options: [:]) { [weak self] didOpen in
			Task { @MainActor [weak self] in
				guard let self else { return }
				guard didOpen else {
					self._cancelTransition()
					self._log("LocalDevVPN did not accept the connection request.", category: "Tunnel", level: .error)
					await self.reconcile(force: true)
					return
				}
				self._log("Sent \(enabled ? "connect" : "disconnect") request to LocalDevVPN.", category: "Tunnel")
			}
		}
	}

	private func _setEmbeddedTunnelConnection(enabled: Bool, generation: UUID) async {
		if enabled {
			do {
				try await EmbeddedTunnelManager.shared.start()
				guard transitionGeneration == generation else { return }
				// The embedded tunnel also carries the pre-RSD legacy service.
				HeartbeatManager.shared.start(true)
				transitionDeadline = CACurrentMediaTime() + 10.0
				_startTransitionPolling(generation: generation, expectedState: true)
				await reconcile()
			} catch {
				guard transitionGeneration == generation else { return }
				_finishTransition(to: .disconnected, diagnostic: .error(error.localizedDescription))
				_log("In-app tunnel failed to start: \(error.localizedDescription)", category: "Tunnel", level: .error)
			}
		} else {
			await EmbeddedTunnelManager.shared.stop()
			guard transitionGeneration == generation else { return }
			transitionDeadline = CACurrentMediaTime() + 2.0
			_startTransitionPolling(generation: generation, expectedState: false)
			await reconcile(force: true)
		}
	}

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
		let previousState = state
		let previousDiagnostic = diagnostic
		transitionGeneration = nil
		transitionExpectedState = nil
		transitionDeadline = 0
		transitionTask?.cancel()
		transitionTask = nil
		state = newState
		diagnostic = newDiagnostic
		if previousState != newState || previousDiagnostic != newDiagnostic {
			_log("Device state is now \(_stateDescription(newState)): \(newDiagnostic.localizedDescription)")
		}
	}

	private func _stateDescription(_ state: DeviceConnectionState) -> String {
		switch state {
		case .disconnected: return "disconnected"
		case .connecting: return "connecting"
		case .connected: return "connected"
		case .disconnecting: return "disconnecting"
		}
	}

	private func _log(
		_ message: String,
		category: String = "Device",
		level: DebugLogItem.Level = .info
	) {
		DebugLogManager.shared.log(message, category: category, level: level)
	}
}
