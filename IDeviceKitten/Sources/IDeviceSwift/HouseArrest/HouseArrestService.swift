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
	private static let _transferChunkSize = 4 * 1024 * 1024

	private enum _VendTarget {
		case container
		case documents
	}

	private static func _requirePairingFile() throws {
		guard HeartbeatManager.hasPairingFile() else {
			throw IDeviceConnectionError.pairingFileMissing
		}
	}

	private static func _connectHouseArrest() throws -> HouseArrestHandle {
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
		return houseArrest
	}

	private static func _vend(
		bundleIdentifier: String,
		target: _VendTarget
	) throws -> AfcHandle {
		let houseArrest = try _connectHouseArrest()
		var wasConsumed = false
		defer {
			if !wasConsumed {
				house_arrest_client_free(houseArrest)
			}
		}

		var afc: AfcHandle?
		// Both vend APIs consume the House Arrest client, including when vending fails.
		wasConsumed = true
		let vendError = bundleIdentifier.withCString { cBundleId in
			switch target {
			case .container:
				return house_arrest_vend_container(houseArrest, cBundleId, &afc)
			case .documents:
				return house_arrest_vend_documents(houseArrest, cBundleId, &afc)
			}
		}

		if let vendError {
			throw IDeviceSwiftError(vendError)
		}
		guard let afc else {
			throw IDeviceSwiftError(message: "Failed to acquire AFC client for \(bundleIdentifier)")
		}
		return afc
	}

	private static func _withSession<T: Sendable>(
		bundleIdentifier: String,
		_ block: @escaping @Sendable (AfcHandle) throws -> T
	) async throws -> T {
		try await Task.detached(priority: .userInitiated) {
			let afc: AfcHandle
			do {
				afc = try _vend(bundleIdentifier: bundleIdentifier, target: .container)
			} catch {
				// A failed vend consumes its House Arrest client too, so Documents needs a
				// fresh connection rather than reusing the old handle.
				afc = try _vend(bundleIdentifier: bundleIdentifier, target: .documents)
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
			try _contentsOfDirectory(afc, path: path)
		}
	}

	/// Streams an app-container directory to disk. The result keeps the directory
	/// structure intact and never holds file contents in memory.
	public static func copyDirectoryFromDevice(
		bundleIdentifier: String,
		path remotePath: String,
		to localURL: URL
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			try _copyDirectory(afc, remotePath: remotePath, localURL: localURL)
		}
	}

	public static func readFile(
		bundleIdentifier: String,
		path: String,
		maximumSize: Int
	) async throws -> Data {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			guard maximumSize >= 0 else {
				throw IDeviceSwiftError(message: "The maximum file size must not be negative.")
			}
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

			var data = Data()
			while true {
				let requestSize = min(_transferChunkSize, maximumSize - data.count + 1)
				guard requestSize > 0 else {
					throw IDeviceSwiftError(message: "The file at \(path) exceeds the allowed preview size.")
				}

				var dataPtr: UnsafeMutablePointer<UInt8>?
				var bytesRead = 0
				let readErr = afc_file_read(fileHandle, &dataPtr, UInt(requestSize), &bytesRead)
				if let readErr {
					throw IDeviceSwiftError(readErr)
				}
				guard bytesRead > 0 else { break }
				guard let dataPtr else {
					throw IDeviceSwiftError(message: "AFC returned an empty buffer while reading \(path)")
				}
				defer { afc_file_read_data_free(dataPtr, bytesRead) }

				data.append(contentsOf: UnsafeBufferPointer(start: dataPtr, count: bytesRead))
				if data.count > maximumSize {
					throw IDeviceSwiftError(message: "The file at \(path) exceeds the allowed preview size.")
				}
			}
			return data
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

	/// Streams a local file into an app container without loading its full contents into memory.
	public static func copyFileToDevice(
		bundleIdentifier: String,
		from localURL: URL,
		to remotePath: String
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			var fileHandle: OpaquePointer?
			let openErr = remotePath.withCString { cPath in
				afc_file_open(afc, cPath, AfcWrOnly, &fileHandle)
			}
			if let openErr {
				throw IDeviceSwiftError(openErr)
			}
			guard let fileHandle else {
				throw IDeviceSwiftError(message: "Failed to create file at \(remotePath)")
			}
			defer { _ = afc_file_close(fileHandle) }

			let localFile = try FileHandle(forReadingFrom: localURL)
			defer { try? localFile.close() }

			while let chunk = try localFile.read(upToCount: _transferChunkSize), !chunk.isEmpty {
				try Task.checkCancellation()
				let writeErr = chunk.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
					guard let baseAddress = buffer.baseAddress else { return nil }
					return afc_file_write(
						fileHandle,
						baseAddress.assumingMemoryBound(to: UInt8.self),
						chunk.count
					)
				}
				if let writeErr {
					throw IDeviceSwiftError(writeErr)
				}
			}
		}
	}

	/// Streams a file from an app container to disk without allocating the entire remote file.
	public static func copyFileFromDevice(
		bundleIdentifier: String,
		path remotePath: String,
		to localURL: URL
	) async throws {
		try await _withSession(bundleIdentifier: bundleIdentifier) { afc in
			try _copyFile(afc, remotePath: remotePath, localURL: localURL)
		}
	}

	private static func _contentsOfDirectory(
		_ afc: AfcHandle,
		path: String
	) throws -> [SandboxItem] {
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

	private static func _copyDirectory(
		_ afc: AfcHandle,
		remotePath: String,
		localURL: URL
	) throws {
		try Task.checkCancellation()
		let fileManager = FileManager.default
		try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)

		for item in try _contentsOfDirectory(afc, path: remotePath) {
			let destination = localURL.appendingPathComponent(item.name, isDirectory: item.isDirectory)
			if item.isDirectory {
				try _copyDirectory(afc, remotePath: item.path, localURL: destination)
			} else {
				try _copyFile(afc, remotePath: item.path, localURL: destination)
			}
		}
	}

	private static func _copyFile(
		_ afc: AfcHandle,
		remotePath: String,
		localURL: URL
	) throws {
		var fileHandle: OpaquePointer?
		let openErr = remotePath.withCString { cPath in
			afc_file_open(afc, cPath, AfcRdOnly, &fileHandle)
		}
		if let openErr {
			throw IDeviceSwiftError(openErr)
		}
		guard let fileHandle else {
			throw IDeviceSwiftError(message: "Failed to open file at \(remotePath)")
		}
		defer { _ = afc_file_close(fileHandle) }

		let fileManager = FileManager.default
		try fileManager.createDirectory(
			at: localURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		if fileManager.fileExists(atPath: localURL.path) {
			try fileManager.removeItem(at: localURL)
		}
		guard fileManager.createFile(atPath: localURL.path, contents: nil) else {
			throw IDeviceSwiftError(message: "Failed to create local file at \(localURL.path)")
		}
		let localFile = try FileHandle(forWritingTo: localURL)
		defer { try? localFile.close() }

		while true {
			try Task.checkCancellation()

			var dataPtr: UnsafeMutablePointer<UInt8>?
			var bytesRead = 0
			let readErr = afc_file_read(fileHandle, &dataPtr, UInt(_transferChunkSize), &bytesRead)
			if let readErr {
				throw IDeviceSwiftError(readErr)
			}
			guard bytesRead > 0 else { break }
			guard let dataPtr else {
				throw IDeviceSwiftError(message: "AFC returned an empty buffer while reading \(remotePath)")
			}
			defer { afc_file_read_data_free(dataPtr, bytesRead) }

			try localFile.write(contentsOf: Data(bytes: dataPtr, count: bytesRead))
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
