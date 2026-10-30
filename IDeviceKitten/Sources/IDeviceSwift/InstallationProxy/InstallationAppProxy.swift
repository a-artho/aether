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
import OSLog

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

	public func fetchApps(applicationType: String? = nil, lightweight: Bool = false, bundleIdentifier: String? = nil) async throws -> [AppInfo] {
		let worker = Task.detached(priority: .userInitiated) { () throws -> [AppInfo] in
			try Task.checkCancellation()
			var client: InstallationProxyClientHandle?
			try self._connectInstallationProxy(client: &client)
			defer { installation_proxy_client_free(client) }
			try Task.checkCancellation()
			return try Self.readApps(client: client, applicationType: applicationType, lightweight: lightweight, bundleIdentifier: bundleIdentifier)
		}
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			let result = try await worker.value
			try Task.checkCancellation()
			return result
		} onCancel: { worker.cancel() }
	}

	/// The initial browse contains row/classification fields only. Full Lookup
	/// remains available for details and as a compatibility fallback.
	static func readApps(client: OpaquePointer?, applicationType: String? = nil, lightweight: Bool = false, bundleIdentifier: String? = nil) throws -> [AppInfo] {
		try Task.checkCancellation()
		if lightweight {
			let options = plist_new_dict()
			defer { plist_free(options) }
			plist_dict_set_item(options, "ApplicationType", plist_new_string(applicationType ?? "Any"))
			let attributes = plist_new_array()
			for field in ["CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion", "SignerIdentity", "IsAppClip", "IsDemotedApp", "Entitlements", "ApplicationDSID", "ApplicationSINF", "iTunesMetadata"] {
				plist_array_append_item(attributes, plist_new_string(field))
			}
			plist_dict_set_item(options, "ReturnAttributes", attributes)
			var results: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
			var count = 0
			if let error = installation_proxy_browse(client, options, &results, &count) {
				let failure = IDeviceSwiftError(error)
				if DeviceConnectionCheck(isConnected: false, errorCode: failure.code, errorSubCode: failure.subCode).rejectsPairingRecord { throw failure }
				Logger.heartbeat.debug("Lightweight browse unavailable; using full app lookup: \(failure.localizedDescription)")
			} else {
				let apps = decodeApps(results, count: count)
				if apps.count == count, !apps.isEmpty, apps.allSatisfy({ !($0.CFBundleIdentifier ?? "").isEmpty }) { return apps }
			}
		}
		try Task.checkCancellation()
		var result: UnsafeMutableRawPointer?
		var count = 0
		let lookup: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<IdeviceFfiError>? = { type in
			if let bundleIdentifier {
				return bundleIdentifier.withCString { id in
					var idPointer: UnsafePointer<CChar>? = id
					return withUnsafePointer(to: &idPointer) { ids in
						installation_proxy_get_apps(client, type, ids, 1, &result, &count)
					}
				}
			}
			return installation_proxy_get_apps(client, type, nil, 0, &result, &count)
		}
		let error: UnsafeMutablePointer<IdeviceFfiError>?
		if let applicationType { error = applicationType.withCString(lookup) }
		else { error = lookup(nil) }

		if let error { throw IDeviceSwiftError(error) }
		let apps = decodeApps(result?.bindMemory(to: UnsafeMutableRawPointer?.self, capacity: count), count: count)
		guard apps.count == count, apps.allSatisfy({ !($0.CFBundleIdentifier ?? "").isEmpty }) else {
			throw NSError(domain: "AetherDeviceApps", code: 1, userInfo: [NSLocalizedDescriptionKey: "The device returned an incomplete app list. Please retry."])
		}
		return apps
	}

	private static func decodeApps(_ results: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, count: Int) -> [AppInfo] {
		guard let results else { return [] }
		defer {
			idevice_plist_array_free(results, UInt(count))
			idevice_outer_slice_free(UnsafeMutableRawPointer(results), UInt(count))
		}
		let decoder = PropertyListDecoder()
		return UnsafeBufferPointer(start: results, count: count).compactMap { plist -> AppInfo? in
			guard let plist else { return nil }
			var bytes: UnsafeMutablePointer<CChar>?
			var length: UInt32 = 0
			plist_to_bin(plist, &bytes, &length)
			guard let bytes else { return nil }
			defer { free(bytes) }
			do { return try decoder.decode(AppInfo.self, from: Data(bytes: bytes, count: Int(length))) }
			catch { Logger.heartbeat.error("Failed to decode installed app: \(error.localizedDescription)"); return nil }
		}
	}

	public func provisioningProfiles() async throws -> [ProvisioningProfileInfo] {
		let worker = Task.detached(priority: .userInitiated) { () throws -> [ProvisioningProfileInfo] in
			try Task.checkCancellation()
			var client: MisagentClientHandle?
			try self._connectMisagent(client: &client)
			defer { misagent_client_free(client) }
			try Task.checkCancellation()

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
			try Task.checkCancellation()

			return (0..<profileCount).compactMap { index -> ProvisioningProfileInfo? in
				guard let bytes = profilePointers[index] else { return nil }
				return ProvisioningProfileInfo(
					data: Data(bytes: bytes, count: profileLengths[index])
				)
			}
		}
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			let result = try await worker.value
			try Task.checkCancellation()
			return result
		} onCancel: { worker.cancel() }
	}

	static public func deleteApp(for id: String) async throws {
		try await Task.detached(priority: .userInitiated) {
			let heartbeat = HeartbeatManager.shared
			var installproxy: InstallationProxyClientHandle?
			try Self._requirePairingFile()

			do {
				try heartbeat.withRSDServiceConnection { adapter, handshake in
					installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				}
			} catch {
				throw IDeviceConnectionError.installationProxyConnectionFailed(
					error.localizedDescription
				)
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

		do {
			try _heartbeat.withRSDServiceConnection { adapter, handshake in
				installation_proxy_connect_rsd(adapter, handshake, &client)
			}
		} catch {
			throw IDeviceConnectionError.installationProxyConnectionFailed(
				error.localizedDescription
			)
		}

	}

	private func _connectMisagent(client: inout MisagentClientHandle?) throws {
		try Self._requirePairingFile()

		do {
			try _heartbeat.withRSDServiceConnection { adapter, handshake in
				misagent_connect_rsd(adapter, handshake, &client)
			}
		} catch {
			throw IDeviceConnectionError.misagentConnectionFailed(error.localizedDescription)
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
	private static var selectedIconScope: String?
	private static var iconScopeID = UUID()
	private typealias IconStream = AsyncThrowingStream<UIImage?, Error>
	private struct IconRequest {
		let id: UUID
		let task: Task<Void, Never>
		let cancellation: InstalledIconCancellation
		var waiters: [UUID: IconStream.Continuation]
	}
	private static var iconRequests: [String: IconRequest] = [:]
	private static let iconCacheQueue = DispatchQueue(label: "InstallationAppProxy.iconCache")

	/// The connection manager already reads the selected pairing digest. Reuse that
	/// identity instead of scheduling file metadata work for every cached icon.
	static public func setIconDeviceScope(pairingDigest: Data?, endpoint: String) {
		let scope = pairingDigest.map { $0.map { String(format: "%02x", $0) }.joined() + "|" + endpoint }
		let retired: [IconRequest]? = iconCacheQueue.sync {
			guard selectedIconScope != scope else { return nil }
			selectedIconScope = scope
			iconScopeID = UUID()
			let requests = Array(iconRequests.values)
			iconRequests.removeAll()
			return requests
		}
		if let retired {
			iconConnection.invalidate()
			cancelIconRequests(retired)
		}
	}

	fileprivate static func cancelPendingIconRequests() {
		let retired = iconCacheQueue.sync {
			let requests = Array(iconRequests.values)
			iconRequests.removeAll()
			return requests
		}
		cancelIconRequests(retired)
	}

	private static func cancelIconRequests(_ requests: [IconRequest]) {
		for request in requests {
			request.cancellation.cancel()
			request.task.cancel()
			for waiter in request.waiters.values { waiter.finish(throwing: CancellationError()) }
		}
	}

	private static func releaseIconWaiter(_ id: UUID, key: String) {
		let retired: IconRequest? = iconCacheQueue.sync {
			guard var request = iconRequests[key], request.waiters.removeValue(forKey: id) != nil else { return nil }
			if request.waiters.isEmpty { iconRequests[key] = nil; return request }
			iconRequests[key] = request
			return nil
		}
		if let retired { retired.cancellation.cancel(); retired.task.cancel() }
	}

	private static func completeIconRequest(_ id: UUID, key: String, result: Result<UIImage?, Error>) {
		let waiters: [IconStream.Continuation] = iconCacheQueue.sync {
			guard let request = iconRequests[key], request.id == id else { return [] }
			iconRequests[key] = nil
			return Array(request.waiters.values)
		}
		for waiter in waiters {
			switch result {
			case .success(let image): waiter.yield(image); waiter.finish()
			case .failure(let error): waiter.finish(throwing: error)
			}
		}
	}

	static public func iconCacheRevision(for id: String) -> String {
		UserDefaults.standard.string(forKey: "InstalledIconRevision." + id) ?? ""
	}

	static public func invalidateAppIcon(for id: String) {
		UserDefaults.standard.set(UUID().uuidString, forKey: "InstalledIconRevision." + id)
	}

	/// A first-frame lookup only: never reads disk, decodes images, or opens a device connection.
	static public func appIconInMemory(for id: String, cacheVersion: String? = nil) -> UIImage? {
		guard let scope = iconCacheQueue.sync(execute: { selectedIconScope }) else { return nil }
		let cacheKey = "\(scope)|\(id)|\(cacheVersion ?? "")|\(iconCacheRevision(for: id))"
		return iconCache.image(for: cacheKey)
	}

	/// 50pt rows need at most 150 pixels at 3x. Called exclusively by background cache work.
	fileprivate static func preparedRowIcon(data: Data) -> UIImage? {
		UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 150, height: 150))
	}

	static public func getAppIconCached(for id: String, cacheVersion: String? = nil) async throws -> UIImage? {
		try Task.checkCancellation()
		// File I/O and identity hashing never run on the UI thread.
		let selection = iconCacheQueue.sync { (scope: selectedIconScope, id: iconScopeID) }
		let scope: String
		if let verified = selection.scope { scope = verified }
		else { scope = await Task.detached(priority: .userInitiated) { iconDiskCache.deviceScope() }.value }
		try Task.checkCancellation()
		let cacheKey = "\(scope)|\(id)|\(cacheVersion ?? "")|\(iconCacheRevision(for: id))"
		if let cached = iconCache.image(for: cacheKey) { return cached }
		let waiterID = UUID()
		let (stream, continuation) = IconStream.makeStream()
		defer { releaseIconWaiter(waiterID, key: cacheKey); continuation.finish() }
		return try await withTaskCancellationHandler {
			// Registration and the background notification share the main actor.
			// No request can slip in between the active check and retirement.
			try await MainActor.run {
				try Task.checkCancellation()
				guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
				_ = iconConnection
				try iconCacheQueue.sync {
					guard iconScopeID == selection.id else { throw CancellationError() }
					if var request = iconRequests[cacheKey] {
						request.waiters[waiterID] = continuation
						iconRequests[cacheKey] = request
						return
					}
					let requestID = UUID()
					let cancellation = InstalledIconCancellation()
					let task = Task.detached(priority: .userInitiated) {
						let result: Result<UIImage?, Error>
						do {
							try cancellation.check()
							if let image = iconDiskCache.image(for: cacheKey) {
								try cancellation.check()
								iconCache.insert(image, for: cacheKey)
								result = .success(image)
							} else {
								let data = try await iconConnection.iconData(for: id, scope: scope, cancellation: cancellation)
								try cancellation.check()
								let image = preparedRowIcon(data: data)
								if let image {
									iconDiskCache.store(data, for: cacheKey)
									iconCache.insert(image, for: cacheKey)
								}
								result = .success(image)
							}
						} catch { result = .failure(error) }
						completeIconRequest(requestID, key: cacheKey, result: result)
					}
					iconRequests[cacheKey] = IconRequest(id: requestID, task: task, cancellation: cancellation,
						waiters: [waiterID: continuation])
				}
			}
			for try await image in stream { try Task.checkCancellation(); return image }
			throw CancellationError()
		} onCancel: {
			continuation.finish(throwing: CancellationError())
			releaseIconWaiter(waiterID, key: cacheKey)
		}
	}

	static public func getAppIcon(for id: String) async throws -> UIImage? {
		let cancellation = InstalledIconCancellation()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			let scope = await Task.detached { iconDiskCache.deviceScope() }.value
			let data = try await iconConnection.iconData(for: id, scope: scope, cancellation: cancellation)
			try cancellation.check()
			return UIImage(data: data)
		} onCancel: { cancellation.cancel() }
	}
}

