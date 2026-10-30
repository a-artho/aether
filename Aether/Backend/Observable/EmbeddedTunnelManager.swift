//
//  EmbeddedTunnelManager.swift
//  Aether
//

import Combine
import Foundation
import IDeviceSwift

/// System callbacks and native cleanup may outlive the caller. Resolve once,
/// including cancellation/timeout, and ignore any eventual obsolete callback.
private final class TunnelOperationReply<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Value, Error>?
	private var result: Result<Value, Error>?
	private var timeoutTask: Task<Void, Never>?

	func install(_ continuation: CheckedContinuation<Value, Error>, timeout: Double) {
		lock.lock()
		if let result {
			lock.unlock()
			continuation.resume(with: result)
			return
		}
		self.continuation = continuation
		timeoutTask = Task.detached { [weak self] in
			do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
			self?.complete(.failure(NSError(domain: "Aether.Tunnel", code: 1,
				userInfo: [NSLocalizedDescriptionKey: "The device connection timed out. Retry connecting."])))
		}
		lock.unlock()
	}

	func complete(_ result: Result<Value, Error>) {
		lock.lock()
		guard self.result == nil else { lock.unlock(); return }
		self.result = result
		let continuation = self.continuation
		self.continuation = nil
		let timeout = timeoutTask
		timeoutTask = nil
		lock.unlock()
		timeout?.cancel()
		continuation?.resume(with: result)
	}
}

@MainActor
func awaitTunnelReply<Value: Sendable>(timeout: Double = 4,
	_ request: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
) async throws -> Value {
	let reply = TunnelOperationReply<Value>()
	return try await withTaskCancellationHandler {
		try await withCheckedThrowingContinuation { continuation in
			reply.install(continuation, timeout: timeout)
			guard !Task.isCancelled else { reply.complete(.failure(CancellationError())); return }
			request { reply.complete($0) }
		}
	} onCancel: { reply.complete(.failure(CancellationError())) }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import NetworkExtension
#endif

public enum DeviceTunnelMethod: String, CaseIterable, Identifiable {
	case inApp = "in-app"
	case localDevVPN = "localdevvpn"

	public var id: String { rawValue }

	public var displayName: String {
		switch self {
		case .inApp:
			return .localized("In-App")
		case .localDevVPN:
			return "LocalDevVPN"
		}
	}
}

public enum EmbeddedTunnelState: Equatable {
	case unavailable
	case disconnected
	case preparing
	case connecting
	case connected
	case disconnecting
	case error(String)
}

public enum EmbeddedTunnelError: LocalizedError {
	case unavailable
	case extensionMissing
	case invalidConfiguration
	case providerNotReady

	public var errorDescription: String? {
		switch self {
		case .unavailable:
			return .localized("In-app tunneling is only available on iPhone and iPad.")
		case .extensionMissing:
			return .localized("The Aether tunnel extension is missing.")
		case .invalidConfiguration:
			return .localized("The Aether tunnel configuration is invalid.")
		case .providerNotReady:
			return .localized("The Aether tunnel did not become ready.")
		}
	}
}

// The system callback transfers these managers once; all subsequent access is main-actor owned.
private struct TunnelManagersHandoff: @unchecked Sendable {
    private let values: [NETunnelProviderManager]
    init(_ values: [NETunnelProviderManager]) { self.values = values }
    @MainActor var managers: [NETunnelProviderManager] { values }
}

// NotificationCenter permits removal from any thread; the token is immutable.
private final class TunnelStatusObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    func cancel() { NotificationCenter.default.removeObserver(token) }
    deinit { cancel() }
}

@MainActor
public final class EmbeddedTunnelManager: ObservableObject {
	public static let shared = EmbeddedTunnelManager()

	public static let defaultInterfaceAddress = "10.7.1.1/32"
	public static let defaultPeerAddress = "10.7.0.1/32"
	public static let defaultAllowIntermediate = true

