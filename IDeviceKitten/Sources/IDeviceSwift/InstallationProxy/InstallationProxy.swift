//
//  ConduitInstaller.swift
//  Aether
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import UIKit.UIApplication

// One pending main-queue delivery, regardless of how many AFC writes finish.
// Closing discards delayed deliveries so they cannot overwrite a terminal state.
private final class UploadProgressPublisher: @unchecked Sendable {
 private let lock = NSLock()
 private var latest: Double?
 private var scheduled = false
 private var closed = false
 private var highest = 0.0
 private let publish: @MainActor @Sendable (Double) -> Void
 init(publish: @escaping @MainActor @Sendable (Double) -> Void) { self.publish = publish }
 func submit(_ value: Double) {
  lock.lock()
  guard !closed, value.isFinite else { lock.unlock(); return }
  let value = min(1, max(highest, max(0, value)))
  guard value > highest else { lock.unlock(); return }
  highest = value
  latest = value
  let enqueue = !scheduled
  scheduled = true
  lock.unlock()
  if enqueue { DispatchQueue.main.async { [self] in drain() } }
 }
 @MainActor private func drain() {
  lock.lock()
  let value = closed ? nil : latest
  latest = nil
  scheduled = false
  lock.unlock()
  if let value { publish(value) }
 }
 @MainActor func finish() { drain(); cancel() }
 func cancel() { lock.lock(); closed = true; latest = nil; lock.unlock() }
}

// Value-only context retained for the duration of a synchronous native write.
private final class UploadProgressContext {
 let publisher: UploadProgressPublisher
 let acknowledgedBytes: Int64
 let totalBytes: Int64
 init(publisher: UploadProgressPublisher, acknowledgedBytes: Int64, totalBytes: Int64) {
  self.publisher = publisher; self.acknowledgedBytes = acknowledgedBytes; self.totalBytes = totalBytes
 }
 func report(_ bytes: UInt64) {
  guard totalBytes > 0 else { return }
  publisher.submit(min(1, (Double(acknowledgedBytes) + Double(bytes)) / Double(totalBytes)))
 }
}

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

	public func install(
		at url: URL, suspend: Bool = false,
		diagnosticID: String? = nil,
		diagnosticLog: (@Sendable (String) -> Void)? = nil
	) async throws {
		let diagnostics: InstallationTransferDiagnostics?
		if let diagnosticLog {
			diagnostics = await MainActor.run {
				InstallationTransferDiagnostics(id: diagnosticID ?? self._uuid, emit: diagnosticLog)
			}
		} else {
			diagnostics = nil
		}
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
		var remotePath: String?

		let progressPublisher = UploadProgressPublisher { [weak self] value in
			self?.viewModel.uploadProgress = value
		}
		let installationProgressPublisher = UploadProgressPublisher { [weak self] value in
			self?.viewModel.installProgress = value
		}
		defer { progressPublisher.cancel(); installationProgressPublisher.cancel() }
		let worker = Task.detached(priority: .utility) {
			defer { progressPublisher.cancel(); installationProgressPublisher.cancel() }
			var diagnosticOutcome = "failed"
			defer { diagnostics?.finish(outcome: Task.isCancelled ? "cancelled" : diagnosticOutcome) }
			try Task.checkCancellation()
			guard HeartbeatManager.hasPairingFile() else {
				throw IDeviceConnectionError.pairingFileMissing
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

			diagnostics?.transport(isRSD: true)
			do {
				try heartbeat.withRSDServiceConnection { adapter, handshake in
					afc_client_connect_rsd(adapter, handshake, &afcClient)
				}
			} catch {
				throw IDeviceConnectionError.afcConnectionFailed(error.localizedDescription)
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
			diagnostics?.beginUpload(bytes: totalSize, chunkBytes: chunkSize)
			while true {
				let readStarted = diagnostics?.now() ?? 0
				let chunk = try localFile.read(upToCount: chunkSize)
				diagnostics?.recordRead(seconds: (diagnostics?.now() ?? 0) - readStarted)
				guard let chunk, !chunk.isEmpty else { break }
				diagnostics?.recordPayload(chunk)
				try Task.checkCancellation()
				let writeStarted = diagnostics?.now() ?? 0
				var nativeMetrics = AfcWriteDiagnostics()
				let progressContext = UploadProgressContext(publisher: progressPublisher,
					acknowledgedBytes: totalBytesWritten, totalBytes: totalSize)
				let writeError = withExtendedLifetime(progressContext) {
					chunk.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
						guard let baseAddress = buffer.baseAddress else { return nil }
						return afc_file_write_with_progress(openedFileHandle,
							baseAddress.assumingMemoryBound(to: UInt8.self), chunk.count, &nativeMetrics,
							Self._uploadProgressCallback, Unmanaged.passUnretained(progressContext).toOpaque())
					}
				}
				diagnostics?.recordNative(nativeMetrics)
				diagnostics?.recordWrite(bytes: chunk.count, seconds: (diagnostics?.now() ?? 0) - writeStarted, succeeded: writeError == nil)
				if let writeError {
					throw IDeviceSwiftError(writeError)
				}

				totalBytesWritten += Int64(chunk.count)
				let progress = totalSize > 0
					? Double(totalBytesWritten) / Double(totalSize)
					: 1
				let progressStarted = diagnostics?.now() ?? 0
				progressPublisher.submit(min(progress, 1))
				diagnostics?.recordProgress(seconds: (diagnostics?.now() ?? 0) - progressStarted)
			}

			try Task.checkCancellation()
			await MainActor.run { progressPublisher.finish() }
			diagnostics?.endUpload()
			diagnostics?.stage("afc-close")
			let afc_file_close_result = afc_file_close(openedFileHandle)
			fileHandle = nil
			guard afc_file_close_result == nil else {
				throw IDeviceSwiftError(afc_file_close_result)
			}

			try Task.checkCancellation()
			try await self._updateStatus(with: .installing)
			diagnostics?.stage("installation-proxy-connect")

			do {
				try heartbeat.withRSDServiceConnection { adapter, handshake in
					installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				}
			} catch {
				throw IDeviceConnectionError.installationProxyConnectionFailed(
					error.localizedDescription
				)
			}

			try Task.checkCancellation()
			diagnostics?.stage("native-install")

			let installError: UnsafeMutablePointer<IdeviceFfiError>? = remoteDir.withCString { cString in
				let context = Unmanaged.passUnretained(installationProgressPublisher).toOpaque()

				if suspend {
					DispatchQueue.main.async {
						UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}

				return withExtendedLifetime(installationProgressPublisher) { installation_proxy_install_with_callback(
					installproxy,
					cString,
					nil, // options
					Self._installationProgressCallback,
					context
				) }
			}

			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}

			await MainActor.run { installationProgressPublisher.finish() }
			diagnostics?.stage("completion")
			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(())))
			diagnosticOutcome = "success"
		}
		try await withTaskCancellationHandler {
			try await worker.value
		} onCancel: {
			progressPublisher.cancel()
			installationProgressPublisher.cancel()
			worker.cancel()
		}
	}

	private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}

	// Both callbacks coalesce deliveries and drop updates after their operation closes.
	nonisolated static private let _uploadProgressCallback: @convention(c) (
		UInt64, UnsafeMutableRawPointer?
	) -> Void = { bytes, context in
		guard let context else { return }
		Unmanaged<UploadProgressContext>.fromOpaque(context).takeUnretainedValue().report(bytes)
	}

	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64, UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context else { return }
		Unmanaged<UploadProgressPublisher>.fromOpaque(context).takeUnretainedValue().submit(Double(progress) / 100.0)
	}
}
