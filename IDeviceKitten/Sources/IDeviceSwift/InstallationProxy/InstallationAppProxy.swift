//
//  InstallationAppProxy.swift
//  IDeviceKit
//
//  Created by samara on 8.06.2025.
//

import Foundation
import IDevice
import UIKit

public class InstallationAppProxy: NSObject {
	private let _heartbeat = HeartbeatManager.shared

	typealias InstallationProxyClientHandle = OpaquePointer
	typealias MisagentClientHandle = OpaquePointer
	typealias SpringBoardServicesClientHandle = OpaquePointer

	public weak var delegate: InstallationProxyAppsDelegate?

	public func listApps(applicationType: String? = nil) async throws {
		let apps = try await fetchApps(applicationType: applicationType)
		await MainActor.run {
			self.delegate?.updateApplications(with: apps)
		}
	}

	public func fetchApps(applicationType: String? = nil) async throws -> [AppInfo] {
		try await Task.detached(priority: .userInitiated) {
			var installproxy: InstallationProxyClientHandle?
			try self._connectInstallationProxy(client: &installproxy)
			defer { installation_proxy_client_free(installproxy) }

			var outResult: UnsafeMutableRawPointer?
			var outResultLen: Int = 0
			let getAppsError: UnsafeMutablePointer<IdeviceFfiError>?
			if let applicationType {
				getAppsError = applicationType.withCString { type in
					installation_proxy_get_apps(
						installproxy,
						type,
						nil,
						0,
						&outResult,
						&outResultLen
					)
				}
			} else {
				getAppsError = installation_proxy_get_apps(
					installproxy,
					nil,
					nil,
					0,
					&outResult,
					&outResultLen
				)
			}
			if let getAppsError {
				throw IDeviceSwiftError(getAppsError)
			}

			guard let outResult else { return [] }
			let plistBuffer = outResult.bindMemory(
				to: UnsafeMutableRawPointer?.self,
				capacity: outResultLen
			)
			defer {
				idevice_plist_array_free(plistBuffer, UInt(outResultLen))
				idevice_outer_slice_free(outResult, UInt(outResultLen))
			}

			let decoder = PropertyListDecoder()
			return UnsafeBufferPointer(start: plistBuffer, count: outResultLen).compactMap { plist in
				guard let plist else { return nil }

				var xml: UnsafeMutablePointer<CChar>?
				var length: UInt32 = 0
				plist_to_xml(plist, &xml, &length)
				guard let xml else { return nil }
				defer { free(xml) }

				do {
					return try decoder.decode(
						AppInfo.self,
						from: Data(bytes: xml, count: Int(length))
					)
				} catch {
					print("Failed to decode AppInfo plist: \(error)")
					return nil
				}
			}
		}.value
	}

	public func provisioningProfiles() async throws -> [ProvisioningProfileInfo] {
		try await Task.detached(priority: .userInitiated) {
			var client: MisagentClientHandle?
			try self._connectMisagent(client: &client)
			defer { misagent_client_free(client) }

			var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
			var profileLengths: UnsafeMutablePointer<Int>?
			var profileCount = 0
			if let error = misagent_copy_all(
				client,
				&profilePointers,
				&profileLengths,
				&profileCount
			) {
				throw IDeviceSwiftError(error)
			}

			guard let profilePointers, let profileLengths else { return [] }
			defer { misagent_free_profiles(profilePointers, profileLengths, profileCount) }

			return (0..<profileCount).compactMap { index in
				guard let bytes = profilePointers[index] else { return nil }
				return ProvisioningProfileInfo(
					data: Data(bytes: bytes, count: profileLengths[index])
				)
			}
		}.value
	}

	static public func deleteApp(for id: String) async throws {
		try await Task.detached(priority: .userInitiated) {
			let heartbeat = HeartbeatManager.shared
			var installproxy: InstallationProxyClientHandle?
			try Self._requirePairingFile()

			if heartbeat.isRsd {
				do {
					try heartbeat.withRSDServiceConnection { adapter, handshake in
						installation_proxy_connect_rsd(adapter, handshake, &installproxy)
					}
				} catch {
					throw IDeviceConnectionError.installationProxyConnectionFailed(
						error.localizedDescription
					)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceConnectionError.tcpProviderUnavailable
				}
				if let error = installation_proxy_connect(provider, &installproxy) {
					let reason = IDeviceSwiftError(error).localizedDescription
					throw IDeviceConnectionError.installationProxyConnectionFailed(reason)
				}
			}
			defer { installation_proxy_client_free(installproxy) }

			if let error = installation_proxy_uninstall(installproxy, id, nil) {
				throw IDeviceSwiftError(error)
			}
		}.value
	}