	public static let interfaceAddressKey = "TunnelIfaceIP"
	public static let peerAddressKey = "TunnelPeerIP"
	public static let allowIntermediateAddressesKey = "allowIntermediateAddresses"

	@Published public private(set) var interfaceAddress: String
	@Published public private(set) var peerAddress: String
	@Published public private(set) var allowIntermediateAddresses: Bool
	@Published public private(set) var state: EmbeddedTunnelState

	public var peerIPOnly: String {
		peerAddress.split(separator: "/").first.map(String.init) ?? "10.7.0.1"
	}

	#if os(iOS) && !targetEnvironment(macCatalyst)
	private static let managedMarkerKey = "AetherManagedTunnel"
	private static let schemaKey = "AetherTunnelSchema"
	private static let schema = 1
	private var manager: NETunnelProviderManager?
	private var statusObserver: NSObjectProtocol?
	private var configurationObserver: NSObjectProtocol?
	private var cachedManagers: [NETunnelProviderManager]?
	private var managersLoadedAt: TimeInterval = 0
	private var managersRevision = UUID()
	private var managersLoad: (id: UUID, task: Task<TunnelManagersHandoff, Error>)?
	#endif

	private init() {
		let iface = UserDefaults.standard.string(forKey: Self.interfaceAddressKey) ?? Self.defaultInterfaceAddress
		let peer = UserDefaults.standard.string(forKey: Self.peerAddressKey) ?? Self.defaultPeerAddress
		let allowIntermediate = UserDefaults.standard.object(forKey: Self.allowIntermediateAddressesKey) as? Bool ?? Self.defaultAllowIntermediate

		self.interfaceAddress = iface
		self.peerAddress = peer
		self.allowIntermediateAddresses = allowIntermediate

		let peerIP = peer.split(separator: "/").first.map(String.init) ?? "10.7.0.1"
		HeartbeatManager.shared.ipAddress = peerIP

		#if os(iOS) && !targetEnvironment(macCatalyst)
		state = .disconnected
		statusObserver = NotificationCenter.default.addObserver(
			forName: .NEVPNStatusDidChange,
			object: nil,
			queue: .main
		) { [weak self] notification in
			guard let connection = notification.object as? NEVPNConnection else { return }
			let identity = ObjectIdentifier(connection)
			Task { @MainActor [weak self] in
				guard let self, let current = self.manager?.connection, identity == ObjectIdentifier(current) else { return }
				// The main-actor hop may outlive this notification's status.
				self.updateState(for: current.status)
			}
		}
		configurationObserver = NotificationCenter.default.addObserver(
			forName: .NEVPNConfigurationChange, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?.invalidateConfigurationCache() }
		}
		#else
		state = .unavailable
		#endif
	}

	isolated deinit {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		if let statusObserver {
			NotificationCenter.default.removeObserver(statusObserver)
		}
		if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
		#endif
	}

	public var isConnected: Bool {
		if case .connected = state { return true }
		return false
	}

	public var isRunning: Bool {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		switch manager?.connection.status {
		case .connected?, .connecting?, .reasserting?: return true
		default: return false
		}
		#else
		return isConnected
		#endif
	}

	/// Wait for the embedded VPN shutdown confirmation needed before iOS
	/// replaces Aether. Keep the NetworkExtension-specific waiter private.
	func waitForSelfUpdateDisconnection() async -> Bool {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		await waitForDisconnected()
		#else
		state == .disconnected
		#endif
	}

	public var isProviderAvailable: Bool {
		#if targetEnvironment(simulator)
		return true
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		return (try? discoverProviderIdentifier()) != nil
		#else
		return false
		#endif
	}

	/// Send a superseding stop without waiting for preferences or RSD locks.
	public func requestStopIfRunning() {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		guard let manager else { return }
		switch manager.connection.status {
		case .connected, .connecting, .reasserting:
			manager.connection.stopVPNTunnel()
		default: break
		}
		#endif
	}

	/// Checks whether Aether already has a saved tunnel profile without creating
	/// one or triggering iOS's VPN-profile approval prompt.
	public func hasSavedConfiguration() async throws -> Bool {
		#if targetEnvironment(simulator)
		return true
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		do {
			let providerIdentifier = try discoverProviderIdentifier()
			return try await loadManagers().contains { manager in
				Self.isAetherManaged(manager)
					&& (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
			}
		} catch {
			_log("Could not check for an in-app tunnel configuration: \(error.localizedDescription)", level: .warning)
			throw error
		}
		#else
		return false
		#endif
	}

	public func invalidateConfigurationCache() {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		cachedManagers = nil
		managersRevision = UUID()
		managersLoad = nil
		#endif
	}

	public func refresh() async {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		let revision = managersRevision
		do {
			let providerIdentifier = try discoverProviderIdentifier()
			let managers = try await loadManagers()
			guard !Task.isCancelled, managersRevision == revision else { return }
			let matching = managers.filter {
				Self.isAetherManaged($0)
					&& ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
			}
			manager = matching.first(where: { $0.connection.status == .connected || $0.connection.status == .connecting }) ?? matching.first
			updateState(for: manager?.connection.status ?? .disconnected)
		} catch {
			guard !Task.isCancelled, managersRevision == revision else { return }
			_setState(.error(error.localizedDescription))
		}
		#endif
	}

	@discardableResult
	public func prepare(shouldProceed: () -> Bool = { true }) async throws -> Bool {
		guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
		#if targetEnvironment(simulator)
		state = .disconnected
		return true
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		state = .preparing
		let providerIdentifier = try discoverProviderIdentifier()
		let managers = try await loadManagers()
		guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
		let aetherManagers = managers.filter(Self.isAetherManaged)
		let matchingManagers = aetherManagers.filter {
			($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
		}

		let managerToKeep = matchingManagers.first(where: {
			switch $0.connection.status {
			case .connected, .connecting, .reasserting:
				return true
			default:
				return false
			}
		}) ?? matchingManagers.first

		for staleManager in aetherManagers where staleManager !== managerToKeep {
			guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
			try? await remove(staleManager)
		}
		guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
		if aetherManagers.count > 1 {
			_log("Removed stale in-app tunnel configurations.", level: .warning)
		}

		let selectedManager: NETunnelProviderManager
		if let managerToKeep {
			selectedManager = managerToKeep
		} else {
			let newManager = NETunnelProviderManager()
			configure(newManager, providerIdentifier: providerIdentifier)
			try await save(newManager)
			guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
			try await load(newManager)
			guard shouldProceed(), !Task.isCancelled else { throw CancellationError() }
			selectedManager = newManager
			_log("Created the in-app tunnel configuration.")
		}
		manager = selectedManager
		updateState(for: selectedManager.connection.status)
		return true
		#else
		state = .unavailable
		throw EmbeddedTunnelError.unavailable
		#endif
	}

	public func start(shouldStart: () -> Bool = { true }) async throws {
		guard shouldStart() else { throw CancellationError() }
		_log("In-app tunnel start requested.", level: .notice)
		#if targetEnvironment(simulator)
		HeartbeatManager.shared.ipAddress = peerIPOnly
		state = .connected
		return
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		_ = try await prepare(shouldProceed: shouldStart)
		guard shouldStart() else { throw CancellationError() }
		guard let manager else { throw EmbeddedTunnelError.invalidConfiguration }
		if manager.connection.status == .disconnecting {
			guard await waitForDisconnected(), shouldStart() else { throw CancellationError() }
		}

		switch manager.connection.status {
		case .connected:
			state = .connected
			_log("In-app tunnel is already connected.")
			return
		case .connecting, .reasserting:
			state = .connecting
		default:
			if !manager.isEnabled {
				manager.isEnabled = true
				try await save(manager)
				guard shouldStart(), !Task.isCancelled else { throw CancellationError() }
				try await load(manager)
			}
			guard shouldStart() else { throw CancellationError() }
			state = .connecting
			HeartbeatManager.shared.ipAddress = peerIPOnly
			let options: [String: NSObject] = [
				Self.interfaceAddressKey: interfaceAddress as NSString,
				Self.peerAddressKey: peerAddress as NSString,
			]
			try await startTunnel(on: manager, options: options, shouldStart: shouldStart)
		}

		let connected = await waitForConnected()
		guard shouldStart() else { throw CancellationError() }
		guard connected else {
			_setState(.error(EmbeddedTunnelError.providerNotReady.localizedDescription))
			_log("In-app tunnel did not become ready.", level: .error)
			throw EmbeddedTunnelError.providerNotReady
		}
		_setState(.connected)
		#else
		throw EmbeddedTunnelError.unavailable
		#endif
	}

	public func stop(shouldProceed: () -> Bool = { true }) async {
		guard shouldProceed(), !Task.isCancelled else { return }
		_log("In-app tunnel stop requested.")
		#if targetEnvironment(simulator)
		state = .disconnected
		return
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		// A cold-launch start can still be loading preferences when idle-off
		// supersedes it. Find an existing running profile even if prepare() has
		// not yet published its manager. This does not create a VPN profile.
		if manager == nil { await refresh() }
		guard shouldProceed(), !Task.isCancelled else { return }
		guard let manager else {
			state = .disconnected
			return
		}
		guard manager.connection.status != .disconnected, manager.connection.status != .invalid else {
			state = .disconnected
			return
		}
		state = .disconnecting
		manager.connection.stopVPNTunnel()
		let disconnected = await waitForDisconnected()
		guard shouldProceed(), !Task.isCancelled else { return }
		if disconnected {
			_setState(.disconnected)
		} else {
			_setState(.error(.localized("The Aether tunnel did not stop in time.")))
			_log("In-app tunnel did not stop in time.", level: .warning)
		}
		#else
		state = .unavailable
		#endif
	}

	public func updateNetworkConfiguration(
		interface: String,
		peer: String,
		allowIntermediate: Bool
	) async throws {
		try Task.checkCancellation()
		let (_, peerParsed) = try CIDRValidator.shared.validatePair(
			tunnelIfaceInput: interface,
			tunnelPeerInput: peer,
			allowIntermediateAddresses: allowIntermediate
		)

		let normalizedInterface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalizedPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines)

		#if os(iOS) && !targetEnvironment(macCatalyst)
		if let manager {
			let providerIdentifier = try discoverProviderIdentifier()
			configure(
				manager,
				providerIdentifier: providerIdentifier,
				interfaceAddress: normalizedInterface,
				peerAddress: normalizedPeer
			)
			try await save(manager)
			try await load(manager)
		}
		#endif

		// Do not publish the new values until the persisted VPN configuration
		// accepted them. This keeps the UI, heartbeat target, and profile in sync
		// if saving or reloading the profile fails.
		interfaceAddress = normalizedInterface
		peerAddress = normalizedPeer
		allowIntermediateAddresses = allowIntermediate
		UserDefaults.standard.set(interfaceAddress, forKey: Self.interfaceAddressKey)
		UserDefaults.standard.set(peerAddress, forKey: Self.peerAddressKey)
		UserDefaults.standard.set(allowIntermediateAddresses, forKey: Self.allowIntermediateAddressesKey)
		HeartbeatManager.shared.ipAddress = peerParsed.ip
		_log("Updated in-app tunnel network configuration.", level: .notice)

		// Restart policy belongs to DeviceConnectionManager. Persisting settings
		// must never independently restart a superseded/backgrounded connection.
	}

	public func resetNetworkConfiguration() async throws {
		try await updateNetworkConfiguration(
			interface: Self.defaultInterfaceAddress,
			peer: Self.defaultPeerAddress,
			allowIntermediate: Self.defaultAllowIntermediate
		)
	}

	public func resetConfiguration(shouldProceed: () -> Bool = { true }) async {
		_log("Resetting the in-app tunnel configuration.", level: .warning)
		#if os(iOS) && !targetEnvironment(macCatalyst)
		let managers = (try? await loadManagers()) ?? []
		guard shouldProceed(), !Task.isCancelled else { return }
		for manager in managers where Self.isAetherManaged(manager) {
			guard shouldProceed(), !Task.isCancelled else { return }
			manager.connection.stopVPNTunnel()
			try? await remove(manager)
		}
		guard shouldProceed(), !Task.isCancelled else { return }
		self.manager = nil
		_setState(.disconnected)
		#endif
	}
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private extension EmbeddedTunnelManager {
	func discoverProviderIdentifier() throws -> String {
		guard let pluginsURL = Bundle.main.builtInPlugInsURL,
			let pluginURLs = try? FileManager.default.contentsOfDirectory(
				at: pluginsURL,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			) else {
			throw EmbeddedTunnelError.extensionMissing
		}

		for pluginURL in pluginURLs where pluginURL.pathExtension == "appex" {
			guard let bundle = Bundle(url: pluginURL),
				let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
				let pointIdentifier = extensionInfo["NSExtensionPointIdentifier"] as? String,
				pointIdentifier == "com.apple.networkextension.packet-tunnel",
				let bundleIdentifier = bundle.bundleIdentifier else {
				continue
			}
			return bundleIdentifier
		}
		throw EmbeddedTunnelError.extensionMissing
	}

	static func isAetherManaged(_ manager: NETunnelProviderManager) -> Bool {
		guard let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
			return false
		}
		return configuration[managedMarkerKey] as? Bool == true
	}

	func configure(
		_ manager: NETunnelProviderManager,
		providerIdentifier: String,
		interfaceAddress: String? = nil,
		peerAddress: String? = nil
	) {
		let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
		protocolConfiguration.providerBundleIdentifier = providerIdentifier
		protocolConfiguration.serverAddress = "Aether Local Device"
		protocolConfiguration.providerConfiguration = [
			Self.managedMarkerKey: true,
			Self.schemaKey: Self.schema,
			Self.interfaceAddressKey: interfaceAddress ?? self.interfaceAddress,
			Self.peerAddressKey: peerAddress ?? self.peerAddress,
		]
		manager.protocolConfiguration = protocolConfiguration
		manager.localizedDescription = "Aether Local Device"
		manager.isEnabled = true
		manager.isOnDemandEnabled = false
		manager.onDemandRules = nil
	}

	func updateState(for status: NEVPNStatus) {
		let newState: EmbeddedTunnelState
		switch status {
		case .invalid, .disconnected:
			newState = .disconnected
		case .connecting, .reasserting:
			newState = .connecting
		case .connected:
			newState = .connected
		case .disconnecting:
			newState = .disconnecting
		@unknown default:
			newState = .error(.localized("The Aether tunnel reported an unknown state."))
		}
		_setState(newState)
	}

	func waitForConnected() async -> Bool {
		await waitForStatus(.connected, timeout: 6_000_000_000)
	}

	func waitForDisconnected() async -> Bool {
		await waitForStatus(.disconnected, timeout: 6_000_000_000)
	}

	func waitForStatus(_ desired: NEVPNStatus, timeout: UInt64) async -> Bool {
		guard let connection = manager?.connection else { return desired == .disconnected }
		let statuses = AsyncStream<NEVPNStatus> { continuation in
			let observer = NotificationCenter.default.addObserver(
				forName: .NEVPNStatusDidChange, object: connection, queue: nil
			) { notification in
				guard let changed = notification.object as? NEVPNConnection else { return }
				continuation.yield(changed.status)
			}
			let observation = TunnelStatusObservation(observer)
			continuation.onTermination = { _ in observation.cancel() }
			// Subscribe before reading status to cover changes during registration.
			continuation.yield(connection.status)
		}
		return await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				for await status in statuses {
					if status == desired { return true }
					if status == .invalid { return desired == .disconnected }
				}
				return false
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: timeout)
				return false
			}
			let result = await group.next() ?? false
			group.cancelAll()
			return result
		}
	}

	func loadManagers() async throws -> [NETunnelProviderManager] {
		if let cachedManagers, ProcessInfo.processInfo.systemUptime - managersLoadedAt < 60 {
			return cachedManagers
		}
		if let managersLoad { return try await managersLoad.task.value.managers }
		let revision = managersRevision
		let id = UUID()
		let task = Task<TunnelManagersHandoff, Error> {
			try await awaitTunnelReply { complete in
				NETunnelProviderManager.loadAllFromPreferences { managers, error in
					if let error { complete(.failure(error)) }
					else { complete(.success(TunnelManagersHandoff(managers ?? []))) }
				}
			}
		}
		managersLoad = (id, task)
		defer { if managersLoad?.id == id { managersLoad = nil } }
		let managers = try await task.value.managers
		if managersRevision == revision {
			cachedManagers = managers
			managersLoadedAt = ProcessInfo.processInfo.systemUptime
		}
		return managers
	}

	func save(_ manager: NETunnelProviderManager) async throws {
		invalidateConfigurationCache()
		defer { invalidateConfigurationCache() }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			manager.saveToPreferences { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	func load(_ manager: NETunnelProviderManager) async throws {
		try await awaitTunnelReply { (complete: @escaping @Sendable (Result<Void, Error>) -> Void) in
			manager.loadFromPreferences { error in
				if let error {
					complete(.failure(error))
				} else {
					complete(.success(()))
				}
			}
		}
	}

	func remove(_ manager: NETunnelProviderManager) async throws {
		invalidateConfigurationCache()
		defer { invalidateConfigurationCache() }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			manager.removeFromPreferences { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	func startTunnel(on manager: NETunnelProviderManager, options: [String: NSObject], shouldStart: () -> Bool) async throws {
		guard shouldStart() else { throw CancellationError() }
		do {
			try manager.connection.startVPNTunnel(options: options)
		} catch {
			guard shouldStart() else { throw CancellationError() }
			let failure = error as NSError
			guard failure.domain == NEVPNErrorDomain,
				failure.code == NEVPNError.configurationStale.rawValue else { throw error }
			// Only stale preferences warrant one reload. Routing, permissions and
			// provider failures must never delete a valid profile or re-prompt.
			_log("Reloading stale VPN preferences before one retry.", level: .notice)
			try await load(manager)
			guard shouldStart() else { throw CancellationError() }
			try manager.connection.startVPNTunnel(options: options)
		}
	}

	func _setState(_ newState: EmbeddedTunnelState) {
		guard state != newState else { return }
		state = newState
		let level: DebugLogItem.Level
		switch newState {
		case .error: level = .error
		case .unavailable: level = .warning
		case .disconnected, .preparing, .connecting, .connected, .disconnecting: level = .info
		}
		_log("In-app tunnel state is now \(_stateDescription(newState)).", level: level)
	}

	func _stateDescription(_ state: EmbeddedTunnelState) -> String {
		switch state {
		case .unavailable: return "unavailable"
		case .disconnected: return "disconnected"
		case .preparing: return "preparing"
		case .connecting: return "connecting"
		case .connected: return "connected"
		case .disconnecting: return "disconnecting"
		case .error(let message): return "failed (\(message))"
		}
	}

}
#endif

private extension EmbeddedTunnelManager {
	func _log(_ message: String, level: DebugLogItem.Level = .info) {
		DebugLogManager.shared.log(message, category: "Tunnel", level: level)
	}
}
