//
//  AppLifecycleService.swift
//  IDeviceSwift
//

import Foundation
import IDevice
import UIKit

public enum AppLifecycleService {
	typealias AppServiceHandle = OpaquePointer

	@discardableResult
	public static func launchApp(
		bundleIdentifier: String,
		urlSchemes: [String] = []
	) async throws -> Bool {
		// Prefer the typed RSD AppService transport. It has a defined response
		// contract, unlike the private Objective-C workspace selector.
		let heartbeat = HeartbeatManager.shared
		if HeartbeatManager.hasPairingFile() {
			do {
				let launched = try await Task.detached(priority: .userInitiated) { () -> Bool in
					var appService: AppServiceHandle?
					try heartbeat.withRSDServiceConnection { adapter, handshake in
						app_service_connect_rsd(adapter, handshake, &appService)
					}
					guard let appService else {
						throw IDeviceConnectionError.appServiceConnectionFailed("Could not connect to AppService.")
					}
					defer { app_service_free(appService) }

					var response: UnsafeMutablePointer<LaunchResponseC>?
					let launchErr = bundleIdentifier.withCString { cBundleId in
						app_service_launch_app(appService, cBundleId, nil, 0, 0, 0, nil, &response)
					}
					if let launchErr {
						throw IDeviceSwiftError(launchErr)
					}
					if let response {
						app_service_free_launch_response(response)
					}
					return true
				}.value
				if launched {
					return true
				}
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				// A failed service transport still permits the documented scheme fallback.
			}
		}

		// Fall back to registered URL schemes when the device service is unavailable.
		for scheme in urlSchemes {
			try Task.checkCancellation()
			let clean = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !clean.isEmpty, let url = URL(string: "\(clean)://") else { continue }
			let opened = await withCheckedContinuation { continuation in
				DispatchQueue.main.async {
					if UIApplication.shared.canOpenURL(url) {
						UIApplication.shared.open(url, options: [:]) { success in
							continuation.resume(returning: success)
						}
					} else {
						continuation.resume(returning: false)
					}
				}
			}
			if opened { return true }
		}

		throw IDeviceSwiftError(
			message: "Could not launch \(bundleIdentifier). An active iDevice tunnel or supported URL scheme is required."
		)
	}

	@discardableResult
	public static func terminateApp(
		bundleIdentifier: String,
		executableName: String? = nil
	) async throws -> Bool {
		let heartbeat = HeartbeatManager.shared
		guard HeartbeatManager.hasPairingFile() else {
			throw IDeviceSwiftError(
				message: "Terminating running processes requires an active iDevice RSD tunnel."
			)
		}

		return try await Task.detached(priority: .userInitiated) {
			var appService: AppServiceHandle?
			try heartbeat.withRSDServiceConnection { adapter, handshake in
				app_service_connect_rsd(adapter, handshake, &appService)
			}
			guard let appService else {
				throw IDeviceConnectionError.appServiceConnectionFailed("Could not connect to AppService.")
			}
			defer { app_service_free(appService) }

			var processesPtr: UnsafeMutablePointer<ProcessTokenC>?
			var count: UInt = 0
			let listErr = app_service_list_processes(appService, &processesPtr, &count)
			if let listErr {
				throw IDeviceSwiftError(listErr)
			}
			guard let processesPtr, count > 0 else { return false }
			defer { app_service_free_process_list(processesPtr, count) }

			var killed = false
			for i in 0..<Int(count) {
				let proc = processesPtr[i]
				guard let cUrl = proc.executable_url else { continue }
				let urlStr = String(cString: cUrl)

				var matches = urlStr.localizedCaseInsensitiveContains(bundleIdentifier)
				if !matches, let exe = executableName, !exe.isEmpty {
					matches = urlStr.hasSuffix("/" + exe) || urlStr.localizedCaseInsensitiveContains("/" + exe + ".app/")
				}

				if matches {
					var sigResp: UnsafeMutablePointer<SignalResponseC>?
					let sigErr = app_service_send_signal(appService, proc.pid, 9, &sigResp)
					if let sigErr {
						idevice_error_free(sigErr)
					}
					if let sigResp {
						app_service_free_signal_response(sigResp)
					}
					killed = true
				}
			}

			return killed
		}.value
	}

	public static func uninstallApp(bundleIdentifier: String) async throws {
		try await InstallationAppProxy.deleteApp(for: bundleIdentifier)
	}

}
