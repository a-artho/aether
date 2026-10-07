//
//  EmbeddedTunnelManager.swift
//  Aether
//

import Combine
import Foundation
import IDeviceSwift

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
	private var managersLoad: (id: UUID, task: Task<[NETunnelProviderManager], Error>)?
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
			Task { @MainActor [weak self] in
				guard let self, connection == self.manager?.connection else { return }
				self.updateState(for: connection.status)
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

	deinit {
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

	/// Checks whether Aether already has a saved tunnel profile without creating
	/// one or triggering iOS's VPN-profile approval prompt.
	public func hasSavedConfiguration() async -> Bool {
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
			return false
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
		do {
			let providerIdentifier = try discoverProviderIdentifier()
			let managers = try await loadManagers()
			let matching = managers.filter {
				Self.isAetherManaged($0)
					&& ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
			}
			manager = matching.first(where: { $0.connection.status == .connected || $0.connection.status == .connecting }) ?? matching.first
			updateState(for: manager?.connection.status ?? .disconnected)
		} catch {
			_setState(.error(error.localizedDescription))
		}
		#endif
	}

	@discardableResult
	public func prepare() async throws -> Bool {
		#if targetEnvironment(simulator)
		state = .disconnected
		return true
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		state = .preparing
		let providerIdentifier = try discoverProviderIdentifier()
		let managers = try await loadManagers()
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
			try? await remove(staleManager)
		}
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
			try await load(newManager)
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
		_ = try await prepare()
		guard shouldStart() else { throw CancellationError() }
		guard let manager else { throw EmbeddedTunnelError.invalidConfiguration }

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

	public func stop() async {
		_log("In-app tunnel stop requested.")
		#if targetEnvironment(simulator)
		state = .disconnected
		return
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
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
		if await waitForDisconnected() {
			_setState(.disconnected)
		} else {
			_setState(.error(.localized("The Aether tunnel did not stop in time.")))
			_log("In-app tunnel did not stop in time.", level: .warning)
		}
		#else
		state = .unavailable
		#endif
	}

	public func providerIsReady() async -> Bool {
		#if targetEnvironment(simulator)
		return isConnected
		#elseif os(iOS) && !targetEnvironment(macCatalyst)
		return manager?.connection.status == .connected
		#else
		return false
		#endif
	}

	public func updateNetworkConfiguration(
		interface: String,
		peer: String,
		allowIntermediate: Bool
	) async throws {
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

		#if os(iOS) && !targetEnvironment(macCatalyst)
		if let manager, manager.connection.status == .connected || manager.connection.status == .connecting {
			await stop()
			try await start()
		}
		#endif
	}

	public func resetNetworkConfiguration() async throws {
		try await updateNetworkConfiguration(
			interface: Self.defaultInterfaceAddress,
			peer: Self.defaultPeerAddress,
			allowIntermediate: Self.defaultAllowIntermediate
		)
	}

	public func resetConfiguration() async {
		_log("Resetting the in-app tunnel configuration.", level: .warning)
		#if os(iOS) && !targetEnvironment(macCatalyst)
		let managers = (try? await loadManagers()) ?? []
		for manager in managers where Self.isAetherManaged(manager) {
			manager.connection.stopVPNTunnel()
			try? await remove(manager)
		}
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
		await waitForStatus(.connected, timeout: 10_000_000_000)
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
			continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
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
		if let managersLoad { return try await managersLoad.task.value }
		let revision = managersRevision
		let id = UUID()
		let task = Task<[NETunnelProviderManager], Error> {
			try await withCheckedThrowingContinuation { continuation in
				NETunnelProviderManager.loadAllFromPreferences { managers, error in
					if let error { continuation.resume(throwing: error) }
					else { continuation.resume(returning: managers ?? []) }
				}
			}
		}
		managersLoad = (id, task)
		defer { if managersLoad?.id == id { managersLoad = nil } }
		let managers = try await task.value
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
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			manager.loadFromPreferences { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
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
			// A re-signed update can leave an old provider identifier in the
			// preferences. Repair only Aether's marked configuration, then retry.
			_log("Repairing the in-app tunnel configuration after a start failure.", level: .warning)
			await resetConfiguration()
			guard shouldStart() else { throw CancellationError() }
			_ = try await prepare()
			guard shouldStart() else { throw CancellationError() }
			guard let repairedManager = self.manager else { throw error }
			try repairedManager.connection.startVPNTunnel(options: options)
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
