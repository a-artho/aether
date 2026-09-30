//
//  FileManager+bundle.swift
//  Aether
//
//  Created by samara on 16.04.2025.
//

import Foundation.NSFileManager

public struct MaterializedExternalFile: Sendable {
	public let fileURL: URL
	public let directoryURL: URL

	public func cleanup() {
		try? FileManager.default.removeItem(at: directoryURL)
	}
}

public enum ExternalFileMaterializationError: LocalizedError {
	case unsupportedFileType
	case copyFailed(Error)

	public var errorDescription: String? {
		switch self {
		case .unsupportedFileType:
			return "The selected file is not an IPA or TIPA archive."
		case .copyFailed(let error):
			return "The selected file could not be copied into Aether: \(error.localizedDescription)"
		}
	}
}

extension FileManager {
	public func getPath(in directory: URL, for pathExtension: String) -> URL? {
		guard let contents = try? contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
			return nil
		}
		
		return contents.first(where: { $0.pathExtension == pathExtension })
	}
	
	public func isFileFromFileProvider(at url: URL) -> Bool {
		if let resourceValues = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .fileResourceIdentifierKey]),
		   resourceValues.isUbiquitousItem == true {
			return true
		}
		
		let path = url.path
		if path.contains("/Library/CloudStorage/") || path.contains("/File Provider Storage/") {
			return true
		}
		
		return false
	}

	public func materializePackageForImport(at sourceURL: URL) throws -> MaterializedExternalFile {
		let pathExtension = sourceURL.pathExtension.lowercased()
		guard pathExtension == "ipa" || pathExtension == "tipa" else {
			throw ExternalFileMaterializationError.unsupportedFileType
		}

		let directoryURL = temporaryDirectory.appendingPathComponent(
			"AetherImport_\(UUID().uuidString)",
			isDirectory: true
		)
		let fileName = sourceURL.lastPathComponent.isEmpty
			? "Import.\(pathExtension)"
			: sourceURL.lastPathComponent
		let destinationURL = directoryURL.appendingPathComponent(fileName)
		let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
		defer {
			if accessedSecurityScope {
				sourceURL.stopAccessingSecurityScopedResource()
			}
		}

		do {
			try createDirectory(at: directoryURL, withIntermediateDirectories: true)

			var coordinationError: NSError?
			var copyError: Error?
			NSFileCoordinator().coordinate(
				readingItemAt: sourceURL,
				options: [],
				error: &coordinationError
			) { readableURL in
				do {
					try self.copyItem(at: readableURL, to: destinationURL)
				} catch {
					copyError = error
				}
			}

			if let copyError { throw copyError }
			if let coordinationError { throw coordinationError }
			guard fileExists(atPath: destinationURL.path) else {
				throw CocoaError(.fileNoSuchFile)
			}
			return MaterializedExternalFile(
				fileURL: destinationURL,
				directoryURL: directoryURL
			)
		} catch {
			try? removeItem(at: directoryURL)
			throw ExternalFileMaterializationError.copyFailed(error)
		}
	}
	
	public func removeFileIfNeeded(at url: URL) throws {
		if self.fileExists(atPath: url.path) {
			try self.removeItem(at: url)
		}
	}
	
	public func moveFileIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
		if !self.fileExists(atPath: destinationURL.path) {
			try self.moveItem(at: sourceURL, to: destinationURL)
		}
	}
	
	public func createDirectoryIfNeeded(at url: URL) throws {
		if !self.fileExists(atPath: url.path) {
			try self.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
		}
	}
	
	static public func forceWrite(content: String, to filename: String) throws {
		let path = URL.documentsDirectory.appendingPathComponent(filename)
		try content.write(to: path, atomically: true, encoding: .utf8)
	}
	
	public func decodeAndWrite(base64: String, pathComponent: String) -> URL? {
		let raw = base64.replacingOccurrences(of: " ", with: "+")
		guard let data = Data(base64Encoded: raw) else { return nil }
		let dir = self.temporaryDirectory.appendingPathComponent(UUID().uuidString + pathComponent)
		try? data.write(to: dir)
		return dir
	}
	
	// AetherTweak
	public func moveAndStore(_ url: URL, with prepend: String, completion: @escaping (URL) -> Void) {
		let destination = _getDestination(url, with: prepend)
		
		try? createDirectoryIfNeeded(at: destination.temp)
		
		try? self.copyItem(at: url, to: destination.dest)
		completion(destination.dest)
	}
	
	public func deleteStored(_ url: URL, completion: @escaping (URL) -> Void) {
		try? FileManager.default.removeItem(at: url)
		completion(url)
	}
	
	// AetherTweak
	private func _getDestination(_ url: URL, with prepend: String) -> (temp: URL, dest: URL) {
		let tempDir = self.temporaryDirectory.appendingPathComponent("\(prepend)_\(UUID().uuidString)", isDirectory: true)
		let destinationUrl = tempDir.appendingPathComponent(url.lastPathComponent)
		return (tempDir, destinationUrl)
	}
}
