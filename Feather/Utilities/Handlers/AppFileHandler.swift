//
//  IPAHandler.swift
//  Feather
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
			.appendingPathComponent("FeatherImport_\(uuid)", isDirectory: true)
		
		super.init()
	}
	
	func copy() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)
		
		try _fileManager.copyItem(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}
	
	func extract() async throws {
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
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							if let download = download {
								DispatchQueue.main.async {
									download.unpackageProgress = progress
									
									#if !targetEnvironment(macCatalyst)
									if #available(iOS 26.0, *) {
										BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
									}
									#endif
								}
							}
						}
					)
					
					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
	
	func move() async throws {
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
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw ImportedFileHandlerError.appBundleNotFound
		}

		try await _commitToDatabase(appURL: appUrl)
	}

	func recoverCommittedImport() async throws -> Bool {
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

	static func removeUncommittedImport(transactionIdentifier: String) async {
		let isCommitted = await MainActor.run {
			do {
				return try Storage.shared.importedExists(uuid: transactionIdentifier)
			} catch {
				// Preserve the destination if Core Data cannot prove it is uncommitted.
				return true
			}
		}
		guard !isCommitted else { return }

		let fileManager = FileManager.default
		try? fileManager.removeFileIfNeeded(
			at: fileManager.unsigned(transactionIdentifier)
		)
		try? fileManager.removeFileIfNeeded(
			at: fileManager.temporaryDirectory.appendingPathComponent(
				"FeatherImport_\(transactionIdentifier)",
				isDirectory: true
			)
		)
	}

	private func _commitToDatabase(appURL: URL) async throws {
		let bundle = Bundle(url: appURL)
		try await MainActor.run {
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
		// Documents/Feather/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

private enum ImportedFileHandlerError: LocalizedError {
	case payloadNotFound
	case appBundleNotFound

	var errorDescription: String? {
		switch self {
		case .payloadNotFound:
			return "The archive does not contain a Payload directory."
		case .appBundleNotFound:
			return "The archive does not contain an application bundle."
		}
	}
}
