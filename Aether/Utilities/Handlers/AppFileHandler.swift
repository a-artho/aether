//
//  IPAHandler.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import Foundation
import Zip
import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid: String
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	private var _archiveInspection: ArchiveInspection?

	private struct ArchiveInspection {
		let entryCount: Int
		let uncompressedBytes: Int64
	}

	private static let maximumArchiveEntries = 20_000
	private static let maximumUncompressedArchiveBytes: Int64 = 16 * 1024 * 1024 * 1024
	
	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		transactionIdentifier: String? = nil
	) {
		let uuid = transactionIdentifier ?? UUID().uuidString
		self._uuid = uuid
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("AetherImport_\(uuid)", isDirectory: true)
		
		super.init()
	}
	
	func prepare(copySource: Bool) async throws {
		// Reserve enough room before duplicating a large archive. This avoids a
		// needless full IPA copy only to fail during extraction.
		try _inspectArchiveIfNeeded()
		try _checkAvailableDiskSpace()
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		guard copySource else { return }
		
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)
		
		try _fileManager.copyItemPreferClone(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}
	
	func extract() async throws {
		try Task.checkCancellation()
		try _inspectArchiveIfNeeded()
		try _checkAvailableDiskSpace()
		if _ipa.pathExtension.lowercased() == "ipa" {
			Zip.addCustomFileExtension("ipa")
		}
		if _ipa.pathExtension.lowercased() == "tipa" {
			Zip.addCustomFileExtension("tipa")
		}
		
		let download = self._download
		
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .utility).async {
				do {
					let progressLock = NSLock()
					var lastProgressUpdate = Date.distantPast
					var lastReportedProgress = 0.0
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							if let download = download {
								progressLock.lock()
								let now = Date()
								let shouldReport = now.timeIntervalSince(lastProgressUpdate) >= 0.125
									|| progress - lastReportedProgress >= 0.01
									|| progress >= 1
								if shouldReport {
									lastProgressUpdate = now
									lastReportedProgress = progress
								}
								progressLock.unlock()
								guard shouldReport else { return }
								DispatchQueue.main.async {
									download.unpackageProgress = progress
									
									#if !targetEnvironment(macCatalyst)
									BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
									#endif
								}
							}
						}
					)
					if Task.isCancelled { throw CancellationError() }
					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
	
	func move() async throws {
		try Task.checkCancellation()
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		let destinationURL = try await _directory()
		
		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		try _fileManager.removeFileIfNeeded(at: destinationURL)
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		try Task.checkCancellation()
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw ImportedFileHandlerError.appBundleNotFound
		}

		try await _commitToDatabase(appURL: appUrl)
	}

	func recoverCommittedImport() async throws -> Bool {
		try Task.checkCancellation()
		let destinationURL = try await _directory()
		guard _fileManager.fileExists(atPath: destinationURL.path) else {
			return false
		}
		guard let appURL = _fileManager.getPath(in: destinationURL, for: "app") else {
			try _fileManager.removeFileIfNeeded(at: destinationURL)
			return false
		}

		try await _commitToDatabase(appURL: appURL)
		try? await clean()
		return true
	}

	static func removeImportTransaction(transactionIdentifier: String) async {
		await MainActor.run {
			try? Storage.shared.removeImported(uuid: transactionIdentifier)
		}
		let fileManager = FileManager.default
		try? fileManager.removeFileIfNeeded(
			at: fileManager.unsigned(transactionIdentifier)
		)
		try? fileManager.removeFileIfNeeded(
			at: fileManager.temporaryDirectory.appendingPathComponent(
				"AetherImport_\(transactionIdentifier)",
				isDirectory: true
			)
		)
	}

	private func _commitToDatabase(appURL: URL) async throws {
		try Task.checkCancellation()
		let bundle = Bundle(url: appURL)
		try await MainActor.run {
			if Task.isCancelled { throw CancellationError() }
			try Storage.shared.upsertImported(
				uuid: _uuid,
				source: _sourceProvenance?.sourceRepositoryURL,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			)

			if let sourceProvenance = _sourceProvenance {
				Storage.shared.addSourceMetadata(
					for: _uuid,
					kind: .imported,
					provenance: sourceProvenance
				)
				if Storage.shared.context.hasChanges {
					try Storage.shared.context.save()
				}
			}
		}
	}
	
	private func _directory() async throws -> URL {
		// Documents/Aether/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}

	private func _checkAvailableDiskSpace() throws {
		let fileSize = Int64(
			(try _ipa.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
		)
		let values = try URL.documentsDirectory.resourceValues(
			forKeys: [.volumeAvailableCapacityForImportantUsageKey]
		)
		guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
		let expansion = _archiveInspection?.uncompressedBytes ?? fileSize
		let requiredBytes = fileSize.addingReportingOverflow(expansion)
		let required = requiredBytes.overflow
			? Int64.max
			: max(requiredBytes.partialValue, 512 * 1024 * 1024)
		guard available >= required else {
			throw ImportedFileHandlerError.insufficientDiskSpace(required: required, available: available)
		}
	}

	/// Reads only ZIP metadata before extraction. `Zip.unzipFile` is deliberately
	/// kept for the actual work, but it does not expose a way to cap expansion;
	/// without this check a tiny hostile IPA can consume arbitrary storage.
	private func _inspectArchiveIfNeeded() throws {
		guard _archiveInspection == nil else { return }
		let fileSize = Int64((try _ipa.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
		guard fileSize > 0 else { throw ImportedFileHandlerError.unsafeArchive("The archive is empty.") }

		let handle = try FileHandle(forReadingFrom: _ipa)
		defer { try? handle.close() }
		let tailSize = min(fileSize, 65_557)
		try handle.seek(toOffset: UInt64(fileSize - tailSize))
		let tail = try handle.readToEnd() ?? Data()
		guard let eocdOffset = _endOfCentralDirectory(in: tail) else {
			throw ImportedFileHandlerError.unsafeArchive("The archive directory is invalid.")
		}

		let entries = try _littleEndianUInt16(in: tail, at: eocdOffset + 10)
		let centralDirectorySize = try _littleEndianUInt32(in: tail, at: eocdOffset + 12)
		let centralDirectoryOffset = try _littleEndianUInt32(in: tail, at: eocdOffset + 16)
		guard entries != UInt16.max,
			centralDirectorySize != UInt32.max,
			centralDirectoryOffset != UInt32.max
		else {
			throw ImportedFileHandlerError.unsafeArchive("ZIP64 archives aren’t supported for import.")
		}
		guard Int(entries) <= Self.maximumArchiveEntries else {
			throw ImportedFileHandlerError.unsafeArchive("The archive contains too many files.")
		}

		let directoryEnd = UInt64(centralDirectoryOffset) + UInt64(centralDirectorySize)
		guard directoryEnd <= UInt64(fileSize) else {
			throw ImportedFileHandlerError.unsafeArchive("The archive directory is outside the file.")
		}

		var cursor = UInt64(centralDirectoryOffset)
		var totalUncompressed: Int64 = 0
		for _ in 0..<Int(entries) {
			try handle.seek(toOffset: cursor)
			let header = try handle.read(upToCount: 46) ?? Data()
			guard try _littleEndianUInt32(in: header, at: 0) == 0x02014b50 else {
				throw ImportedFileHandlerError.unsafeArchive("The archive contains an invalid file entry.")
			}
			let compressedSize = try _littleEndianUInt32(in: header, at: 20)
			let uncompressedSize = try _littleEndianUInt32(in: header, at: 24)
			let nameLength = try _littleEndianUInt16(in: header, at: 28)
			let extraLength = try _littleEndianUInt16(in: header, at: 30)
			let commentLength = try _littleEndianUInt16(in: header, at: 32)
			guard compressedSize != UInt32.max, uncompressedSize != UInt32.max else {
				throw ImportedFileHandlerError.unsafeArchive("ZIP64 file entries aren’t supported for import.")
			}

			let newTotal = totalUncompressed.addingReportingOverflow(Int64(uncompressedSize))
			guard !newTotal.overflow, newTotal.partialValue <= Self.maximumUncompressedArchiveBytes else {
				throw ImportedFileHandlerError.unsafeArchive("The archive expands to an unsafe size.")
			}
			totalUncompressed = newTotal.partialValue

			let recordLength = UInt64(46 + Int(nameLength) + Int(extraLength) + Int(commentLength))
			guard cursor + recordLength <= directoryEnd else {
				throw ImportedFileHandlerError.unsafeArchive("The archive directory is truncated.")
			}
			cursor += recordLength
		}

		_archiveInspection = ArchiveInspection(entryCount: Int(entries), uncompressedBytes: totalUncompressed)
	}

	private func _endOfCentralDirectory(in tail: Data) -> Int? {
		guard tail.count >= 22 else { return nil }
		for offset in stride(from: tail.count - 22, through: 0, by: -1) {
			if (try? _littleEndianUInt32(in: tail, at: offset)) == 0x06054b50 {
				return offset
			}
		}
		return nil
	}

	private func _littleEndianUInt16(in data: Data, at offset: Int) throws -> UInt16 {
		guard offset >= 0, offset + 2 <= data.count else { throw ImportedFileHandlerError.unsafeArchive("The archive metadata is truncated.") }
		return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
	}

	private func _littleEndianUInt32(in data: Data, at offset: Int) throws -> UInt32 {
		guard offset >= 0, offset + 4 <= data.count else { throw ImportedFileHandlerError.unsafeArchive("The archive metadata is truncated.") }
		return UInt32(data[offset])
			| (UInt32(data[offset + 1]) << 8)
			| (UInt32(data[offset + 2]) << 16)
			| (UInt32(data[offset + 3]) << 24)
	}
}

private enum ImportedFileHandlerError: LocalizedError {
	case payloadNotFound
	case appBundleNotFound
	case insufficientDiskSpace(required: Int64, available: Int64)
	case unsafeArchive(String)

	var errorDescription: String? {
		switch self {
		case .payloadNotFound:
			return "The archive does not contain a Payload directory."
		case .appBundleNotFound:
			return "The archive does not contain an application bundle."
		case .insufficientDiskSpace(let required, let available):
			return "Not enough free space to import this IPA. Aether needs about \(required.formattedByteCount), but \(available.formattedByteCount) is available."
		case .unsafeArchive(let message):
			return message
		}
	}
}
