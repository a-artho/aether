import Foundation
import Darwin
import Network
import NetworkExtension

// NetworkExtension callbacks may use different threads. Custom lifecycle state is locked.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
	private static let interfaceAddressKey = "TunnelIfaceIP"
	private static let peerAddressKey = "TunnelPeerIP"
	private static let defaultInterfaceAddress = "10.7.1.1/32"
	private static let defaultPeerAddress = "10.7.0.1/32"

	private let stateLock = NSLock()
	private var runningGeneration: UUID?
	private func isRunning(_ generation: UUID) -> Bool {
		stateLock.withLock { runningGeneration == generation }
	}

	override func startTunnel(
		options: [String: NSObject]?,
		completionHandler: @escaping (Error?) -> Void
	) {
		let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
		let interfaceAddress = (options?[Self.interfaceAddressKey] as? String)
			?? (configuration?[Self.interfaceAddressKey] as? String)
			?? Self.defaultInterfaceAddress
		let peerAddress = (options?[Self.peerAddressKey] as? String)
			?? (configuration?[Self.peerAddressKey] as? String)
			?? Self.defaultPeerAddress

		guard let interface = CIDRAddress(interfaceAddress), let peer = CIDRAddress(peerAddress) else {
			completionHandler(TunnelError.invalidAddress)
			return
		}

		let ipv4 = NEIPv4Settings(addresses: [interface.address], subnetMasks: [interface.netmask])
		ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peer.networkBase, subnetMask: peer.netmask)]
		ipv4.excludedRoutes = [NEIPv4Route.default()]

		let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer.address)
		settings.ipv4Settings = ipv4

		let generation = UUID()
		stateLock.withLock { runningGeneration = generation }
		let completion = TunnelCompletion(completionHandler)
		setTunnelNetworkSettings(settings) { [weak self] error in
			guard let self, self.isRunning(generation) else {
				completion.call(CancellationError())
				return
			}
			guard error == nil else {
				self.stateLock.withLock { if self.runningGeneration == generation { self.runningGeneration = nil } }
				completion.call(error)
				return
			}
			self.readPackets(generation: generation)
			completion.call(nil)
		}
	}

	override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
		stateLock.withLock { runningGeneration = nil }
		let completion = TunnelCompletion<Void> { _ in completionHandler() }
		setTunnelNetworkSettings(nil) { _ in
			completion.call(())
		}
	}

	override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
		completionHandler?(nil)
	}

	private func readPackets(generation: UUID) {
		guard isRunning(generation) else { return }
		packetFlow.readPackets { [weak self] packets, protocols in
			guard let self, self.isRunning(generation) else { return }
			var reflectedPackets = packets

			for index in reflectedPackets.indices where protocols[index].int32Value == AF_INET {
				guard reflectedPackets[index].count >= 20 else { continue }
				reflectedPackets[index].withUnsafeMutableBytes { rawBuffer in
					// IPv4 addresses are four network-order bytes; avoid typed alignment assumptions.
					for byte in 0..<4 {
						let source = rawBuffer[12 + byte]
						rawBuffer[12 + byte] = rawBuffer[16 + byte]
						rawBuffer[16 + byte] = source
					}
				}
			}

			self.packetFlow.writePackets(reflectedPackets, withProtocols: protocols)
			self.readPackets(generation: generation)
		}
	}
}

private struct CIDRAddress {
	let address: String
	let networkBase: String
	let netmask: String
	let prefix: Int

	init?(_ value: String, defaultPrefix: Int = 32) {
		let pieces = value.split(separator: "/", maxSplits: 1).map(String.init)
		guard !pieces.isEmpty else { return nil }
		let ipString = pieces[0].trimmingCharacters(in: .whitespaces)
		let octets = ipString.split(separator: ".").compactMap { UInt32($0) }
		guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
		let ipRaw = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]

		let parsedPrefix: Int
		if pieces.count == 2, let parsed = Int(pieces[1].trimmingCharacters(in: .whitespaces)), (0...32).contains(parsed) {
			parsedPrefix = parsed
		} else {
			parsedPrefix = defaultPrefix
		}
		self.prefix = parsedPrefix
		self.address = ipString

		let maskRaw: UInt32 = parsedPrefix == 0 ? 0 : UInt32.max << (32 - UInt32(parsedPrefix))
		let baseRaw = ipRaw & maskRaw

		let b1 = (maskRaw >> 24) & 0xff
		let b2 = (maskRaw >> 16) & 0xff
		let b3 = (maskRaw >> 8) & 0xff
		let b4 = maskRaw & 0xff
		self.netmask = "\(b1).\(b2).\(b3).\(b4)"

		let nb1 = (baseRaw >> 24) & 0xff
		let nb2 = (baseRaw >> 16) & 0xff
		let nb3 = (baseRaw >> 8) & 0xff
		let nb4 = baseRaw & 0xff
		self.networkBase = "\(nb1).\(nb2).\(nb3).\(nb4)"
	}
}

private enum TunnelError: LocalizedError {
	case invalidAddress

	var errorDescription: String? {
		"Invalid Aether tunnel address."
	}
}

// The SDK's completion is consumed once under a lock, then invoked outside the lock.
private final class TunnelCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?
    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    func call(_ value: Value) {
        let callback = lock.withLock { let result = self.callback; self.callback = nil; return result }
        callback?(value)
    }
}
