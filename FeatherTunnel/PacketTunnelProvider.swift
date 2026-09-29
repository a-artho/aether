import Foundation
import Darwin
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
	private static let interfaceAddressKey = "TunnelIfaceIP"
	private static let peerAddressKey = "TunnelPeerIP"
	private static let defaultInterfaceAddress = "10.7.1.1/32"
	private static let defaultPeerAddress = "10.7.0.1/32"

	private var isRunning = false

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

		setTunnelNetworkSettings(settings) { [weak self] error in
			guard let self else { return }
			guard error == nil else {
				completionHandler(error)
				return
			}
			self.isRunning = true
			self.readPackets()
			completionHandler(nil)
		}
	}

	override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
		isRunning = false
		setTunnelNetworkSettings(nil) { _ in
			completionHandler()
		}
	}

	override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
		completionHandler?(nil)
	}

	private func readPackets() {
		guard isRunning else { return }
		packetFlow.readPackets { [weak self] packets, protocols in
			guard let self, self.isRunning else { return }
			var reflectedPackets = packets

			for index in reflectedPackets.indices where protocols[index].int32Value == AF_INET {
				guard reflectedPackets[index].count >= 20 else { continue }
				reflectedPackets[index].withUnsafeMutableBytes { rawBuffer in
					guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
					let src = ptr[3]
					let dst = ptr[4]
					ptr[3] = dst
					ptr[4] = src
				}
			}

			self.packetFlow.writePackets(reflectedPackets, withProtocols: protocols)
			self.readPackets()
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
		"Invalid Feather tunnel address."
	}
}
