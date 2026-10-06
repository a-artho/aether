//
//  InstallationAppProxy.swift
//  IDeviceKit
//
//  Created by samara on 8.06.2025.
//

import Foundation
import IDevice
import UIKit
import CryptoKit

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
		guard HeartbeatManager.hasPairingFile() else {
			throw IDeviceConnectionError.pairingFileMissing
		}
	}
}

extension InstallationAppProxy {
	private static let iconCache = InstalledIconCache()
	private static let iconDiskCache = InstalledIconDiskCache()
	private static let iconConnection = InstalledIconConnection()
	private static var iconRequests: [String: (id: UUID, task: Task<UIImage?, Error>)] = [:]
	private static let iconCacheQueue = DispatchQueue(label: "InstallationAppProxy.iconCache")

	static public func iconCacheRevision(for id: String) -> String {
		UserDefaults.standard.string(forKey: "InstalledIconRevision." + id) ?? ""
	}

	static public func invalidateAppIcon(for id: String) {
		UserDefaults.standard.set(UUID().uuidString, forKey: "InstalledIconRevision." + id)
	}

	static public func getAppIconCached(for id: String, cacheVersion: String? = nil) async throws -> UIImage? {
		// File I/O and identity hashing never run on the UI thread.
		let scope = await Task.detached(priority: .userInitiated) {
			iconDiskCache.deviceScope()
		}.value
		let cacheKey = "\(scope)|\(id)|\(cacheVersion ?? "")|\(iconCacheRevision(for: id))"
		if let cached = iconCache.image(for: cacheKey) { return cached }
		let request = iconCacheQueue.sync { () -> (id: UUID, task: Task<UIImage?, Error>) in
			if let existing = iconRequests[cacheKey] { return existing }
			let request = (id: UUID(), task: Task.detached(priority: .userInitiated) { () throws -> UIImage? in
				if let image = iconDiskCache.image(for: cacheKey) {
					iconCache.insert(image, for: cacheKey)
					return image
				}
				let data = try await iconConnection.iconData(for: id, scope: scope)
				guard let image = UIImage(data: data) else { return nil }
				iconDiskCache.store(data, for: cacheKey)
				iconCache.insert(image, for: cacheKey)
				return image
			})
			iconRequests[cacheKey] = request
			return request
		}
		defer {
			iconCacheQueue.sync {
				if iconRequests[cacheKey]?.id == request.id { iconRequests[cacheKey] = nil }
			}
		}
		return try await request.task.value
	}

	static public func getAppIcon(for id: String) async throws -> UIImage? {
		let scope = await Task.detached { iconDiskCache.deviceScope() }.value
		return UIImage(data: try await iconConnection.iconData(for: id, scope: scope))
	}
}

/// SpringBoard requests are serial on one short-lived connection. Native handles
/// are created, used and freed exclusively on this queue.
private final class InstalledIconConnection: @unchecked Sendable {
	private let queue = DispatchQueue(label: "InstallationAppProxy.icons", qos: .userInitiated)
	private var client: OpaquePointer?
	private var scope: String?
	private var generation: UInt64?
	private var idleClose: DispatchWorkItem?
	private var backgroundObserver: NSObjectProtocol?

