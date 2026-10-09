//
//  Server.swift
//  aether
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR AETHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

private enum ServerInstallerError: LocalizedError {
	case unavailable

	var errorDescription: String? {
		switch self {
		case .unavailable:
			return .localized("Unable to start the local install server.")
		}
	}
}

// MARK: - Class
@MainActor
final class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	private let serverMethod: Int
	let viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel, serverMethod: Int) throws {
		self.app = app
		self.serverMethod = serverMethod
		self.viewModel = viewModel
		do {
			try _setup()
			_needsShutdown = true
			try _configureRoutes()
			try _server?.server.start()
		} catch {
			_shutdownServer()
			throw error
		}
	}
	
	isolated deinit {
		_shutdownServer()
	}
	
	private func _setup() throws {
		self._server = try setupApp(port: port)
	}
		
	private func _configureRoutes() throws {
		guard let server = _server else {
			throw ServerInstallerError.unavailable
		}

		// Render UIKit assets once on the main actor. Routes consume immutable snapshots.
		let manifestPath = plistEndpoint.path
		let smallPath = displayImageSmallEndpoint.path
		let largePath = displayImageLargeEndpoint.path
		let payloadPath = payloadEndpoint.path
		let manifest = installManifestData
		let smallImage = displayImageSmallData
		let largeImage = displayImageLargeData
		let installHTML = html
		server.get("*") { [weak self] req async -> Response in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case manifestPath:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: manifest))
			case smallPath:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: smallImage))
			case largePath:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: largeImage))
			case payloadPath:
				guard let packageUrl = await self.packageUrl else {
					return Response(status: .notFound)
				}
				
				return self._streamPayload(at: packageUrl, for: req)

			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: installHTML))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	nonisolated private func _streamPayload(at url: URL, for request: Request) -> Response {
		// Keep Vapor's existing range, cache and content headers. Replace only the
		// body producer so successful writes can report bounded byte progress.
		let response = request.fileio.streamFile(at: url.path)
		guard response.status == .ok || response.status == .partialContent else { return response }
		let count = response.body.count
		guard count >= 0 else { return response }
		let offset: Int64
		if response.status == .partialContent {
			guard let range = response.headers.first(name: .contentRange),
				let start = range.split(separator: " ").last?.split(separator: "-").first,
				let parsed = Int64(start), parsed >= 0 else { return response }
			offset = parsed
		} else { offset = 0 }
		_updateStatus(.sendingPayload)
		response.body = .init(asyncStream: { [weak self] writer in
			let installer = self
			let progress = OperationProgressPublisher { [weak installer] value in
				guard let installer, case .sendingPayload = installer.viewModel.status else { return }
				installer.viewModel.uploadProgress = max(installer.viewModel.uploadProgress, value)
			}
			defer { progress.cancel() }
			do {
				let chunks = try await request.fileio.readFile(at: url.path,
					chunkSize: 64 * 1024, offset: offset, byteCount: count)
				var written = 0
				var lastPublishedAt = DispatchTime.now().uptimeNanoseconds
				for try await chunk in chunks {
					try await writer.write(.buffer(chunk))
					written += chunk.readableBytes
					let now = DispatchTime.now().uptimeNanoseconds
					if now - lastPublishedAt >= 250_000_000 {
						progress.submit(Double(written) / Double(max(1, count)))
						lastPublishedAt = now
					}
				}
				guard written == count else { throw Abort(.internalServerError) }
				try await writer.write(.end)
				progress.cancel()
				await MainActor.run {
					guard let installer, case .sendingPayload = installer.viewModel.status else { return }
					installer.viewModel.uploadProgress = 1
					installer.viewModel.status = .installing
				}
			} catch {
				progress.cancel()
				try? await writer.write(.error(error))
				await MainActor.run {
					guard let installer, case .sendingPayload = installer.viewModel.status else { return }
					installer.viewModel.status = .broken(error)
				}
			}
		}, count: count, byteBufferAllocator: request.byteBufferAllocator)
		return response
	}

	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	nonisolated private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		serverMethod
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.object(forKey: "Aether.ipFix") as? Bool ?? true
	}
}
