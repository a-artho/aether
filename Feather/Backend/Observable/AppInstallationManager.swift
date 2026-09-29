//
//  AppInstallationManager.swift
//  Feather
//
//  Created by samara on 28.09.2026.
//

import SwiftUI
import Combine
import Foundation
import IDeviceSwift

@MainActor
final class AppInstallationManager: ObservableObject {
	static let shared = AppInstallationManager()
	
	@Published var activeApp: AppInfoPresentable?
	@Published var viewModel: InstallerStatusViewModel?
	@Published var installer: ServerInstaller?
	@Published var archiveHandler: ArchiveHandler?
	@Published var isWebviewPresenting: Bool = false
	@Published var lastErrorMessage: String?
	
	private var progressTask: Task<Void, Never>?
	private var iDevicePreflightTask: Task<Void, Never>?
	private var installTask: Task<Void, Never>?
	private var installGeneration = UUID()
	private var cancellables = Set<AnyCancellable>()
	private var _hasLaunchedSemiLocalInstall = false
	
	private var _installationMethod: Int {
		UserDefaults.standard.integer(forKey: "Feather.installationMethod")
	}
	
	private var _serverMethod: Int {
		UserDefaults.standard.object(forKey: "Feather.serverMethod") as? Int ?? 1
	}
	
	private init() {}
	
	var isInstalling: Bool {
		if iDevicePreflightTask != nil || installTask != nil {
			return true
		}
		guard activeApp != nil, let viewModel else {
			return activeApp != nil
		}
		switch viewModel.status {
		case .completed, .broken:
			return false
		default:
			return true
		}
	}
	
	func startInstall(app: AppInfoPresentable) {
		cancel()
		let appName = app.name ?? app.identifier ?? .localized("app")
		_log("Install requested for \(appName).", category: "Install", level: .notice)
		
		guard app.identifier != Bundle.main.bundleIdentifier || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}

		guard _installationMethod == 1 else {
			_beginInstall(app)
			return
		}