private final class InstalledIconCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false
	var isCancelled: Bool { lock.withLock { cancelled } }
	func cancel() { lock.withLock { cancelled = true } }
	func check() throws {
		try Task.checkCancellation()
		if isCancelled { throw CancellationError() }
	}
}

/// SpringBoard requests are serial on one short-lived connection. Native handles
/// are created, used and freed exclusively on this queue.
// Connection ownership and idle-close work are serialized by a private queue.
private final class InstalledIconConnection: @unchecked Sendable {
	private let queue = DispatchQueue(label: "InstallationAppProxy.icons", qos: .userInitiated)
	private let lifecycleLock = NSLock()
	private var lifecycleID = UUID()
	private var client: OpaquePointer?
	private var scope: String?
	private var generation: UInt64?
	private var idleClose: DispatchWorkItem?
	private var backgroundObserver: NSObjectProtocol?

	init() {
		backgroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.invalidate()
			InstallationAppProxy.cancelPendingIconRequests()
		}
	}

	deinit {
		if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
		idleClose?.cancel()
		if let client { springboard_services_free(client) }
	}

	func invalidate() {
		lifecycleLock.withLock { lifecycleID = UUID() }
		queue.async { [weak self] in self?.close() }
	}

	func iconData(for id: String, scope: String, cancellation: InstalledIconCancellation = InstalledIconCancellation()) async throws -> Data {
		let lifecycle = try await MainActor.run {
			try cancellation.check()
			guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
			return self.lifecycleLock.withLock { self.lifecycleID }
		}
		let shouldProceed: @Sendable () -> Bool = { !cancellation.isCancelled && self.lifecycleLock.withLock { self.lifecycleID == lifecycle } }
		return try await withCheckedThrowingContinuation { continuation in
			queue.async {
				self.idleClose?.cancel()
				do {
					try cancellation.check()
					guard shouldProceed() else { throw CancellationError() }
					let heartbeat = HeartbeatManager.shared
					if self.scope != scope || self.generation != heartbeat.serviceConnectionGeneration { self.close() }
					guard shouldProceed() else { throw CancellationError() }
					if self.client == nil {
						do {
							try heartbeat.withRSDServiceConnection(shouldProceed: shouldProceed) { adapter, handshake in
								let error = springboard_services_connect_rsd(adapter, handshake, &self.client)
								if error == nil { self.generation = heartbeat.rsdGeneration }
								return error
							}
						}
						self.scope = scope

					}
					guard shouldProceed() else { throw CancellationError() }
					var bytes: UnsafeMutableRawPointer?
					var length = 0
					if let error = springboard_services_get_icon(self.client, id, &bytes, &length) { throw IDeviceSwiftError(error) }
					guard let bytes else { throw IDeviceSwiftError(message: "SpringBoard returned an empty icon buffer.") }
					defer { idevice_data_free(bytes.assumingMemoryBound(to: UInt8.self), UInt(length)) }
					guard shouldProceed() else { throw CancellationError() }
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
// Disk cache mutation is serialized by its private queue.
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
				let data = try? Data(contentsOf: url), let image = InstallationAppProxy.preparedRowIcon(data: data) else { return nil }
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

// NSCache synchronizes its own concurrent access; no other mutable cache state is shared.
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
