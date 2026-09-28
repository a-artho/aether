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
	private var cancellables = Set<AnyCancellable>()
	private var _hasLaunchedSemiLocalInstall = false
	
	private var _installationMethod: Int {
		UserDefaults.standard.integer(forKey: "Feather.installationMethod")
	}
	
	private var _serverMethod: Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}
	
	private init() {}
	
	var isInstalling: Bool {
		activeApp != nil
	}
	
	func startInstall(app: AppInfoPresentable) {
		cancel()
		
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

		guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
			_showIDevicePreflightAlert(
				title: .localized("Pairing File Missing"),
				message: .localized("Import one in Installation settings.")
			)
			return
		}

		iDevicePreflightTask = Task { [weak self] in
			let connection = await Task.detached(priority: .userInitiated) {
				HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 2)
			}.value

			guard !Task.isCancelled, let self else { return }
			self.iDevicePreflightTask = nil

			guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
				self._showIDevicePreflightAlert(
					title: .localized("Pairing File Missing"),
					message: .localized("Import one in Installation settings.")
				)
				return
			}

			guard connection.isConnected else {
				self._showIDevicePreflightAlert(
					title: .localized("LocalDevVPN Not Connected"),
					message: .localized("Turn it on and try again.")
				)
				return
			}

			self._beginInstall(app)
		}
	}

	private func _beginInstall(_ app: AppInfoPresentable) {
		AppTabManager.shared.switchTo(.installed)
		
		self.activeApp = app
		self.lastErrorMessage = nil
		self._hasLaunchedSemiLocalInstall = false
		
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
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		Task.detached { [weak self] in
			var currentHandler: ArchiveHandler?
			do {
				let handler = await ArchiveHandler(app: app, viewModel: statusVM)
				currentHandler = handler
				await MainActor.run {
					self?.archiveHandler = handler
				}
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				let method = await self?._installationMethod ?? 0
				if method == 0 {
					let serverInstaller = try await MainActor.run {
						try ServerInstaller(app: app, viewModel: statusVM)
					}
					await MainActor.run {
						self?.installer = serverInstaller
						serverInstaller.packageUrl = packageUrl
						statusVM.status = .ready
					}
				} else if method == 1 {
					defer { handler.clean() }
					let proxy = await InstallationProxy(viewModel: statusVM)
					try await proxy.install(
						at: packageUrl,
						suspend: app.identifier == Bundle.main.bundleIdentifier
					)
				}
			} catch {
				currentHandler?.clean()
				await self?.progressTask?.cancel()
				
				await MainActor.run {
					self?.archiveHandler = nil
					self?.installer = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
					self?.lastErrorMessage = String(describing: error)
					statusVM.status = .broken(error)
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
				progressTask?.cancel()
				progressTask = nil
				_cleanupInstallResources()
			default:
				break
			}
		} else {
			switch newStatus {
			case .completed:
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
				_cleanupInstallResources()
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
		BackgroundAudioManager.shared.stop()
		#endif
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