		iDevicePreflightTask = Task { [weak self] in
			do {
				try await DeviceConnectionManager.shared.ensureConnected()
			} catch {
				guard !Task.isCancelled, let self else { return }
				self.iDevicePreflightTask = nil
				self._showIDevicePreflightAlert(
					title: .localized("Device Connection Unavailable"),
					message: error.localizedDescription
				)
				self._log("Device install preflight failed: \(error.localizedDescription)", category: "Device", level: .error)
				return
			}

			guard !Task.isCancelled, let self else { return }
			self.iDevicePreflightTask = nil
			self._beginInstall(app)
		}
	}

	private func _beginInstall(_ app: AppInfoPresentable) {
		let appSnapshot = AppSnapshot(app)
		let generation = UUID()
		installGeneration = generation
		AppTabManager.shared.switchTo(.installed)
		
		self.activeApp = app
		self.lastErrorMessage = nil
		self._hasLaunchedSemiLocalInstall = false
		_log(
			"Preparing \(_installationMethod == 1 ? "device" : "server") install for \(app.name ?? app.identifier ?? .localized("app")).",
			category: "Install"
		)
		
		let statusVM = InstallerStatusViewModel(isIdevice: _installationMethod == 1)
		self.viewModel = statusVM
		
		statusVM.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] newStatus in
				self?._handleStatusChange(newStatus)
			}
			.store(in: &cancellables)
		
		#if !targetEnvironment(macCatalyst)
		if _installationMethod == 0 {
			BackgroundAudioManager.shared.start("installation")
		}
		#endif
		
		installTask = Task.detached { [weak self, appSnapshot] in
			var currentHandler: ArchiveHandler?
			do {
				try Task.checkCancellation()
				let handler = ArchiveHandler(app: appSnapshot, viewModel: statusVM, purpose: .install)
				currentHandler = handler
				guard await MainActor.run(body: {
					self?.installGeneration == generation && !Task.isCancelled
				}) else {
					handler.clean()
					return
				}
				await MainActor.run {
					self?.archiveHandler = handler
				}
				try await handler.move()
				try Task.checkCancellation()
				
				let packageUrl = try await handler.archive()
				try Task.checkCancellation()
				
				let method = await MainActor.run { self?._installationMethod ?? 0 }
				if method == 0 {
					let serverInstaller = try await MainActor.run {
						try ServerInstaller(app: appSnapshot, viewModel: statusVM)
					}
					guard await MainActor.run(body: {
						self?.installGeneration == generation && !Task.isCancelled
					}) else {
						handler.clean()
						return
					}
					await MainActor.run {
						self?.installer = serverInstaller
						serverInstaller.packageUrl = packageUrl
						statusVM.status = .ready
					}
				} else if method == 1 {
					defer { handler.clean() }
					let proxy = await InstallationProxy(viewModel: statusVM)
					await MainActor.run {
						self?._log("Sending install to the connected device.", category: "Install", level: .notice)
					}
					try await proxy.install(
						at: packageUrl,
						suspend: appSnapshot.identifier == Bundle.main.bundleIdentifier
					)
				}
			} catch is CancellationError {
				currentHandler?.clean()
			} catch {
				currentHandler?.clean()
				guard await MainActor.run(body: {
					self?.installGeneration == generation && !Task.isCancelled
				}) else { return }
				
				await MainActor.run {
					self?.progressTask?.cancel()
					self?.archiveHandler = nil
					self?.installer = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop("installation")
					#endif
					self?.lastErrorMessage = String(describing: error)
					statusVM.status = .broken(error)
					self?._log("Install failed: \(error.localizedDescription)", category: "Install", level: .error)
				}
			}
		}
	}

	private func _showIDevicePreflightAlert(title: String, message: String) {
		UIAlertController.showAlertWithOk(title: title, message: message)
	}
	
	private func _handleStatusChange(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		guard let app = activeApp, let statusVM = viewModel else { return }
		
		if _installationMethod == 0 {
			if case .ready = newStatus, let installer = self.installer {
				if _serverMethod == 0 {
					if let installURL = URL(string: installer.iTunesLink) {
						UIApplication.shared.open(installURL)
					}
			} else if _serverMethod == 1, !_hasLaunchedSemiLocalInstall {
				_hasLaunchedSemiLocalInstall = true
				let installerID = installer.id
				installer.launchSemiLocalInstall { [weak self] in
					guard self?.installer?.id == installerID else { return }
					self?.isWebviewPresenting = true
				}
				}
			}
			
			if case .sendingPayload = newStatus, _serverMethod == 1 {
				self.isWebviewPresenting = false
			}
			
			if case .installing = newStatus, let bundleIdentifier = app.identifier {
				if progressTask == nil {
					progressTask = startInstallProgressPolling(bundleID: bundleIdentifier, viewModel: statusVM)
				}
			}
			
			switch newStatus {
			case .completed:
				_log("Install completed for \(app.name ?? app.identifier ?? .localized("app")).", category: "Install", level: .notice)
				progressTask?.cancel()
				progressTask = nil
				_cleanupInstallResources()
				NotificationCenter.default.post(name: Notification.Name("Feather.installedAppsRefresh"), object: nil)
				Task { [weak self] in
					try? await Task.sleep(nanoseconds: 3_000_000_000)
					await MainActor.run {
						if self?.viewModel?.isCompleted == true {
							self?.dismiss()
						}
					}
				}
			case .broken:
				_log("Install failed for \(app.name ?? app.identifier ?? .localized("app")).", category: "Install", level: .error)
				progressTask?.cancel()
				progressTask = nil
				_cleanupInstallResources()
			default:
				break
			}
		} else {
			switch newStatus {
			case .completed:
				_log("Device install completed for \(app.name ?? app.identifier ?? .localized("app")).", category: "Install", level: .notice)
				_cleanupInstallResources()
				NotificationCenter.default.post(name: Notification.Name("Feather.installedAppsRefresh"), object: nil)
				if UIApplication.shared.applicationState == .background,
				   DeviceConnectionManager.shared.isAutoTunnelLifecycleEnabled,
				   !DeviceConnectionManager.shared.hasActiveTunnelDependencies {
					DeviceConnectionManager.shared.setConnection(enabled: false)
				}
				Task { [weak self] in
					try? await Task.sleep(nanoseconds: 3_000_000_000)
					await MainActor.run {
						if self?.viewModel?.isCompleted == true {
							self?.dismiss()
						}
					}
				}
			case .broken:
				_log("Device install failed for \(app.name ?? app.identifier ?? .localized("app")).", category: "Install", level: .error)
				_cleanupInstallResources()
				if UIApplication.shared.applicationState == .background,
				   DeviceConnectionManager.shared.isAutoTunnelLifecycleEnabled,
				   !DeviceConnectionManager.shared.hasActiveTunnelDependencies {
					DeviceConnectionManager.shared.setConnection(enabled: false)
				}
			default:
				break
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {
		Task.detached(priority: .background) { [weak self] in
			var hasStarted = false
			var lastPublishedProgress = -1.0
			
			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0
				
				if rawProgress > 0 {
					hasStarted = true
				}
				
				let progress = await hasStarted
					? (self?._normalizeInstallProgress(rawProgress) ?? 0.0)
					: 0.0
				
				if abs(progress - lastPublishedProgress) >= 0.005 {
					lastPublishedProgress = progress
					await MainActor.run {
						viewModel.installProgress = progress
					}
				}
				
				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}
				
				do {
					try await Task.sleep(nanoseconds: 300_000_000)
				} catch {
					break
				}
			}
		}
	}
	
	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
	
	func cancel() {
		installGeneration = UUID()
		installTask?.cancel()
		installTask = nil
		iDevicePreflightTask?.cancel()
		iDevicePreflightTask = nil
		progressTask?.cancel()
		progressTask = nil
		cancellables.removeAll()
		_cleanupInstallResources()
		withAnimation(.easeInOut(duration: 0.25)) {
		self.activeApp = nil
		self.viewModel = nil
		self.lastErrorMessage = nil
		self._hasLaunchedSemiLocalInstall = false
		}
	}
	
	func dismiss() {
		cancel()
	}
	
	private func _cleanupInstallResources() {
		archiveHandler?.clean()
		archiveHandler = nil
		installer = nil
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop("installation")
		#endif
	}

	private func _log(
		_ message: String,
		category: String,
		level: DebugLogItem.Level = .info
	) {
		DebugLogManager.shared.log(message, category: category, level: level)
	}
}

#if DEBUG
struct MockAppPresentable: AppInfoPresentable {
	var name: String? = "Delta"
	var version: String? = "1.6.1"
	var identifier: String? = "com.rileytestut.Delta"
	var date: Date? = Date()
	var icon: String? = nil
	var uuid: String? = "mock-uuid"
	var source: URL? = nil
	var isSigned: Bool = true
}

extension AppInstallationManager {
	func startMockInstall(progress: Double = 0.45, status: InstallerStatusViewModel.InstallerStatus = .installing) {
		cancel()
		let mock = MockAppPresentable()
		self.activeApp = mock
		let vm = InstallerStatusViewModel(status: status, isIdevice: false)
		vm.installProgress = progress
		self.viewModel = vm
	}
}
#endif