	private func _connectInstallationProxy(
		client: inout InstallationProxyClientHandle?
	) throws {
		try Self._requirePairingFile()

		if _heartbeat.isRsd {
			do {
				try _heartbeat.withRSDServiceConnection { adapter, handshake in
					installation_proxy_connect_rsd(adapter, handshake, &client)
				}
			} catch {
				throw IDeviceConnectionError.installationProxyConnectionFailed(
					error.localizedDescription
				)
			}
		} else {
			let connection = _heartbeat.checkSocketConnection()
			guard connection.isConnected else {
				throw IDeviceConnectionError.legacyEndpointUnavailable(connection.error)
			}
			guard let provider = _heartbeat.provider else {
				throw IDeviceConnectionError.tcpProviderUnavailable
			}
			if let error = installation_proxy_connect(provider, &client) {
				let reason = IDeviceSwiftError(error).localizedDescription
				throw IDeviceConnectionError.installationProxyConnectionFailed(reason)
			}
		}
	}

	private func _connectMisagent(client: inout MisagentClientHandle?) throws {
		try Self._requirePairingFile()

		if _heartbeat.isRsd {
			do {
				try _heartbeat.withRSDServiceConnection { adapter, handshake in
					misagent_connect_rsd(adapter, handshake, &client)
				}
			} catch {
				throw IDeviceConnectionError.misagentConnectionFailed(error.localizedDescription)
			}
		} else {
			guard let provider = _heartbeat.provider else {
				throw IDeviceConnectionError.tcpProviderUnavailable
			}
			if let error = misagent_connect(provider, &client) {
				let reason = IDeviceSwiftError(error).localizedDescription
				throw IDeviceConnectionError.misagentConnectionFailed(reason)
			}
		}
	}

	private static func _requirePairingFile() throws {
		guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
			throw IDeviceConnectionError.pairingFileMissing
		}
	}
}

extension InstallationAppProxy {
	private static var iconCache: [String: UIImage] = [:]
	private static var iconRequests: [String: Task<UIImage?, Error>] = [:]
	private static let iconCacheQueue = DispatchQueue(label: "InstallationAppProxy.iconCache")

	static public func getAppIconCached(for id: String) async throws -> UIImage? {
		if let cached = iconCacheQueue.sync(execute: { iconCache[id] }) {
			return cached
		}

		let request = iconCacheQueue.sync { () -> Task<UIImage?, Error> in
			if let existing = iconRequests[id] {
				return existing
			}
			let request = Task.detached(priority: .userInitiated) {
				try await getAppIcon(for: id)
			}
			iconRequests[id] = request
			return request
		}

		do {
			let image = try await request.value
			iconCacheQueue.sync {
				iconRequests[id] = nil
				if let image { iconCache[id] = image }
			}
			return image
		} catch {
			_ = iconCacheQueue.sync { iconRequests.removeValue(forKey: id) }
			throw error
		}
	}

	static public func getAppIcon(for id: String) async throws -> UIImage? {
		try await Task.detached(priority: .userInitiated) {
			let heartbeat = HeartbeatManager.shared
			var springServices: SpringBoardServicesClientHandle?

			if heartbeat.isRsd {
				do {
					try heartbeat.withRSDServiceConnection { adapter, handshake in
						springboard_services_connect_rsd(adapter, handshake, &springServices)
					}
				} catch {
					throw IDeviceConnectionError.springboardServicesConnectionFailed(
						error.localizedDescription
					)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceConnectionError.tcpProviderUnavailable
				}
				if let error = springboard_services_connect(provider, &springServices) {
					let reason = IDeviceSwiftError(error).localizedDescription
					throw IDeviceConnectionError.springboardServicesConnectionFailed(reason)
				}
			}
			defer { springboard_services_free(springServices) }

			var outResult: UnsafeMutableRawPointer?
			var outResultLen = 0
			if let error = springboard_services_get_icon(
				springServices,
				id,
				&outResult,
				&outResultLen
			) {
				throw IDeviceSwiftError(error)
			}

			guard let iconPointer = outResult else {
				throw IDeviceSwiftError(message: "SpringBoard returned an empty icon buffer.")
			}
			let bytes = iconPointer.assumingMemoryBound(to: UInt8.self)
			defer { idevice_data_free(bytes, UInt(outResultLen)) }
			return UIImage(data: Data(bytes: bytes, count: outResultLen))
		}.value
	}
}
