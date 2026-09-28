//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
	@State private var installer: ServerInstaller?
	@State private var archiveHandler: ArchiveHandler?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			if let installer {
				SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
			}
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus, let installer {
					if _serverMethod == 0 {
						if let installURL = URL(string: installer.iTunesLink) {
							UIApplication.shared.open(installURL)
						}
					} else if _serverMethod == 1 {
						_isWebviewPresenting = true
					}
				}
				
				if case .sendingPayload = newStatus, _serverMethod == 1 {
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus, let bundleIdentifier = app.identifier {
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: bundleIdentifier,
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					_cleanupInstallResources()
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_cleanupInstallResources()
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}

		#if !targetEnvironment(macCatalyst)
		if !isSharing && _installationMethod == 0 {
			BackgroundAudioManager.shared.start()
		}
		#endif
				
		Task.detached {
			var currentHandler: ArchiveHandler?
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				currentHandler = handler
				await MainActor.run { archiveHandler = handler }
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						let serverInstaller = try await MainActor.run {
							try ServerInstaller(app: app, viewModel: viewModel)
						}
						await MainActor.run {
							installer = serverInstaller
							serverInstaller.packageUrl = packageUrl
							viewModel.status = .ready
						}
					} else if await _installationMethod == 1 {
						defer { handler.clean() }
						let proxy = await InstallationProxy(viewModel: viewModel)
						try await proxy.install(
							at: packageUrl,
							suspend: app.identifier == Bundle.main.bundleIdentifier
						)
					}
				} else {
					defer { handler.clean() }
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				currentHandler?.clean()
				await progressTask?.cancel()
				
				await MainActor.run {
					archiveHandler = nil
					installer = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false
			var lastPublishedProgress = -1.0

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
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

	private func _cleanupInstallResources() {
		archiveHandler?.clean()
		archiveHandler = nil
		installer = nil
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
