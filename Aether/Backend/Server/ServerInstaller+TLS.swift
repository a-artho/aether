//
//  Server+TLS.swift
//  aether
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR AETHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	static let env: Environment = {
		var env = (try? Environment.detect()) ?? .development
		_ = try? LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	func setupApp(port: Int, localTLS: LocalServerTLSMaterial?) throws -> Application {
		let app = Application(Self.env)
		var configured = false
		defer { if !configured { app.shutdown() } }
		app.threadPool = .init(numberOfThreads: 1)
		
		if getServerMethod() == 0 {
			guard let localTLS else { throw LocalServerCertificates.Failure.setupRequired }
			app.http.server.configuration.tlsConfiguration = try tls(material: localTLS)
		}

		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname(getServerMethod() == 0 ? "127.0.0.1" : "0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		
		configured = true
		return app
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		} else {
			return LocalServerCertificates.hostname
		}
	}
	
	func tls(material: LocalServerTLSMaterial) throws -> TLSConfiguration {
		try TLSConfiguration.makeServerConfiguration(
			certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(material.certificateDER), format: .der))],
			privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(material.privateKeyPEM), format: .pem))
		)
	}
}

extension ServerInstaller {
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while let currentPtr = ptr {
				let interface = currentPtr.pointee
				if let ifaAddr = interface.ifa_addr {
					let addrFamily = ifaAddr.pointee.sa_family
					if addrFamily == UInt8(AF_INET) {
						let name = String(cString: interface.ifa_name)
						if name == "en0" || name == "pdp_ip0" {
							var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
							if getnameinfo(ifaAddr, socklen_t(ifaAddr.pointee.sa_len),
							               &hostname, socklen_t(hostname.count),
							               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
								let candidate = String(cString: hostname)
								if name == "en0" {
									address = candidate
									break
								}
								if address == nil { address = candidate }
							}
						}
					}
				}
				ptr = interface.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
