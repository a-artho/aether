//
//  HouseArrestService.swift
//  IDeviceSwift
//

import Foundation
import IDevice

public struct SandboxItem: Identifiable, Hashable, Sendable {
	public let name: String
	public let path: String
	public let isDirectory: Bool
	public let size: Int64
	public let modifiedDate: Date?

	public var id: String { path }

	public init(
		name: String,
		path: String,
		isDirectory: Bool,
		size: Int64,
		modifiedDate: Date?
	) {
		self.name = name
		self.path = path
		self.isDirectory = isDirectory
		self.size = size
		self.modifiedDate = modifiedDate
	}
}

public enum HouseArrestService {
	typealias HouseArrestHandle = OpaquePointer
	typealias AfcHandle = OpaquePointer

	private static func _requirePairingFile() throws {
		guard HeartbeatManager.hasPairingFile() else {
			throw IDeviceConnectionError.pairingFileMissing
		}
	}

	private static func _withSession<T: Sendable>(
		bundleIdentifier: String,
		_ block: @escaping @Sendable (AfcHandle) throws -> T
	) async throws -> T {
		try await Task.detached(priority: .userInitiated) {
			try _requirePairingFile()
			let heartbeat = HeartbeatManager.shared

			var houseArrest: HouseArrestHandle?
			if heartbeat.isRsd {
				do {
					try heartbeat.withRSDServiceConnection { adapter, handshake in
						house_arrest_client_connect_rsd(adapter, handshake, &houseArrest)
					}
				} catch {
					throw IDeviceConnectionError.houseArrestConnectionFailed(error.localizedDescription)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceConnectionError.tcpProviderUnavailable
				}
				if let error = house_arrest_client_connect(provider, &houseArrest) {
					let reason = IDeviceSwiftError(error).localizedDescription
					throw IDeviceConnectionError.houseArrestConnectionFailed(reason)
				}
			}
			guard let houseArrest else {
				throw IDeviceSwiftError(message: "Failed to establish House Arrest connection.")
			}
			defer { house_arrest_client_free(houseArrest) }

			var afc: AfcHandle?
			// Attempt to vend full container first; if not allowed, fallback to Documents
			var vendError = bundleIdentifier.withCString { cBundleId in
				house_arrest_vend_container(houseArrest, cBundleId, &afc)
			}
			if vendError != nil {
				idevice_error_free(vendError)
				vendError = bundleIdentifier.withCString { cBundleId in
					house_arrest_vend_documents(houseArrest, cBundleId, &afc)
				}
			}

			if let vendError {
				throw IDeviceSwiftError(vendError)
			}
			guard let afc else {
				throw IDeviceSwiftError(message: "Failed to acquire AFC client for \(bundleIdentifier)")
			}
			defer { afc_client_free(afc) }

			return try block(afc)
		}.value
	}

