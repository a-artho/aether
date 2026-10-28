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
	case providerMissing(DeviceTunnelMethod)
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
		case .providerMissing(let method):
			return method == .localDevVPN
				? .localized("Install LocalDevVPN to use this tunneling provider.")
				: .localized("The Aether tunnel extension is missing. Install a build that includes it.")
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
	// Preserve the existing background-disconnection preference.
	public static let disconnectWhenIdleKey = "Aether.autoTunnelLifecycle"
	public static let connectAutomaticallyKey = "Aether.connectAutomatically"
	private static let unresolvedSimulationKey = "Aether.spoofing.simulationMayBeActive"

	@Published public private(set) var state: DeviceConnectionState = .disconnected {
		didSet { if state != oldValue { _signalConnectionWorkChanged() } }
	}
	@Published public private(set) var diagnostic: DeviceDiagnosticStatus = .tunnelUnavailable
	@Published private var awaitingInitialActivation = false
	@Published private var awaitingIdleReconnect = false
	// UIApplication can report Active while the app/scene is still being built.
	// Provider queries must wait for a real activation callback, not that value alone.
	private var hasCompletedInitialActivation = false

	/// Keep the UI pending across activation, idle-disconnect completion, and verification.
	/// This is presentation state, separate from the guards that permit a connection to start.
	public var isAwaitingAutomaticConnection: Bool {
		awaitingInitialActivation || awaitingIdleReconnect
			|| ((foregroundRecoveryID != nil || appRefreshConnectionID != nil) && !isConnected)
	}
	@Published public private(set) var hasPairingFile: Bool = false
	@Published public private(set) var pairingVerification = PairingVerificationState()
	@Published public private(set) var tunnelMethod: DeviceTunnelMethod
	@Published public private(set) var isDisconnectWhenIdleEnabled: Bool
	@Published public private(set) var isConnectAutomaticallyEnabled: Bool
	@Published public private(set) var physicalNetworkState: PhysicalNetworkState = .unknown
	/// External VPN state is not observable here. Show cellular guidance only
	/// after a requested LocalDevVPN handoff has returned, never before opening it.
	@Published private var hasReturnedFromLocalDevVPN = false
	public var needsLocalDevVPNCellularRecovery: Bool {
		tunnelMethod == .localDevVPN && hasReturnedFromLocalDevVPN
			&& physicalNetworkState == .cellularOnly && !isConnected
	}
	@Published public private(set) var requiresInAppTunnelSetup = false
	@Published private var connectionPreparation: UUID? {
		didSet { if connectionPreparation != oldValue { _signalConnectionWorkChanged() } }
	}

	public var isConnected: Bool {
		state == .connected
	}

	public var failureMessage: String? {
		switch diagnostic {
		case .error(let message): return message
		case .providerMissing, .pairingMissing, .invalidPairing: return diagnostic.localizedDescription
		default: return nil
		}
	}

	public var isUpdating: Bool {
		connectionPreparation != nil || state == .connecting || state == .disconnecting
	}

	private var networkObservation: DeviceNetworkObservation?
	private var didBecomeActiveObserver: NSObjectProtocol?
	private var didEnterBackgroundObserver: NSObjectProtocol?
	private var foregroundRecoveryTask: Task<Void, Never>?
	@Published private var foregroundRecoveryID: UUID?
	private var transitionTask: Task<Void, Never>?
	private var preparationTask: Task<Void, Never>?
	private var connectionTask: Task<Void, Never>?
	private var attemptTimeoutTask: Task<Void, Never>?
	private var rsdCleanupTask: Task<Void, Never>?
	private var embeddedStateObservation: AnyCancellable?
	private var pendingTunnelMethod: DeviceTunnelMethod?
	private var transitionGeneration: UUID?
	private var activeVerificationID: UUID?
	private var connectionEpoch: UInt64 = 0
	private var networkGeneration = UUID()
	private var automaticAttemptEpoch: UInt64?
	private var transitionExpectedState: Bool?
	private var transitionDeadline: TimeInterval = 0
	private var connectionWorkWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
	private var reconciliationTask: Task<Bool, Never>? {
		didSet { _signalConnectionWorkChanged() }
	}
	private var reconciliationRequiresFreshProbe = false
	private var reconciliationID: UUID?
	private var appRefreshConnectionTask: Task<Bool, Never>?
	@Published private var appRefreshConnectionID: UUID?
	private var lastVerifiedAt: TimeInterval = 0
	private var lastVerifiedRecord: PairingRecordIdentity?
	private var automaticRetryBlocked = false
	private var localDevVPNHandoffGeneration: UUID?
	/// A self-update must release Aether's embedded VPN before iOS can replace
	/// this process. This is process-local; a fresh launch resumes normal recovery.
	private var selfUpdateHandoffPending = false
	var isSelfUpdateTunnelHandoffPending: Bool { selfUpdateHandoffPending }

	public init() {
		hasPairingFile = HeartbeatManager.hasPairingFile()
		tunnelMethod = DeviceTunnelMethod(
			rawValue: UserDefaults.standard.string(forKey: "Aether.tunnelMethod") ?? ""
		) ?? .inApp
		isDisconnectWhenIdleEnabled = UserDefaults.standard.bool(forKey: Self.disconnectWhenIdleKey)
		isConnectAutomaticallyEnabled = UserDefaults.standard.object(forKey: Self.connectAutomaticallyKey) as? Bool ?? true
		HeartbeatManager.shared.ipAddress = EmbeddedTunnelManager.shared.peerIPOnly
		_syncPairingRecord()
		_log(
			"Device connection initialized with \(tunnelMethod.displayName); pairing file \(hasPairingFile ? "available" : "missing")."
		)

		// 1. Monitor network changes (NWPathMonitor is an event trigger, not source of truth)
		networkObservation = DeviceNetworkObservation { [weak self] path in
            self?.networkPathChanged(path)
        }
		embeddedStateObservation = EmbeddedTunnelManager.shared.$state
			.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				guard let self, self.tunnelMethod == .inApp else { return }
				Task { [weak self] in await self?.reconcile() }
			}

		// 2. Foreground reconciliation (fires when returning from LocalDevVPN or app switcher)
		didBecomeActiveObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			// The observer is delivered on the main queue. Publish activation state
			// synchronously, before the first resumed frame (including inactive-only returns).
			MainActor.assumeIsolated {
				guard let self else { return }
				self.handleAppForeground()
				if !self.isConnectAutomaticallyEnabled || !self.isIDeviceInstallationMode {
					Task { [weak self] in await self?.reconcile() }
				}
			}
		}

		// 3. Background lifecycle (auto-close tunnel if idle)
		didEnterBackgroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.handleAppBackground() }
		}

		// Restore the selected install mode's expected connection state. Server mode
		// deliberately does not launch LocalDevVPN when Aether opens.
		_restoreInstallationMode()
	}

	isolated deinit {
		if let didBecomeActiveObserver {
			NotificationCenter.default.removeObserver(didBecomeActiveObserver)
		}
		if let didEnterBackgroundObserver {
			NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
		}
		transitionTask?.cancel()
		foregroundRecoveryTask?.cancel()
		preparationTask?.cancel()
		connectionTask?.cancel()
		attemptTimeoutTask?.cancel()
		rsdCleanupTask?.cancel()
	}

	// MARK: - Event Triggers

	public func networkPathChanged(_ path: NWPath? = nil) {
		lastVerifiedAt = 0
		let wasWaitingForDataOff = CellularAssistManager.shared.isWaitingForManualRecovery
			|| needsLocalDevVPNCellularRecovery
		if let path {
			let previousNetworkState = physicalNetworkState
			physicalNetworkState = DeviceNetworkObservation.classify(path)
			networkGeneration = UUID()
			if reconciliationTask != nil {
				_cancelReconciliation()
				activeVerificationID = nil
			}
			// Cellular Assist owns a separate verification ID. Its current probe
			// is retired by networkGeneration, then retried within the same deadline.
			if previousNetworkState != physicalNetworkState { automaticRetryBlocked = false }
			_log("Physical network is now \(String(describing: physicalNetworkState)).", category: "Cellular Assist")
			if physicalNetworkState != .cellularOnly {
				if wasWaitingForDataOff, physicalNetworkState != .unknown, isConnectAutomaticallyEnabled,
					UIApplication.shared.applicationState == .active, !isUpdating {
					_beginTransportRecovery()
				}
				CellularAssistManager.shared.networkNoLongerNeedsManualRecovery()
				if previousNetworkState == .cellularOnly {
					CellularAssistManager.shared.rearmAutomaticRecovery()
				}
			}
		}
		Task { @MainActor [weak self] in
			guard let self, self.hasCompletedInitialActivation else { return }
			if self.tunnelMethod == .inApp, UIApplication.shared.applicationState == .active,
				self.isConnectAutomaticallyEnabled, self.isIDeviceInstallationMode,
				!self.isConnected, !self.isUpdating, self._automaticConnectionPrerequisitesReady() {
				self._connectForIDeviceMode()
			} else { await self.reconcile() }
		}
	}

	public func refresh() async {
		await reconcile()
	}

	public func setTunnelMethod(_ method: DeviceTunnelMethod) {
		guard !isUpdating, AppMaintenanceGuard.pairingBlockReason == nil else { return }
		guard tunnelMethod != method else { return }
		automaticRetryBlocked = false
		if state == .connected {
			pendingTunnelMethod = method
			CellularAssistManager.shared.cancelAndRestoreIfNeeded()
			setConnection(enabled: false)
			return
		}
		guard state == .disconnected else { return }
		connectionEpoch &+= 1
		tunnelMethod = method
		hasReturnedFromLocalDevVPN = false
		CellularAssistManager.shared.networkNoLongerNeedsManualRecovery()
		requiresInAppTunnelSetup = false
		UserDefaults.standard.set(method.rawValue, forKey: "Aether.tunnelMethod")
		diagnostic = .tunnelUnavailable
		_log("Tunneling provider changed to \(method.displayName).", category: "Tunnel", level: .notice)
		if isConnectAutomaticallyEnabled { reconnectForIDeviceMode() }
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
		// AppStorage can publish the new mode before its connection work begins.
		// Establish presentation ownership first so Library never interprets that
		// intermediate state as a failed connection. Prerequisite failures remain
		// actionable, and the normal connection/lifecycle paths retire this flag.
		if previousMethod != normalizedMethod, normalizedMethod == 1,
		   isConnectAutomaticallyEnabled, UIApplication.shared.applicationState != .background,
		   hasPairingFile, !requiresInAppTunnelSetup, !isConnected {
			awaitingInitialActivation = true
		}
		UserDefaults.standard.set(normalizedMethod, forKey: Self.installationMethodKey)
		guard previousMethod != normalizedMethod else {
			if normalizedMethod == 1, isConnectAutomaticallyEnabled {
				CellularAssistManager.shared.rearmAutomaticRecovery()
				_connectForIDeviceMode()
			}
			return true
		}

		if normalizedMethod == 1 {
			CellularAssistManager.shared.rearmAutomaticRecovery()
			_log("iDevice mode selected; preparing the device tunnel.", category: "Tunnel", level: .notice)
			if isConnectAutomaticallyEnabled { _connectForIDeviceMode() }
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
		automaticRetryBlocked = false
		CellularAssistManager.shared.rearmAutomaticRecovery()
		_connectForIDeviceMode(automatically: false)
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
		let neededSetup = requiresInAppTunnelSetup
		requiresInAppTunnelSetup = false
		automaticRetryBlocked = false
		connectionEpoch &+= 1
		let preparation = UUID()
		connectionPreparation = preparation
		diagnostic = .checking
		// Saving a new profile can present iOS's approval UI. The connection's
			// four-second budget starts after that user-controlled step completes.
		preparationTask = Task { [weak self] in
			guard let self else { return }
			do {
				_ = try await EmbeddedTunnelManager.shared.prepare {
					self.connectionPreparation == preparation && !Task.isCancelled
				}
				guard self.connectionPreparation == preparation else { return }
				self.preparationTask = nil
				self.connectionPreparation = nil
				guard UIApplication.shared.applicationState != .background else {
					self._finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
					return
				}
				self.setConnection(enabled: true)
			} catch {
				guard self.connectionPreparation == preparation else { return }
				self.requiresInAppTunnelSetup = neededSetup
				self._finishTransition(to: .disconnected, diagnostic: .error(error.localizedDescription))
			}
		}
	}

	/// Checks whether any long-running operation requires the device tunnel to stay open in background.
	public var hasActiveTunnelDependencies: Bool {
		// 1. Location spoofing
		if SpoofSession.existing?.requiresBackgroundExecution == true {
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
		if CellularAssistManager.shared.requiresTunnelConnection {
			return true
		}
		return false
	}

	public func setDisconnectWhenIdle(_ enabled: Bool) {
		guard isDisconnectWhenIdleEnabled != enabled else { return }
		isDisconnectWhenIdleEnabled = enabled
		if !enabled { awaitingIdleReconnect = false }
		UserDefaults.standard.set(enabled, forKey: Self.disconnectWhenIdleKey)
		_log("Disconnect when idle set to \(enabled).", category: "Tunnel", level: .notice)
	}

	public func setConnectAutomatically(_ enabled: Bool) {
		guard isConnectAutomaticallyEnabled != enabled else { return }
		isConnectAutomaticallyEnabled = enabled
		UserDefaults.standard.set(enabled, forKey: Self.connectAutomaticallyKey)
		if !enabled {
			awaitingInitialActivation = false
			awaitingIdleReconnect = false
			_cancelForegroundRecovery()
			if automaticAttemptEpoch == connectionEpoch {
				_cancelTransition()
				CellularAssistManager.shared.cancelAndRestoreIfNeeded()
				if tunnelMethod == .inApp, !hasActiveTunnelDependencies {
					EmbeddedTunnelManager.shared.requestStopIfRunning()
				}
			}
		}
		_log("Connect automatically set to \(enabled).", category: "Tunnel", level: .notice)
		if enabled && isIDeviceInstallationMode && !isConnected && !isUpdating {
			_connectForIDeviceMode()
		}
	}

	/// App-shell bootstrap; shares the existing guarded connection path with activation.
	public func connectAutomaticallyIfNeeded() {
		guard UIApplication.shared.applicationState == .active,
			!selfUpdateHandoffPending,
			isConnectAutomaticallyEnabled, isIDeviceInstallationMode,
			!CellularAssistManager.shared.isBusy,
			_automaticConnectionPrerequisitesReady() else { return }
		_connectForIDeviceMode()
	}

	private func _providerIsAvailable() -> Bool {
		guard hasCompletedInitialActivation else { return false }
		if tunnelMethod == .inApp {
			guard EmbeddedTunnelManager.shared.isProviderAvailable else {
				_finishTransition(to: .disconnected, diagnostic: .providerMissing(.inApp))
				return false
			}
		} else {
			guard let url = URL(string: "localdevvpn://enable?scheme=aether"), UIApplication.shared.canOpenURL(url) else {
				_finishTransition(to: .disconnected, diagnostic: .providerMissing(.localDevVPN))
				return false
			}
		}
		return true
	}

	private func _automaticConnectionPrerequisitesReady() -> Bool {
		_syncPairingRecord()
		guard hasPairingFile, !requiresInAppTunnelSetup, !automaticRetryBlocked else { return false }
		guard _providerIsAvailable() else { return false }
		guard !needsLocalDevVPNCellularRecovery else { return false }
		guard tunnelMethod != .inApp || !CellularAssistManager.shared.isWaitingForManualRecovery else { return false }
		return true
	}

	public func prepareForForeground() {
		awaitingInitialActivation = isConnectAutomaticallyEnabled && isIDeviceInstallationMode
			&& hasPairingFile && !requiresInAppTunnelSetup
	}

	/// Scene activation also covers a manager constructed after the UIKit notification.
	public func handleInitialActivationIfNeeded() {
		guard !hasCompletedInitialActivation else { return }
		handleAppForeground()
	}

	public func handleAppForeground() {
		guard UIApplication.shared.applicationState == .active else { return }
		hasCompletedInitialActivation = true
		_signalConnectionWorkChanged()
		awaitingInitialActivation = false
		awaitingIdleReconnect = false
		lastVerifiedAt = 0
		CellularAssistManager.shared.handleApplicationDidBecomeActive()
		guard !selfUpdateHandoffPending else {
			_log("Foreground tunnel recovery deferred during Aether self-update handoff.", category: "Tunnel", level: .notice)
			return
		}
		guard !CellularAssistManager.shared.isBusy else { return }
		if let generation = localDevVPNHandoffGeneration, transitionGeneration == generation {
			localDevVPNHandoffGeneration = nil
			if transitionExpectedState == true { hasReturnedFromLocalDevVPN = true }
			if needsLocalDevVPNCellularRecovery {
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			transitionDeadline = CACurrentMediaTime() + 4
			_armAttemptTimeout(epoch: connectionEpoch, seconds: 4)
			_startTransitionPolling(generation: generation, expectedState: transitionExpectedState == true)
			if !isConnectAutomaticallyEnabled || !isIDeviceInstallationMode {
				Task { [weak self] in await self?.reconcile(force: true) }
				return
			}
		}
		guard isConnectAutomaticallyEnabled, isIDeviceInstallationMode else { return }
		if tunnelMethod == .inApp, CellularAssistManager.shared.isWaitingForManualRecovery,
			!EmbeddedTunnelManager.shared.isRunning {
			CellularAssistManager.shared.networkNoLongerNeedsManualRecovery()
		}
		guard _automaticConnectionPrerequisitesReady() else { return }
		_scheduleForegroundRecovery()
		guard !isConnected, !isUpdating else { return }
		_log("App foregrounded; automatically starting device tunnel.", category: "Tunnel", level: .notice)
		_connectForIDeviceMode()
	}

	/// One recovery per activation, after the background stop and verification
	/// settle. A stale Connected value must not consume the reconnect opportunity.
	private func _scheduleForegroundRecovery() {
		_cancelForegroundRecovery()
		let id = UUID()
		foregroundRecoveryID = id
		foregroundRecoveryTask = Task { [weak self] in
			guard let self else { return }
			defer {
				if self.foregroundRecoveryID == id {
					self.foregroundRecoveryID = nil
					self.foregroundRecoveryTask = nil
				}
			}
			let deadline = CACurrentMediaTime() + 4
			guard await self._waitForForegroundConnectionToSettle(id: id, deadline: deadline) else {
				if !Task.isCancelled, self.foregroundRecoveryID == id,
					UIApplication.shared.applicationState == .active,
					!CellularAssistManager.shared.requiresTunnelConnection,
					!CellularAssistManager.shared.isWaitingForManualRecovery,
					self.localDevVPNHandoffGeneration == nil {
					self._expireConnectionAttempt()
				}
				return
			}
			_ = await self.verifyForAppRefresh()
		}
	}

	private func _signalConnectionWorkChanged() {
		for waiter in connectionWorkWaiters.values { waiter.yield(()) }
	}

	private func _waitForForegroundConnectionToSettle(id: UUID, deadline: TimeInterval) async -> Bool {
		guard !Task.isCancelled, foregroundRecoveryID == id,
			UIApplication.shared.applicationState == .active,
			isConnectAutomaticallyEnabled, isIDeviceInstallationMode else { return false }
		guard !CellularAssistManager.shared.requiresTunnelConnection,
			!CellularAssistManager.shared.isWaitingForManualRecovery,
			localDevVPNHandoffGeneration == nil else { return false }
		if !isUpdating, isConnected || reconciliationTask == nil { return true }
		let remaining = deadline - CACurrentMediaTime()
		guard remaining > 0 else { return false }

		// Register before suspending so a transition completion cannot be missed.
		let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		connectionWorkWaiters[id] = continuation
		let timeout = Task {
			do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
			catch { return }
			continuation.finish()
		}
		defer {
			timeout.cancel()
			connectionWorkWaiters.removeValue(forKey: id)
			continuation.finish()
		}
		for await _ in changes {
			guard !Task.isCancelled, foregroundRecoveryID == id,
				UIApplication.shared.applicationState == .active,
				isConnectAutomaticallyEnabled, isIDeviceInstallationMode else { return false }
			guard !CellularAssistManager.shared.requiresTunnelConnection,
				!CellularAssistManager.shared.isWaitingForManualRecovery,
				localDevVPNHandoffGeneration == nil else { return false }
			if !isUpdating, isConnected || reconciliationTask == nil { return true }
		}
		if !Task.isCancelled, foregroundRecoveryID == id {
			_log("Foreground recovery deferred because a connection operation is still pending.", category: "Tunnel", level: .notice)
		}
		return false
	}

	private func _cancelForegroundRecovery() {
		if let id = foregroundRecoveryID { connectionWorkWaiters[id]?.finish() }
		foregroundRecoveryID = nil
		foregroundRecoveryTask?.cancel()
		foregroundRecoveryTask = nil
	}

	private func _cancelReconciliation() {
		reconciliationID = nil
		reconciliationTask?.cancel()
		reconciliationTask = nil
	}

	private func _armAttemptTimeout(epoch: UInt64, seconds: Double) {
		attemptTimeoutTask?.cancel()
		attemptTimeoutTask = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
			guard let self, self.connectionEpoch == epoch, !self.isConnected else { return }
			guard self.localDevVPNHandoffGeneration == nil,
				!CellularAssistManager.shared.requiresTunnelConnection,
				!CellularAssistManager.shared.isWaitingForManualRecovery else { return }
			self._expireConnectionAttempt()
		}
	}

	private func _expireConnectionAttempt() {
		automaticRetryBlocked = true
		connectionEpoch &+= 1
		_cancelReconciliation()
		EmbeddedTunnelManager.shared.invalidateConfigurationCache()
		if tunnelMethod == .inApp, !hasActiveTunnelDependencies {
			EmbeddedTunnelManager.shared.requestStopIfRunning()
		}
		_finishTransition(to: .disconnected,
			diagnostic: .error(.localized("The device connection timed out. Retry connecting.")))
		_log("Retired expired connection work; late completions cannot restart the tunnel.", category: "Tunnel", level: .warning)
	}

	public func handleAppBackground() {
		// A delayed background notification must not close a resumed app's tunnel.
		guard UIApplication.shared.applicationState == .background else { return }
		guard !selfUpdateHandoffPending else {
			_log("App backgrounded during the explicit Aether self-update tunnel handoff.", category: "Tunnel", level: .notice)
			return
		}
		let wasExpectingConnection = (transitionExpectedState != false || awaitingIdleReconnect)
			&& (isAwaitingAutomaticConnection || isConnected || isUpdating
				|| EmbeddedTunnelManager.shared.isRunning)
		_signalConnectionWorkChanged()
		CellularAssistManager.shared.handleApplicationDidEnterBackground()
		awaitingInitialActivation = false
		_cancelForegroundRecovery()
		if localDevVPNHandoffGeneration == nil, !CellularAssistManager.shared.requiresTunnelConnection {
			appRefreshConnectionTask?.cancel()
			appRefreshConnectionTask = nil
			appRefreshConnectionID = nil
		}
		guard tunnelMethod == .inApp, isDisconnectWhenIdleEnabled, isIDeviceInstallationMode else {
			awaitingIdleReconnect = false
			return
		}
		if hasActiveTunnelDependencies {
			awaitingIdleReconnect = false
			_log(
				"App backgrounded; keeping device tunnel active because an operation is in progress (spoofing: \(SpoofSession.existing?.requiresBackgroundExecution == true), locationUnverified: \(UserDefaults.standard.bool(forKey: Self.unresolvedSimulationKey)), installing: \(AppInstallationManager.shared.isInstalling), pairing: \(OnDevicePairingManager.shared.isActive), cellular assist: \(CellularAssistManager.shared.isBusy)).",
				category: "Tunnel",
				level: .notice
			)
			return
		}
		// A deliberate idle stop is pending foreground recovery, including when
		// backgrounding interrupted the first connection before the VPN started.
		// Keep Library from presenting this expected disconnection as a failure.
		awaitingIdleReconnect = isConnectAutomaticallyEnabled && hasPairingFile
			&& !requiresInAppTunnelSetup && wasExpectingConnection
		// LocalDevVPN uses a foreground app handoff to connect. Do not interrupt
		// that handoff; an in-app VPN has no such requirement and must also stop
		// while preparation / start is pending, not just after it is Connected.
		guard state != .disconnecting,
			isConnected || (tunnelMethod == .inApp && (isUpdating || EmbeddedTunnelManager.shared.isRunning)) else { return }
		_log("App backgrounded with no active tasks; automatically closing device tunnel.", category: "Tunnel", level: .notice)
		setConnection(enabled: false, force: tunnelMethod == .inApp)
	}

	private func _restoreInstallationMode() {
		guard isIDeviceInstallationMode else {
			state = .disconnected
			diagnostic = .tunnelUnavailable
			return
		}
		guard isConnectAutomaticallyEnabled else { return }
		// UIKit can still report Background while constructing a cold launch's
		// first scene. Reserve its connection presentation before the first frame;
		// activation starts the work, and a real background event retires it.
		awaitingInitialActivation = hasPairingFile && !requiresInAppTunnelSetup
		// Initialization reserves presentation only. UIKit/scene activation starts
		// provider discovery and connection work after launch services are ready.
	}

	private func _connectForIDeviceMode(automatically: Bool = true) {
		guard hasCompletedInitialActivation, !selfUpdateHandoffPending else { return }
		guard UIApplication.shared.applicationState != .background else { return }
		guard isIDeviceInstallationMode, !isUpdating, !isConnected else { return }
		guard _providerIsAvailable() else { return }
		if tunnelMethod == .inApp, EmbeddedTunnelManager.shared.isRunning {
			_beginTransportRecovery(automatically: automatically)
			return
		}
		awaitingInitialActivation = false
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return
		}
		connectionEpoch &+= 1
		automaticAttemptEpoch = automatically ? connectionEpoch : nil
		activeVerificationID = nil
		let preparation = UUID()
		connectionPreparation = preparation
		diagnostic = .checking
		let deadline = CACurrentMediaTime() + 4
		transitionDeadline = deadline
		_armAttemptTimeout(epoch: connectionEpoch, seconds: 4)
		preparationTask = Task { [weak self] in
			guard let self else { return }
			let hasProfile = await self._hasRequiredTunnelProfile()
			guard self.connectionPreparation == preparation else { return }
			self.preparationTask = nil
			self.connectionPreparation = nil
			guard self.isIDeviceInstallationMode else { return }
			guard UIApplication.shared.applicationState != .background else {
				self._finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			guard hasProfile else {
				self._finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return
			}
			// A device action may have adopted this preparation while the profile
			// lookup was suspended. Preserve that explicit ownership.
			let remainsAutomatic = self.automaticAttemptEpoch == self.connectionEpoch
			guard !remainsAutomatic || self.isConnectAutomaticallyEnabled else { return }
			self.setConnection(enabled: true, deadline: deadline, automatically: remainsAutomatic)
		}
	}

	// MARK: - Toggle Connection

	public func setConnection(enabled: Bool, force: Bool = false, deadline: TimeInterval? = nil, automatically: Bool = false) {
		guard !enabled || !selfUpdateHandoffPending else {
			_log("Ignored tunnel start during Aether self-update handoff.", category: "Tunnel", level: .notice)
			return
		}
		awaitingInitialActivation = false
		if !enabled && UIApplication.shared.applicationState != .background {
			awaitingIdleReconnect = false
		}
		if !enabled {
			appRefreshConnectionTask?.cancel()
			appRefreshConnectionTask = nil
			appRefreshConnectionID = nil
			localDevVPNHandoffGeneration = nil
			connectionEpoch &+= 1
			activeVerificationID = nil
			_cancelForegroundRecovery()
			connectionPreparation = nil
			preparationTask?.cancel()
			preparationTask = nil
		}
		guard force || !isUpdating else { return }
		guard force || (enabled && state != .connected) || (!enabled && state != .disconnected) else { return }
		hasReturnedFromLocalDevVPN = false

		connectionEpoch &+= 1
		automaticAttemptEpoch = enabled && automatically ? connectionEpoch : nil
		connectionTask?.cancel()
		rsdCleanupTask?.cancel()
		rsdCleanupTask = nil
		_cancelReconciliation()
		let method = tunnelMethod
		let generation = UUID()
		activeVerificationID = nil
		transitionGeneration = generation
		transitionExpectedState = enabled
		transitionDeadline = deadline ?? (CACurrentMediaTime() + 4.0)
		guard transitionDeadline > CACurrentMediaTime() else { _expireConnectionAttempt(); return }
		_armAttemptTimeout(epoch: connectionEpoch, seconds: max(0, transitionDeadline - CACurrentMediaTime()))
		state = enabled ? .connecting : .disconnecting
		diagnostic = .checking
		_log("\(enabled ? "Connecting" : "Disconnecting") with \(method.displayName).", category: "Tunnel", level: .notice)

		#if !targetEnvironment(macCatalyst)
		// Acquire before yielding: a backgrounded app can otherwise be suspended
		// while retiring the old RSD transport, before stopVPNTunnel is sent.
		let stopLease = !enabled && method == .inApp ? IdleTunnelStopLease() : nil
		#endif
		connectionTask = Task { [weak self] in
			#if !targetEnvironment(macCatalyst)
			defer { stopLease?.end() }
			#endif
			guard let self else { return }
			// NetworkExtension start/stop must not queue behind an old RSD
			// connection. In-app starts clean the transport after VPN readiness,
			// before probing services; stops retire it after delivering VPN stop.
			if method != .inApp {
				guard await self._resetRSDTunnel() else {
					if self.transitionGeneration == generation { self._expireConnectionAttempt() }
					return
				}
			}
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

	/// Reserves the embedded tunnel for Aether's self-update grace period.
	/// This suppresses lifecycle reconnects without stopping the transport yet.
	@discardableResult
	func prepareSelfUpdateTunnelHandoff() -> Bool {
		guard tunnelMethod == .inApp else { return false }
		guard !selfUpdateHandoffPending else { return true }
		selfUpdateHandoffPending = true
		awaitingInitialActivation = false
		awaitingIdleReconnect = false
		automaticAttemptEpoch = nil
		_cancelForegroundRecovery()
		appRefreshConnectionTask?.cancel()
		appRefreshConnectionTask = nil
		appRefreshConnectionID = nil
		_cancelReconciliation()
		_log("Prepared the embedded VPN for Aether self-update; tunnel shutdown is deferred until the acceptance grace period ends.", category: "Tunnel", level: .notice)
		return true
	}

	/// Starts the VPN shutdown after the installation service has acknowledged
	/// Aether's Install request and the grace period has elapsed.
	@discardableResult
	func stopSelfUpdateTunnelForHandoff() -> Bool {
		guard tunnelMethod == .inApp, selfUpdateHandoffPending else { return false }
		if state == .disconnected, !EmbeddedTunnelManager.shared.isRunning {
			_log("Self-update handoff found the embedded VPN already stopped.", category: "Tunnel", level: .notice)
			return true
		}

		// Keep BGContinued active until this stop has been confirmed.
		EmbeddedTunnelManager.shared.requestStopIfRunning()
		// NetworkExtension's stop confirmation can take up to six seconds. Give
		// this disconnect its own bounded window without changing connect timeouts.
		setConnection(enabled: false, force: true, deadline: CACurrentMediaTime() + 7)
		_log("Started embedded VPN shutdown for Aether self-update after service acceptance.", category: "Tunnel", level: .notice)
		return true
	}

	/// Wait for NetworkExtension to report that the embedded VPN has stopped.
	func waitForSelfUpdateTunnelHandoff() async -> Bool {
		guard selfUpdateHandoffPending else { return false }
		if let task = connectionTask { await task.value }
		if EmbeddedTunnelManager.shared.state == .disconnecting {
			_ = await EmbeddedTunnelManager.shared.waitForSelfUpdateDisconnection()
		}
		let stopped = EmbeddedTunnelManager.shared.state == .disconnected
			&& !EmbeddedTunnelManager.shared.isRunning
		_log("Self-update embedded VPN shutdown \(stopped ? "confirmed" : "not confirmed").",
			category: "Tunnel", level: stopped ? .notice : .warning)
		return stopped
	}

	func endSelfUpdateTunnelHandoff() {
		guard selfUpdateHandoffPending else { return }
		selfUpdateHandoffPending = false
		_log("Ended Aether self-update tunnel handoff state.", category: "Tunnel", level: .notice)
	}

	// MARK: - Ensure Connected (for Installation & Operations)

	@discardableResult
	public func ensureConnected() async throws -> Bool {
		guard !selfUpdateHandoffPending else { throw CancellationError() }
		// An explicit device operation adopts the connection. Disabling automatic
		// launch must not cancel an installation or spoofing operation's work.
		automaticAttemptEpoch = nil
		let epoch = connectionEpoch
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			_log("Device action blocked because the pairing file is missing.", level: .warning)
			throw DeviceConnectionError.pairingMissing
		}
		guard _providerIsAvailable() else {
			throw DeviceConnectionError.tunnelUnavailable(diagnostic.localizedDescription)
		}

		let method = tunnelMethod
		if method == .localDevVPN, needsLocalDevVPNCellularRecovery {
			throw DeviceConnectionError.tunnelUnavailable("Turn off Mobile Data or briefly enable Airplane Mode, then retry.")
		}
		if method == .inApp {
			let hasProfile = await _hasRequiredTunnelProfile()
			guard _reconciliationIsCurrent(epoch: epoch) else { throw CancellationError() }
			guard hasProfile else {
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				throw DeviceConnectionError.tunnelUnavailable("Set up the Aether VPN profile first")
			}
			await EmbeddedTunnelManager.shared.refresh()
			guard _reconciliationIsCurrent(epoch: epoch) else { throw CancellationError() }
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
				if CellularAssistManager.shared.isWaitingForManualRecovery {
					throw DeviceConnectionError.tunnelUnavailable("Turn off Mobile Data or briefly enable Airplane Mode, then retry.")
				}
				if case .failed(let message) = CellularAssistManager.shared.state {
					throw DeviceConnectionError.tunnelUnavailable(message)
				}
				throw DeviceConnectionError.tunnelUnavailable(
					"Waiting for the device connection after Cellular Assist."
				)
			}
		}

		let checkedRecord = _syncPairingRecord()
		if let checkedRecord { pairingVerification.beginChecking(checkedRecord) }
		let checkedNetwork = networkGeneration
		let checkResult = await Task.detached(priority: .userInitiated) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1.5)
		}.value

		guard _reconciliationIsCurrent(epoch: epoch), networkGeneration == checkedNetwork else { throw CancellationError() }
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
		guard _reconciliationIsCurrent(epoch: epoch) else { throw CancellationError() }
		if checkResult.isConnected {
			lastVerifiedAt = CACurrentMediaTime()
			lastVerifiedRecord = checkedRecord
			_finishTransition(to: .connected, diagnostic: .ready)
			CellularAssistManager.shared.connectionDidSucceed()
			_log("Device transport and pairing were verified.", level: .notice)
			return true
		} else {
			await _resetRSDTunnel()
			guard _reconciliationIsCurrent(epoch: epoch) else { throw CancellationError() }
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

	/// Library and foreground recovery share one operation and an explicit result.
	public func verifyForAppRefresh() async -> Bool {
		guard !selfUpdateHandoffPending else { return false }
		guard await _waitForInitialActivation() else { return false }
		if let task = appRefreshConnectionTask {
			return await _joinAppRefreshConnection(task)
		}
		let id = UUID()
		appRefreshConnectionID = id
		let task = Task { [weak self] in
			guard let self else { return false }
			defer {
				if self.appRefreshConnectionID == id {
					self.appRefreshConnectionTask = nil
					self.appRefreshConnectionID = nil
				}
			}
			return await self._verifyAndRecoverForAppRefresh()
		}
		appRefreshConnectionTask = task
		return await _joinAppRefreshConnection(task)
	}

	private func _waitForInitialActivation() async -> Bool {
		guard !Task.isCancelled else { return false }
		if hasCompletedInitialActivation { return true }
		guard UIApplication.shared.applicationState != .background else { return false }
		let id = UUID()
		let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		connectionWorkWaiters[id] = continuation
		defer { connectionWorkWaiters.removeValue(forKey: id); continuation.finish() }
		continuation.yield(())
		return await withTaskCancellationHandler {
			for await _ in events {
				guard !Task.isCancelled, UIApplication.shared.applicationState != .background else { return false }
				if hasCompletedInitialActivation { return true }
			}
			return false
		} onCancel: { continuation.finish() }
	}

	private func _joinAppRefreshConnection(_ task: Task<Bool, Never>) async -> Bool {
		// A caller can leave without cancelling work still owned by foreground recovery.
		let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let waiter = Task { continuation.yield(await task.value); continuation.finish() }
		defer { waiter.cancel(); continuation.finish() }
		return await withTaskCancellationHandler {
			for await result in events { return !Task.isCancelled && result }
			return false
		} onCancel: { continuation.finish() }
	}

	private func _verifyAndRecoverForAppRefresh() async -> Bool {
		guard UIApplication.shared.applicationState == .active, isIDeviceInstallationMode,
			!selfUpdateHandoffPending else { return false }
		if isUpdating || CellularAssistManager.shared.isBusy {
			let wasStopping = state == .disconnecting
			if await _waitForRefreshConnection() { return !Task.isCancelled }
			guard wasStopping, !Task.isCancelled else { return false }
		}
		let epoch = connectionEpoch
		if await reconcile(force: true) { return !Task.isCancelled && isConnected }
		guard !Task.isCancelled, connectionEpoch == epoch else { return false }
		if isUpdating || CellularAssistManager.shared.isBusy {
			return await _waitForRefreshConnection()
		}
		guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
			isConnectAutomaticallyEnabled, !isConnected, !isUpdating,
			_automaticConnectionPrerequisitesReady() else { return false }
		// Exactly one recovery for this refresh; failure never recurses into another.
		_connectForIDeviceMode()
		return await _waitForRefreshConnection()
	}

	private func _waitForRefreshConnection() async -> Bool {
		let cellular = CellularAssistManager.shared
		let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let observation = Publishers.Merge(objectWillChange, cellular.objectWillChange)
			.sink { continuation.yield(()) }
		defer { observation.cancel(); continuation.finish() }
		continuation.yield(())
		return await withTaskCancellationHandler {
			for await _ in events {
				guard !Task.isCancelled, isIDeviceInstallationMode else { return false }
				// Provider/shortcut handoffs intentionally background Aether. Their
				// foreground callback resumes a bounded attempt; don't time their UI.
				if isUpdating || cellular.isBusy { continue }
				return isConnected
			}
			return false
		} onCancel: { continuation.finish() }
	}

	@discardableResult
	public func reconcile(force: Bool = false, cellularAssistTransaction: Bool = false) async -> Bool {
		guard hasCompletedInitialActivation, !selfUpdateHandoffPending else { return false }
		guard UIApplication.shared.applicationState != .background || hasActiveTunnelDependencies
			|| (tunnelMethod == .localDevVPN && transitionExpectedState != nil)
			|| (force && transitionExpectedState == false) else { return false }
		let waitTimeout = transitionExpectedState == nil ? 4 : min(4, max(0.001, transitionDeadline - CACurrentMediaTime()))
		if let existing = reconciliationTask {
			reconciliationRequiresFreshProbe = reconciliationRequiresFreshProbe || force
			do {
				return try await awaitTunnelReply(timeout: waitTimeout) { complete in
					Task { complete(.success(await existing.value)) }
				}
			} catch { return false }
		}
		let id = UUID()
		reconciliationRequiresFreshProbe = force
		reconciliationID = id
		let task = Task { [weak self] in
			guard let self else { return false }
			defer {
				if self.reconciliationID == id {
					self.reconciliationTask = nil
					self.reconciliationID = nil
				}
			}
			return await self._reconcile(force: force, cellularAssistTransaction: cellularAssistTransaction)
		}
		reconciliationTask = task
		do {
			return try await awaitTunnelReply(timeout: waitTimeout) { complete in
				Task { complete(.success(await task.value)) }
			}
		} catch {
			guard reconciliationID == id else { return false }
			_cancelReconciliation()
			if !Task.isCancelled {
				if transitionExpectedState != nil { _expireConnectionAttempt() }
				else {
					_finishTransition(to: .disconnected, diagnostic: .error(.localized("The device connection timed out. Retry connecting.")))
				}
			}
			_log("Device verification wait ended: \(error.localizedDescription)", category: "Tunnel", level: .warning)
			return false
		}
	}

	private func _reconcile(force: Bool, cellularAssistTransaction: Bool) async -> Bool {
		guard connectionPreparation == nil else { return false }
		guard !awaitingInitialActivation || UIApplication.shared.applicationState == .active else { return false }
		let reconciliationGeneration = transitionGeneration
		let epoch = connectionEpoch
		let method = tunnelMethod
		if method == .localDevVPN, localDevVPNHandoffGeneration != nil { return false }
		// The embedded stop owns completion; passive events must not finish it
		// while stopVPNTunnel is still disconnecting. Its owner reconciles forcibly.
		if method == .inApp, state == .disconnecting, !force { return false }
		guard isIDeviceInstallationMode else {
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
			return false
		}
		guard !CellularAssistManager.shared.isAutomaticRecoveryInProgress || cellularAssistTransaction else {
			return false
		}
		_syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return false
		}
		guard _providerIsAvailable() else { return false }
		if method == .inApp, physicalNetworkState == .cellularOnly,
			case .failed = CellularAssistManager.shared.state { return false }
		if method == .localDevVPN, needsLocalDevVPNCellularRecovery {
			if isUpdating { _finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable) }
			return false
		}

		// Coalesced heartbeat events can reuse a freshly verified stable transport
		// before repeating profile/preference work. Foreground and network events
		// invalidate lastVerifiedAt; explicit actions and forced checks always probe.
		if !force, !reconciliationRequiresFreshProbe, !cellularAssistTransaction, transitionExpectedState == nil, isConnected,
			lastVerifiedRecord == pairingVerification.record,
			CACurrentMediaTime() - lastVerifiedAt < 1,
			(method != .inApp || EmbeddedTunnelManager.shared.isConnected) {
			return false
		}

		let expectedState = transitionExpectedState
		let now = CACurrentMediaTime()
		let isExpired = now >= transitionDeadline

		if method == .inApp {
			HeartbeatManager.shared.ipAddress = EmbeddedTunnelManager.shared.peerIPOnly
			let hasProfile = await _hasRequiredTunnelProfile()
			guard _reconciliationIsCurrent(epoch: epoch) else { return false }
			guard hasProfile else {
				await _resetRSDTunnel()
				guard _reconciliationIsCurrent(epoch: epoch) else { return false }
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return false
			}
			await EmbeddedTunnelManager.shared.refresh()
			guard _reconciliationIsCurrent(epoch: epoch) else { return false }
			let embeddedReady = EmbeddedTunnelManager.shared.isConnected
			guard embeddedReady else {
				if expectedState == true && !force && !isExpired {
					return false
				}
				await _resetRSDTunnel()
				guard _reconciliationIsCurrent(epoch: epoch) else { return false }
				_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
				return false
			}
			if !cellularAssistTransaction, !isConnected,
				physicalNetworkState == .cellularOnly,
				_beginCellularAssistIfEligible() {
				return false
			}
		}

		// Step 2: Full Installation Proxy check (validates pairing + transport)
		let checkedRecord = _syncPairingRecord()
		if let checkedRecord { pairingVerification.beginChecking(checkedRecord) }
		let includeApps = !isConnected && expectedState != false
		let verificationStarted = ProcessInfo.processInfo.systemUptime
		let verificationID = UUID()
		activeVerificationID = verificationID
		defer { if activeVerificationID == verificationID { activeVerificationID = nil } }
		let probeTimeout = transitionExpectedState == nil ? 4 : min(4, max(0.001, transitionDeadline - CACurrentMediaTime()))
		var verification: Task<DeviceConnectionCheck, Never>?
		let checkResult: DeviceConnectionCheck
		do {
			checkResult = try await awaitTunnelReply(timeout: probeTimeout) { complete in
				let worker = Task.detached(priority: .userInitiated) {
					let result = HeartbeatManager.shared.checkDeviceConnection(
						timeoutInSeconds: min(1.5, probeTimeout), includeApps: includeApps,
						onVerified: { complete(.success(DeviceConnectionCheck(isConnected: true))) })
					complete(.success(result))
					return result
				}
				verification = worker
				if includeApps {
					// Keep the same native client for the browse, but give readiness
					// and app loading independent completion and cancellation.
					InstalledAppsStore.shared.stageInitialBrowse(Task {
						do {
							let apps: [AppInfo] = try await awaitTunnelReply(timeout: 4) { finish in
								Task {
									let result = await worker.value
									if let apps = result.apps { finish(.success(apps)) }
									else { finish(.failure(NSError(domain: "Aether.AppBrowse", code: 1,
										userInfo: [NSLocalizedDescriptionKey: result.error ?? "Unable to load installed apps."]))) }
								}
							}
							try Task.checkCancellation()
							return apps
						} catch { worker.cancel(); throw error }
					})
				}
			}
		} catch {
			verification?.cancel()
			guard !(error is CancellationError), _reconciliationIsCurrent(epoch: epoch),
				activeVerificationID == verificationID, reconciliationGeneration == transitionGeneration else { return false }
			checkResult = DeviceConnectionCheck(isConnected: false, error: error.localizedDescription, isTransientTransportFailure: true)
		}
		guard
			_reconciliationIsCurrent(epoch: epoch),
			activeVerificationID == verificationID,
			reconciliationGeneration == transitionGeneration
		else {
			return false
		}
		guard !CellularAssistManager.shared.isAutomaticRecoveryInProgress || cellularAssistTransaction else {
			return false
		}

		guard _recordStillMatches(checkedRecord) else { return false }
		if let checkedRecord {
			pairingVerification.finishChecking(checkedRecord, succeeded: checkResult.isConnected)
		}
		if await _discardRejectedRecord(checkResult, record: checkedRecord) != .notRejected { return false }
		guard _reconciliationIsCurrent(epoch: epoch) else { return false }
		_log("Device verification seconds=\(ProcessInfo.processInfo.systemUptime - verificationStarted) initialBrowse=\(includeApps) appCount=\(checkResult.apps?.count ?? -1).", level: .debug)

		if checkResult.isConnected {
			if !includeApps, let apps = checkResult.apps { InstalledAppsStore.shared.stageVerifiedApps(apps) }
			lastVerifiedAt = CACurrentMediaTime()
			lastVerifiedRecord = checkedRecord
			if expectedState == false && !force && !isExpired {
				// LocalDevVPN can remain reachable briefly after a disconnect request.
				// Keep polling instead of cancelling the transition on that stale result.
				return false
			}
			_finishTransition(to: .connected, diagnostic: .ready)
			CellularAssistManager.shared.connectionDidSucceed()
			return true
		} else {
			if expectedState == true && !force && !isExpired && checkResult.isTransientTransportFailure {
				return false
			}
			if !checkResult.rejectsPairingRecord, _beginCellularAssistIfEligible() { return false }
			lastVerifiedAt = 0
			rsdCleanupTask?.cancel()
			rsdCleanupTask = Task.detached(priority: .utility) { HeartbeatManager.shared.resetRSDTunnel() }
			guard _reconciliationIsCurrent(epoch: epoch) else { return false }
			if !checkResult.isTransientTransportFailure { automaticRetryBlocked = true }
			if checkResult.rejectsPairingRecord {
				_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
			} else {
				let message = checkResult.error ?? "Device connection failed"
				_finishTransition(to: .disconnected, diagnostic: .error(message))
			}
		}
		return false
	}

	// MARK: - Private Helpers

	private func _reconciliationIsCurrent(epoch: UInt64) -> Bool {
		!Task.isCancelled && connectionEpoch == epoch
	}


	/// Refresh stored-file status without launching a VPN or adding another probe.
	public func refreshStoredPairingState() {
		_syncPairingRecord()
	}

	@discardableResult
	private func _syncPairingRecord() -> PairingRecordIdentity? {
		let fileIsPresent = HeartbeatManager.hasPairingFile()
		if hasPairingFile != fileIsPresent { hasPairingFile = fileIsPresent }
		let record = hasPairingFile ? PairingRecordIdentity(fileURL: URL(fileURLWithPath: HeartbeatManager.activePairingFile())) : nil
		if pairingVerification.record != record {
			automaticRetryBlocked = false
			lastVerifiedAt = 0
			pairingVerification.select(record)
		}
		InstallationAppProxy.setIconDeviceScope(pairingDigest: record?.digest, endpoint: HeartbeatManager.shared.ipAddress)
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
			rsdCleanupTask?.cancel()
			rsdCleanupTask = Task.detached(priority: .utility) { HeartbeatManager.shared.resetRSDTunnel() }
			return .discarded
		} catch {
			_finishTransition(to: .disconnected, diagnostic: .invalidPairing)
			_log("Could not discard the rejected pairing record: \(error.localizedDescription)", category: "Pairing", level: .error)
			return .failed
		}
	}

	@discardableResult
	private func _resetRSDTunnel() async -> Bool {
		lastVerifiedAt = 0
		let cleanup = Task.detached(priority: .utility) { HeartbeatManager.shared.resetRSDTunnel() }
		do {
			let _: Void = try await withTaskCancellationHandler {
				try await awaitTunnelReply { complete in
					Task { await cleanup.value; complete(.success(())) }
				}
			} onCancel: { cleanup.cancel() }
			return true
		} catch {
			cleanup.cancel()
			// The owning attempt's deadline/cancellation retires its generation.
			// Never wait indefinitely for a native connection holding the RSD lock.
			_log("RSD cleanup wait ended: \(error.localizedDescription)", category: "Tunnel", level: .warning)
			return false
		}
	}

	private func _hasRequiredTunnelProfile() async -> Bool {
		guard tunnelMethod == .inApp else {
			requiresInAppTunnelSetup = false
			return true
		}
		let epoch = connectionEpoch
		do {
			let hasProfile = try await EmbeddedTunnelManager.shared.hasSavedConfiguration()
			guard _reconciliationIsCurrent(epoch: epoch), tunnelMethod == .inApp else { return false }
			if requiresInAppTunnelSetup != !hasProfile { requiresInAppTunnelSetup = !hasProfile }
			return hasProfile
		} catch {
			guard _reconciliationIsCurrent(epoch: epoch) else { return false }
			connectionEpoch &+= 1
			_finishTransition(to: .disconnected, diagnostic: .error(error.localizedDescription))
			_log("VPN preference read failed: \(error.localizedDescription)", category: "Tunnel", level: .warning)
			return false
		}
	}

	/// Routes one ordinary reconciliation through cellular recovery only after
	/// the in-app tunnel is running and the active physical route is cellular.
	private func _beginTransportRecovery(automatically: Bool = true) {
		guard isIDeviceInstallationMode, _providerIsAvailable(), hasPairingFile else { return }
		_cancelReconciliation()
		connectionEpoch &+= 1
		automaticAttemptEpoch = automatically ? connectionEpoch : nil
		let generation = UUID()
		transitionGeneration = generation
		transitionExpectedState = true
		transitionDeadline = CACurrentMediaTime() + 4
		state = .connecting
		diagnostic = .checking
		_armAttemptTimeout(epoch: connectionEpoch, seconds: 4)
		_startTransitionPolling(generation: generation, expectedState: true)
	}

	private func _beginCellularAssistIfEligible() -> Bool {
		// Starting the VPN and connecting to the developer service are separate
		// steps. Never ask to change Mobile Data while the VPN is still starting.
		guard tunnelMethod == .inApp, physicalNetworkState == .cellularOnly,
			EmbeddedTunnelManager.shared.isConnected else { return false }
		let started = CellularAssistManager.shared.beginBootstrapIfPossible(
			cellularOnly: true,
			tunnelIsRunning: true
		)
		if started {
			_pauseForCellularRecovery(manual: false)
			return true
		}
		let manual = CellularAssistManager.shared.beginManualRecoveryIfNeeded(
			cellularOnly: true,
			tunnelIsRunning: true
		)
		if manual { _pauseForCellularRecovery(manual: true) }
		return manual
	}

	private func _pauseForCellularRecovery(manual: Bool) {
		attemptTimeoutTask?.cancel()
		attemptTimeoutTask = nil
		transitionTask?.cancel()
		transitionTask = nil
		if manual {
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
		} else {
			// Shortcuts owns the required network change. Its callback starts a
			// separate bounded transport verification after Mobile Data is off.
			transitionDeadline = 0
		}
	}

	public func cellularRecoveryDidFinish() {
		let cellular = CellularAssistManager.shared
		guard !cellular.isBusy else { return }
		if !isConnected, state == .connecting {
			_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
		}
		if case .failed(let message) = cellular.state {
			automaticRetryBlocked = true
			if case .providerMissing = diagnostic {
				// Keep a known provider failure ahead of an unrelated helper error.
			} else if hasPairingFile, !requiresInAppTunnelSetup {
				_finishTransition(to: .disconnected, diagnostic: .error(message))
			}
			if UIApplication.shared.applicationState == .background { handleAppBackground() }
			return
		}
		if !cellular.isEnabled, physicalNetworkState == .cellularOnly,
			tunnelMethod == .inApp, EmbeddedTunnelManager.shared.isConnected {
			_ = cellular.beginManualRecoveryIfNeeded(cellularOnly: true, tunnelIsRunning: true)
			_pauseForCellularRecovery(manual: true)
		}
		if UIApplication.shared.applicationState == .background {
			handleAppBackground()
		} else if !isConnected, !isUpdating, isConnectAutomaticallyEnabled,
			isIDeviceInstallationMode, _automaticConnectionPrerequisitesReady() {
			_connectForIDeviceMode()
		}
	}

	/// One deadline for route settlement and authentication after the helper's
	/// data-off callback. App browsing starts only after Mobile Data is restored.
	public func verifyCellularTransport() async -> Bool {
		guard isIDeviceInstallationMode, tunnelMethod == .inApp,
			CellularAssistManager.shared.state == .establishingTransport else { return false }
		let record = _syncPairingRecord()
		guard hasPairingFile else {
			_finishTransition(to: .disconnected, diagnostic: .pairingMissing)
			return false
		}
		guard _providerIsAvailable() else { return false }
		guard EmbeddedTunnelManager.shared.isConnected else {
			_finishTransition(to: .disconnected, diagnostic: .error(.localized("The VPN disconnected during Cellular Assist.")))
			return false
		}
		_cancelReconciliation()
		let epoch = connectionEpoch
		let id = UUID()
		activeVerificationID = id
		defer { if activeVerificationID == id { activeVerificationID = nil } }
		let deadline = CACurrentMediaTime() + 4
		lastVerifiedAt = 0
		while CACurrentMediaTime() < deadline {
			guard !Task.isCancelled, connectionEpoch == epoch, activeVerificationID == id,
				_recordStillMatches(record) else { return false }
			let remaining = deadline - CACurrentMediaTime()
			guard remaining > 0 else { break }
			if let record { pairingVerification.beginChecking(record) }
			let checkedNetwork = networkGeneration
			let probe = Task.detached(priority: .userInitiated) {
				HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: min(1.5, remaining))
			}
			let result: DeviceConnectionCheck
			do {
				result = try await withTaskCancellationHandler {
					try await awaitTunnelReply(timeout: remaining) { complete in
						Task { complete(.success(await probe.value)) }
					}
				} onCancel: { probe.cancel() }
			} catch {
				probe.cancel()
				break
			}
			guard !Task.isCancelled, connectionEpoch == epoch, activeVerificationID == id,
				_recordStillMatches(record) else { return false }
			// A route event during a native probe retires that result, but the
			// recovery keeps its original deadline and can probe the new route.
			guard networkGeneration == checkedNetwork else { continue }
			if let record { pairingVerification.finishChecking(record, succeeded: result.isConnected) }
			if result.rejectsPairingRecord {
				_ = await _discardRejectedRecord(result, record: record)
				return false
			}
			guard EmbeddedTunnelManager.shared.isConnected else {
				_finishTransition(to: .disconnected, diagnostic: .error(.localized("The VPN disconnected during Cellular Assist.")))
				return false
			}
			if result.isConnected {
				lastVerifiedAt = CACurrentMediaTime()
				lastVerifiedRecord = record
				_finishTransition(to: .connected, diagnostic: .ready)
				_log("Cellular transport authenticated; restoring Mobile Data before browsing apps.", category: "Cellular Assist", level: .notice)
				return true
			}
			guard result.isTransientTransportFailure else {
				automaticRetryBlocked = true
				_finishTransition(to: .disconnected, diagnostic: .error(result.error ?? .localized("Device connection failed.")))
				return false
			}
			// The OFF callback can precede the route change. Retry only transient
			// service failures; an offline Internet path is valid for local access.
			do { try await Task.sleep(for: .seconds(min(0.2, max(0, deadline - CACurrentMediaTime())))) }
			catch { return false }
		}
		guard !Task.isCancelled, connectionEpoch == epoch, activeVerificationID == id else { return false }
		_expireConnectionAttempt()
		return false
	}

	/// Returns true whenever cellular recovery owns the route, including an
	/// already-running automatic or manual recovery. This prevents an explicit
	/// action from falling through to a socket probe during the transition.
	private func _routeCellularRecoveryIfNeeded() -> Bool {
		guard tunnelMethod == .inApp, physicalNetworkState == .cellularOnly else { return false }
		if case .failed = CellularAssistManager.shared.state { return true }
		if isConnected, !CellularAssistManager.shared.requiresTunnelConnection { return false }
		if CellularAssistManager.shared.isAutomaticRecoveryInProgress
			|| CellularAssistManager.shared.isWaitingForManualRecovery {
			return true
		}
		return _beginCellularAssistIfEligible()
	}

	/// Cellular Assist can briefly background Aether while the helper changes
	/// Mobile Data. Keep the initiating action alive across that handoff instead
	/// of reporting an immediate transport error. Callback recovery handles a lost
	/// handoff; manual guidance returns immediately rather than polling.
	private func _waitForCellularRecovery() async -> Bool {
		let cellular = CellularAssistManager.shared
		let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let observation = Publishers.Merge(objectWillChange, cellular.objectWillChange)
			.sink { continuation.yield(()) }
		defer { observation.cancel(); continuation.finish() }
		continuation.yield(())
		for await _ in changes {
			guard !Task.isCancelled else { return false }
			if isConnected, !cellular.isBusy { return true }
			// Manual intervention is an actionable fallback, not a hidden minute
			// of polling an unreachable service while Mobile Data remains on.
			if cellular.isWaitingForManualRecovery || !cellular.requiresTunnelConnection { return false }
		}
		return false
	}

	private func _setLocalDevVPNConnection(enabled: Bool, generation: UUID) {
		let action = enabled ? "enable" : "disable"
		guard let url = URL(string: "localdevvpn://\(action)?scheme=aether") else {
			_cancelTransition()
			_log("Could not create the LocalDevVPN connection URL.", category: "Tunnel", level: .error)
			return
		}

		// The helper deliberately takes the foreground. Only verification after
		// returning to Aether gets a transport deadline, not time spent in its UI.
		localDevVPNHandoffGeneration = generation
		attemptTimeoutTask?.cancel()
		attemptTimeoutTask = nil

		UIApplication.shared.open(url, options: [:]) { [weak self] didOpen in
			Task { @MainActor [weak self] in
				guard let self else { return }
				guard self.transitionGeneration == generation else { return }
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
				try await EmbeddedTunnelManager.shared.start {
					self.transitionGeneration == generation && !Task.isCancelled
						&& (CellularAssistManager.shared.requiresTunnelConnection || CACurrentMediaTime() < self.transitionDeadline)
				}
				guard transitionGeneration == generation, !Task.isCancelled else { return }
				guard await _resetRSDTunnel() else {
					if transitionGeneration == generation { _expireConnectionAttempt() }
					return
				}
				guard transitionGeneration == generation, !Task.isCancelled else { return }
				guard !CellularAssistManager.shared.requiresTunnelConnection else { return }
				// start() returns after NetworkExtension reports Connected. Only
				// now may cellular recovery change the route for service verification.
				if _beginCellularAssistIfEligible() { return }
				_startTransitionPolling(generation: generation, expectedState: true)
			} catch {
				guard transitionGeneration == generation else { return }
				_finishTransition(to: .disconnected, diagnostic: .error(error.localizedDescription))
				_log("In-app tunnel failed to start: \(error.localizedDescription)", category: "Tunnel", level: .error)
			}
		} else {
			await EmbeddedTunnelManager.shared.stop {
				self.transitionGeneration == generation && !Task.isCancelled
			}
			guard transitionGeneration == generation else { return }
			let diagnostic: DeviceDiagnosticStatus
			if case .error(let message) = EmbeddedTunnelManager.shared.state { diagnostic = .error(message) }
			else { diagnostic = .tunnelUnavailable }
			// Stop is already delivered to iOS. Cleanup cannot keep the UI in
			// Disconnecting. A replacement start cancels this retirement, including
			// its native lock wait, before establishing a newer RSD session.
			rsdCleanupTask?.cancel()
			rsdCleanupTask = Task.detached(priority: .utility) { HeartbeatManager.shared.resetRSDTunnel() }
			_finishTransition(to: .disconnected, diagnostic: diagnostic)
		}
	}

	private func _startTransitionPolling(generation: UUID, expectedState: Bool) {
		transitionTask?.cancel()
		transitionTask = Task { [weak self] in
			guard let self else { return }
			while !Task.isCancelled, self.transitionGeneration == generation {
				guard CACurrentMediaTime() < self.transitionDeadline else {
					self._expireConnectionAttempt()
					return
				}
				await self.reconcile()
				guard !Task.isCancelled, self.transitionGeneration == generation else { return }
				if (expectedState && self.isConnected) || (!expectedState && self.state == .disconnected) { return }
				let remaining = max(0, self.transitionDeadline - CACurrentMediaTime())
				do { try await Task.sleep(for: .seconds(min(0.2, remaining))) }
				catch { return }
			}
		}
	}

	private func _cancelTransition() {
		automaticRetryBlocked = true
		connectionEpoch &+= 1
		pendingTunnelMethod = nil
		_finishTransition(to: .disconnected, diagnostic: .tunnelUnavailable)
	}

	private func _finishTransition(to newState: DeviceConnectionState, diagnostic newDiagnostic: DeviceDiagnosticStatus) {
		awaitingInitialActivation = false
		automaticAttemptEpoch = nil
		if newState == .connected { hasReturnedFromLocalDevVPN = false }
		switch newDiagnostic {
		case .error, .providerMissing, .pairingMissing, .invalidPairing:
			hasReturnedFromLocalDevVPN = false
			CellularAssistManager.shared.networkNoLongerNeedsManualRecovery()
		default: break
		}
		activeVerificationID = nil
		connectionPreparation = nil
		preparationTask?.cancel()
		preparationTask = nil
		connectionTask?.cancel()
		connectionTask = nil
		attemptTimeoutTask?.cancel()
		attemptTimeoutTask = nil
		if newState != .connected { lastVerifiedAt = 0 }
		let previousState = state
		let previousDiagnostic = diagnostic
		let nextProvider = transitionExpectedState == false && newState == .disconnected ? pendingTunnelMethod : nil
		pendingTunnelMethod = nil
		transitionGeneration = nil
		localDevVPNHandoffGeneration = nil
		transitionExpectedState = nil
		transitionDeadline = 0
		transitionTask?.cancel()
		transitionTask = nil
		if state != newState { state = newState }
		if diagnostic != newDiagnostic { diagnostic = newDiagnostic }
		if previousState != newState || previousDiagnostic != newDiagnostic {
			_log("Device state is now \(_stateDescription(newState)): \(newDiagnostic.localizedDescription)")
		}
		if let nextProvider { setTunnelMethod(nextProvider) }
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

#if !targetEnvironment(macCatalyst)
/// A brief system grant for retiring an idle VPN; never an ongoing keep-alive.
@MainActor
private final class IdleTunnelStopLease {
	private var identifier: UIBackgroundTaskIdentifier = .invalid
	init() {
		guard UIApplication.shared.applicationState == .background else { return }
		identifier = UIApplication.shared.beginBackgroundTask(withName: "Disconnect idle tunnel") { [weak self] in
			Task { @MainActor in self?.end() }
		}
	}
	func end() {
		guard identifier != .invalid else { return }
		UIApplication.shared.endBackgroundTask(identifier)
		identifier = .invalid
	}
}
#endif