	init() {
		backgroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
		) { [weak self] _ in
			self?.queue.async { [weak self] in self?.close() }
		}
	}

	deinit {
		if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
		idleClose?.cancel()
		if let client { springboard_services_free(client) }
	}

	func iconData(for id: String, scope: String) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			queue.async {
				self.idleClose?.cancel()
				do {
					let heartbeat = HeartbeatManager.shared
					if self.scope != scope || self.generation != heartbeat.serviceConnectionGeneration { self.close() }
					if self.client == nil {
						if heartbeat.isRsd {
							try heartbeat.withRSDServiceConnection { adapter, handshake in
								let error = springboard_services_connect_rsd(adapter, handshake, &self.client)
								if error == nil { self.generation = heartbeat.rsdGeneration }
								return error
							}
						} else {
							guard let provider = heartbeat.provider else { throw IDeviceConnectionError.tcpProviderUnavailable }
							if let error = springboard_services_connect(provider, &self.client) { throw IDeviceSwiftError(error) }
						}
						self.scope = scope
						if !heartbeat.isRsd { self.generation = heartbeat.serviceConnectionGeneration }
					}
					var bytes: UnsafeMutableRawPointer?
					var length = 0
					if let error = springboard_services_get_icon(self.client, id, &bytes, &length) { throw IDeviceSwiftError(error) }
					guard let bytes else { throw IDeviceSwiftError(message: "SpringBoard returned an empty icon buffer.") }
					defer { idevice_data_free(bytes.assumingMemoryBound(to: UInt8.self), UInt(length)) }
					continuation.resume(returning: Data(bytes: bytes, count: length))
					let close = DispatchWorkItem { [weak self] in self?.close() }
					self.idleClose = close
					self.queue.asyncAfter(deadline: .now() + 2, execute: close)
				} catch {
					self.close()
					continuation.resume(throwing: error)
				}
			}
		}
	}

	private func close() {
		idleClose?.cancel()
		idleClose = nil
		if let client { springboard_services_free(client) }
		client = nil
		scope = nil
		generation = nil
	}
}

/// A disposable, bounded cache of original icon bytes, scoped to the pairing
/// identity, endpoint and installed version/build.
private final class InstalledIconDiskCache: @unchecked Sendable {
	private let queue = DispatchQueue(label: "InstallationAppProxy.iconDiskCache")
	private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
		.appendingPathComponent("InstalledAppIcons", isDirectory: true)
	private var identityStamp = ""
	private var identityDigest = ""
	private var writes = 0

	func deviceScope() -> String {
		queue.sync {
			let path = HeartbeatManager.activePairingFile()
			let attributes = try? FileManager.default.attributesOfItem(atPath: path)
			let stamp = "\(path)|\(attributes?[.modificationDate] ?? "")|\(attributes?[.creationDate] ?? "")|\(attributes?[.size] ?? "")"
			if stamp != identityStamp {
				identityDigest = (try? Data(contentsOf: URL(fileURLWithPath: path))).map(Self.digest) ?? UUID().uuidString
				identityStamp = stamp
			}
			return "\(identityDigest)|\(HeartbeatManager.shared.ipAddress)"
		}
	}

	func image(for key: String) -> UIImage? {
		queue.sync {
			let url = directory.appendingPathComponent(Self.digest(Data(key.utf8)))
			guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
				let date = values.contentModificationDate, Date().timeIntervalSince(date) < 30 * 86400,
				let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
			return image
		}
	}

	func store(_ data: Data, for key: String) {
		queue.sync {
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				try data.write(to: directory.appendingPathComponent(Self.digest(Data(key.utf8))), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
				// Prune once per batch, rather than scanning the directory per icon.
				if writes % 32 == 0 { prune() }
				writes += 1
			} catch { /* Cache failures must not prevent displaying a fetched icon. */ }
		}
	}

	private func prune() {
		let files = ((try? FileManager.default.contentsOfDirectory(at: directory,
			includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
			.compactMap { url -> (URL, Date, Int)? in
				guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
				return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
			}.sorted { $0.1 > $1.1 }
		var bytes = 0
		for (index, file) in files.enumerated() {
			bytes += file.2
			if index >= 256 || bytes > 16 * 1024 * 1024 || Date().timeIntervalSince(file.1) >= 30 * 86400 {
				try? FileManager.default.removeItem(at: file.0)
			}
		}
	}

	private static func digest(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

private final class InstalledIconCache: NSObject, @unchecked Sendable {
	private let cache = NSCache<NSString, UIImage>()

	override init() {
		super.init()
		cache.countLimit = 128
		cache.totalCostLimit = 32 * 1024 * 1024
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(clear),
			name: UIApplication.didReceiveMemoryWarningNotification,
			object: nil
		)
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	func image(for key: String) -> UIImage? {
		cache.object(forKey: key as NSString)
	}

	func insert(_ image: UIImage, for key: String) {
		let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
		cache.setObject(image, forKey: key as NSString, cost: cost)
	}

	@objc private func clear() {
		cache.removeAllObjects()
	}
}