	public static func contentsOfDirectory(
		bundleIdentifier: String,
		path: String
	) async throws -> [SandboxItem] {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			let normalizedPath = path.isEmpty || !path.hasPrefix("/") ? "/" + path : path
			var entriesPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
			var count: Int = 0

			let listErr = normalizedPath.withCString { cPath in
				afc_list_directory(afc, cPath, &entriesPtr, &count)
			}
			if let listErr {
				throw IDeviceSwiftError(listErr)
			}

			guard let entriesPtr, count > 0 else { return [] }
			defer {
				for i in 0..<count {
					if let entry = entriesPtr[i] {
						idevice_string_free(entry)
					}
				}
				free(entriesPtr)
			}

			var items: [SandboxItem] = []
			for i in 0..<count {
				guard let cName = entriesPtr[i] else { continue }
				let name = String(cString: cName)
				if name == "." || name == ".." { continue }

				let itemPath = normalizedPath.hasSuffix("/")
					? normalizedPath + name
					: normalizedPath + "/" + name

				var isDir = false
				var size: Int64 = 0
				var modDate: Date?

				var info = AfcFileInfo()
				let infoErr = itemPath.withCString { cItemPath in
					afc_get_file_info(afc, cItemPath, &info)
				}
				if infoErr == nil {
					if let st_ifmt = info.st_ifmt {
						isDir = String(cString: st_ifmt) == "S_IFDIR"
					}
					size = Int64(info.size)
					if info.modified > 0 {
						let ts = Double(info.modified)
						if ts > 1_000_000_000_000_000 {
							modDate = Date(timeIntervalSince1970: ts / 1_000_000_000)
						} else if ts > 1_000_000_000 {
							modDate = Date(timeIntervalSince1970: ts)
						}
					}
					afc_file_info_free(&info)
				} else {
					idevice_error_free(infoErr)
				}

				items.append(
					SandboxItem(
						name: name,
						path: itemPath,
						isDirectory: isDir,
						size: size,
						modifiedDate: modDate
					)
				)
			}

			return items.sorted { lhs, rhs in
				if lhs.isDirectory != rhs.isDirectory {
					return lhs.isDirectory && !rhs.isDirectory
				}
				return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
			}
		}
	}

	public static func readFile(
		bundleIdentifier: String,
		path: String
	) async throws -> Data {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			var fileHandle: OpaquePointer?
			let openErr = path.withCString { cPath in
				afc_file_open(afc, cPath, AfcRdOnly, &fileHandle)
			}
			if let openErr {
				throw IDeviceSwiftError(openErr)
			}
			guard let fileHandle else {
				throw IDeviceSwiftError(message: "Failed to open file at \(path)")
			}
			defer { _ = afc_file_close(fileHandle) }

			var dataPtr: UnsafeMutablePointer<UInt8>?
			var dataLen: Int = 0
			let readErr = afc_file_read_entire(fileHandle, &dataPtr, &dataLen)
			if let readErr {
				throw IDeviceSwiftError(readErr)
			}
			defer {
				if let dataPtr {
					afc_file_read_data_free(dataPtr, dataLen)
				}
			}

			guard let dataPtr, dataLen > 0 else { return Data() }
			return Data(bytes: dataPtr, count: dataLen)
		}
	}

	public static func writeFile(
		bundleIdentifier: String,
		path: String,
		data: Data
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			var fileHandle: OpaquePointer?
			let openErr = path.withCString { cPath in
				afc_file_open(afc, cPath, AfcWrOnly, &fileHandle)
			}
			if let openErr {
				throw IDeviceSwiftError(openErr)
			}
			guard let fileHandle else {
				throw IDeviceSwiftError(message: "Failed to create file at \(path)")
			}
			defer { _ = afc_file_close(fileHandle) }

			let writeErr: UnsafeMutablePointer<IdeviceFfiError>? = data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
				guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
				return afc_file_write(fileHandle, baseAddress, rawBuffer.count)
			}
			if let writeErr {
				throw IDeviceSwiftError(writeErr)
			}
		}
	}

	public static func createDirectory(
		bundleIdentifier: String,
		path: String
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			let err = path.withCString { cPath in
				afc_make_directory(afc, cPath)
			}
			if let err {
				throw IDeviceSwiftError(err)
			}
		}
	}

	public static func deleteItem(
		bundleIdentifier: String,
		path: String
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			var err = path.withCString { cPath in
				afc_remove_path_and_contents(afc, cPath)
			}
			if err != nil {
				idevice_error_free(err)
				err = path.withCString { cPath in
					afc_remove_path(afc, cPath)
				}
			}
			if let err {
				throw IDeviceSwiftError(err)
			}
		}
	}

	public static func renameItem(
		bundleIdentifier: String,
		from: String,
		to: String
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			let err = from.withCString { cFrom in
				to.withCString { cTo in
					afc_rename_path(afc, cFrom, cTo)
				}
			}
			if let err {
				throw IDeviceSwiftError(err)
			}
		}
	}
}
