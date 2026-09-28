//
//  ConduitInstaller.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import UIKit.UIApplication

public class InstallationProxy: Identifiable, ObservableObject {
	private let _heartbeat = HeartbeatManager.shared
	private let _uuid = UUID().uuidString

	typealias AfcClientHandle = OpaquePointer
	typealias AfcFileHandle = OpaquePointer
	typealias InstallationProxyClientHandle = OpaquePointer

	@ObservedObject
	public var viewModel: InstallerStatusViewModel

	public init(viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
	}

	public func install(at url: URL, suspend: Bool = false) async throws {
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
		var remotePath: String?

		try await Task.detached(priority: .utility) {
			guard HeartbeatManager.hasPairingFile() else {
				throw IDeviceConnectionError.pairingFileMissing
			}

			if await self._heartbeat.isRsd {
			} else {
				let connection = await self._heartbeat.checkSocketConnection()
				guard connection.isConnected else {
					throw IDeviceConnectionError.legacyEndpointUnavailable(connection.error)
				}
			}

			defer {
				if let fileHandle {
					if let error = afc_file_close(fileHandle) {
						idevice_error_free(error)
					}
				}
				if let afcClient, let remotePath,
				   let error = afc_remove_path(afcClient, remotePath) {
					idevice_error_free(error)
				}
				installation_proxy_client_free(installproxy)
				afc_client_free(afcClient)
			}

			let heartbeat = await self._heartbeat

			if heartbeat.isRsd {
				do {
					try heartbeat.withRSDServiceConnection { adapter, handshake in
						afc_client_connect_rsd(adapter, handshake, &afcClient)
					}
				} catch {
					throw IDeviceConnectionError.afcConnectionFailed(error.localizedDescription)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceConnectionError.tcpProviderUnavailable
				}

				if let error = afc_client_connect(provider, &afcClient) {
					let reason = IDeviceSwiftError(error).localizedDescription
					throw IDeviceConnectionError.afcConnectionFailed(reason)
				}
			}

			let stagingDir = "PublicStaging"

			let afc_make_directory_result =  afc_make_directory(afcClient, stagingDir)
			guard afc_make_directory_result == nil else {
				throw IDeviceSwiftError(afc_make_directory_result)
			}

			let remoteDir = "/\(stagingDir)/\(self._uuid).ipa"
			remotePath = remoteDir

			let afc_file_open_result = afc_file_open(afcClient, remoteDir, AfcWrOnly, &fileHandle)
			guard afc_file_open_result == nil else {
				throw IDeviceSwiftError(afc_file_open_result)
			}

			try await self._updateStatus(with: .sendingPayload)

			guard let openedFileHandle = fileHandle else {
				throw IDeviceSwiftError(message: "Missing File Handle")
			}

			let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
			let totalSize = Int64(resourceValues.fileSize ?? 0)
			let localFile = try FileHandle(forReadingFrom: url)
			defer { try? localFile.close() }

			let chunkSize = 4 * 1024 * 1024
			var totalBytesWritten: Int64 = 0
			while let chunk = try localFile.read(upToCount: chunkSize), !chunk.isEmpty {
				try Task.checkCancellation()
				let writeError = chunk.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
					guard let baseAddress = buffer.baseAddress else { return nil }
					return afc_file_write(
						openedFileHandle,
						baseAddress.assumingMemoryBound(to: UInt8.self),
						chunk.count
					)
				}
				if let writeError {
					throw IDeviceSwiftError(writeError)
				}

				totalBytesWritten += Int64(chunk.count)
				let progress = totalSize > 0
					? Double(totalBytesWritten) / Double(totalSize)
					: 1
				try await self._updateUploadProgress(with: min(progress, 1))
			}

			let afc_file_close_result = afc_file_close(openedFileHandle)
			fileHandle = nil
			guard afc_file_close_result == nil else {
				throw IDeviceSwiftError(afc_file_close_result)
			}

			try await self._updateStatus(with: .installing)


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

			let installError: UnsafeMutablePointer<IdeviceFfiError>? = remoteDir.withCString { cString in
				let context = Unmanaged.passUnretained(self).toOpaque()

				if suspend {
					DispatchQueue.main.async {
						UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}

				return installation_proxy_install_with_callback(
					installproxy,
					cString,
					nil, // options
					Self._installationProgressCallback,
					context
				)
			}

			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}

			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(())))
		}.value
	}

	private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}

	private func _updateUploadProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.uploadProgress = status
		}
	}

	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64,
		UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context = context else { return }
		let installer = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
		Task {
			try? await installer._updateInstallProgress(with: Double(progress) / 100.0)
		}
	}

	private func _updateInstallProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.installProgress = status
		}
	}
}
