//
//  ArchiveHandler.swift
//  Aether
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import IDeviceSwift

// Immutable inputs cross workers; the lock protects source and cleanup state.
final class ArchiveHandler: NSObject, @unchecked Sendable {
	enum Purpose: Equatable {
		case install
		case export
	}

	let viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private struct Source: Sendable {
		let appURL: URL
		let lease: LibraryArtifactAccess.ReadLease
	}
	private var _source: Source?
	
	private let _app: AppSnapshot
	private let _purpose: Purpose
	private let _uniqueWorkDir: URL
	private let _operationLock = NSLock()
	private var _activeWorkOperations = 0
	private var _cleanupRequested = false
	private var _hasCleaned = false
	
	init(app: AppSnapshot, viewModel: InstallerStatusViewModel, purpose: Purpose) {
		self.viewModel = viewModel
		self._app = app
		self._purpose = purpose
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("AetherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	func move() async throws {
		try _beginWorkOperation()
		defer { _finishWorkOperation() }

		let app = _app
		let lease = try await MainActor.run {
			try LibraryArtifactAccess.shared.acquireRead(for: app)
		}
		let workDirectory = _uniqueWorkDir
		let worker = Task.detached(priority: .utility) { [fileManager = _fileManager] in
			try Task.checkCancellation()
			guard let appURL = fileManager.getPath(in: lease.directory, for: "app") else {
				throw SigningFileHandlerError.appNotFound
			}

			// Payload is a ZIP path prefix; the app stays in its leased directory.
			try fileManager.createDirectoryIfNeeded(at: workDirectory)
			try Task.checkCancellation()
			return Source(appURL: appURL, lease: lease)
		}
		let source = try await withTaskCancellationHandler {
			try await worker.value
		} onCancel: { worker.cancel() }
		_operationLock.withLock { _source = source }
	}
	
	func archive() async throws -> URL {
		try _beginWorkOperation()
		defer { _finishWorkOperation() }

		let worker = Task.detached(priority: .utility) { [self] in
			try Task.checkCancellation()
			guard let source = self._operationLock.withLock({ self._source }) else {
				throw SigningFileHandlerError.appNotFound
			}
			// The local reference keeps the read lease alive through cancellation.
			defer { withExtendedLifetime(source.lease) {} }
			
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
			let progressLock = NSLock()
			var lastProgressUpdate = Date.distantPast
			// Install and export packaging both honor Archive & Compression settings.
			let compression = ArchiveHandler.compressionLevel()

			let entries = try BundlePackageWriter.entries(at: source.appURL,
				rootName: "Payload/" + source.appURL.lastPathComponent)
			let level: Int32
			switch compression {
			case .NoCompression: level = 0
			case .BestSpeed: level = 1
			case .DefaultCompression: level = -1
			case .BestCompression: level = 9
			}
			let report: (Double) -> Void = { progress in
				progressLock.lock()
				let now = Date()
				let shouldPublish = now.timeIntervalSince(lastProgressUpdate) >= 0.125 || progress >= 1
				if shouldPublish {
					lastProgressUpdate = now
				}
				progressLock.unlock()
				guard shouldPublish, !Task.isCancelled else { return }
				Task { @MainActor in self.viewModel.packageProgress = progress }
			}
			try BundlePackageWriter.write(entries, to: ipaUrl, compression: level, progress: report)
			try Task.checkCancellation()
			return ipaUrl
		}
		return try await withTaskCancellationHandler {
			try await worker.value
		} onCancel: { worker.cancel() }
	}
	
	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		try _beginWorkOperation()
		defer { _finishWorkOperation() }

		let name = _safeFilenameComponent(_app.name ?? _app.identifier ?? "App")
		let version = _safeFilenameComponent(_app.version ?? "Unknown")
		let appendingString = "\(name)_\(version)_\(Int(Date().timeIntervalSince1970))_\(_uuid).ipa"
		let dest = _fileManager.archives.appendingPathComponent(appendingString)
		
		try _fileManager.moveItem(
			at: package,
			to: dest
		)
		
		if shouldOpen {
			if let sharedArchivesURL = FileManager.default.archives.toSharedDocumentsURL() {
				await MainActor.run {
					UIApplication.open(sharedArchivesURL)
				}
			}
		}
		
		return dest
	}

	func clean() {
		_operationLock.lock()
		if _hasCleaned {
			_operationLock.unlock()
			return
		}
		if _activeWorkOperations > 0 {
			_cleanupRequested = true
			_operationLock.unlock()
			return
		}
		_hasCleaned = true
		_operationLock.unlock()
		_removeWorkDirectory()
	}

	private func _beginWorkOperation() throws {
		_operationLock.lock()
		defer { _operationLock.unlock() }
		guard !_hasCleaned else {
			throw SigningFileHandlerError.appNotFound
		}
		_activeWorkOperations += 1
	}

	private func _finishWorkOperation() {
		_operationLock.lock()
		_activeWorkOperations -= 1
		let shouldClean = _activeWorkOperations == 0 && _cleanupRequested && !_hasCleaned
		if shouldClean {
			_hasCleaned = true
		}
		_operationLock.unlock()

		if shouldClean {
			_removeWorkDirectory()
		}
	}

	private func _removeWorkDirectory() {
		_operationLock.withLock { _source = nil }
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	private func _safeFilenameComponent(_ value: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
		let sanitized = value.unicodeScalars
			.map { allowed.contains($0) ? String($0) : "_" }
			.joined()
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return String((sanitized.isEmpty ? "Unknown" : sanitized).prefix(80))
	}
	
	static func compressionLevel() -> ZipCompression {
		guard let rawValue = UserDefaults.standard.object(forKey: "Aether.compressionLevel") as? Int else {
			return .DefaultCompression
		}
		return ZipCompression.allCases.first(where: { $0.rawValue == rawValue })
			?? .DefaultCompression
	}
}
