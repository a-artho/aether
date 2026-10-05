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

final class ArchiveHandler: NSObject {
	enum Purpose: Equatable {
		case install
		case export
	}

	let viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
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
		let workDirectory = _uniqueWorkDir
		let worker = Task.detached(priority: .utility) { [fileManager = _fileManager] in
			try Task.checkCancellation()
			guard
				let uuid = app.uuid,
				let appURL = fileManager.getPath(
					in: app.isSigned ? fileManager.signed(uuid) : fileManager.unsigned(uuid),
					for: "app"
				)
			else {
				throw SigningFileHandlerError.appNotFound
			}

			let payloadURL = workDirectory.appendingPathComponent("Payload")
			let movedAppURL = payloadURL.appendingPathComponent(appURL.lastPathComponent)
			try fileManager.createDirectoryIfNeeded(at: payloadURL)
			try fileManager.copyItemPreferClone(at: appURL, to: movedAppURL)
			try Task.checkCancellation()
			return payloadURL
		}
		let payloadURL = try await withTaskCancellationHandler {
			try await worker.value
		} onCancel: { worker.cancel() }
		_payloadUrl = payloadURL
	}
	
	func archive() async throws -> URL {
		try _beginWorkOperation()
		defer { _finishWorkOperation() }

		let worker = Task.detached(priority: .utility) { [self] in
			try Task.checkCancellation()
			guard let payloadUrl = self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}
			
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
			let progressLock = NSLock()
			var lastProgressUpdate = Date.distantPast
			// Install and export packaging both honor Archive & Compression settings.
			let compression = ArchiveHandler.compressionLevel()

			let entries = try BundlePackageWriter.entries(at: payloadUrl)
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
			if self._purpose == .install {
				let reused = try InstallPackageCache.shared.package(entries, to: ipaUrl, compression: level, progress: report)
				await MainActor.run {
					DebugLogManager.shared.log("Install package cache \(reused ? "hit" : "miss").", category: "Install Transfer", level: .info)
				}
			} else {
				try BundlePackageWriter.write(entries, to: ipaUrl, compression: level, progress: report)
			}
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
		let appendingString = "\(name)_\(version)_\(Int(Date().timeIntervalSince1970)).ipa"
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
