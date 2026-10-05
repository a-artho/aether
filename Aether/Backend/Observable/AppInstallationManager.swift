//
//  AppInstallationManager.swift
//  Aether
//
//  Created by samara on 28.09.2026.
//

import SwiftUI
import Combine
import Foundation
import IDeviceSwift

@MainActor
final class AppInstallationManager: ObservableObject {
	private struct InstallationContext: Sendable {
		let method: Int
		let serverMethod: Int
	}

	struct InstallationRequest: Identifiable, Sendable {
		let id = UUID()
		let app: AppSnapshot
		let method: Int
		let serverMethod: Int
		#if DEBUG
		var isMock = false
		#endif

		var appKey: String { Self.appKey(for: app) }

		static func appKey(for app: AppInfoPresentable) -> String {
			let identity = app.uuid ?? app.source?.absoluteString ?? "\(app.identifier ?? "")|\(app.version ?? "")"
			return "\(app.isSigned)|\(identity)"
		}
	}

	static let shared = AppInstallationManager()
	@Published private(set) var currentRequest: InstallationRequest?
	@Published private(set) var queuedInstalls: [InstallationRequest] = []

	var installationCards: [InstallationRequest] {
		currentRequest.map { [$0] + queuedInstalls } ?? queuedInstalls
	}
	
	@Published var activeApp: AppInfoPresentable?
	@Published var viewModel: InstallerStatusViewModel?
	@Published var installer: ServerInstaller?
	@Published var archiveHandler: ArchiveHandler?
	@Published var isWebviewPresenting: Bool = false
	@Published private(set) var isFinishingInstallation = false
	@Published var lastErrorMessage: String?
	
	private var progressTask: Task<Void, Never>?
	private var iDevicePreflightTask: Task<Void, Never>?
	private var installTask: Task<Void, Never>?
	private var retirementTask: Task<Void, Never>?
	private var retiringAppKey: String?
	private var settlementTask: Task<Void, Never>?
	private var installGeneration = UUID()
	private var cancellables = Set<AnyCancellable>()
	private var _hasLaunchedSemiLocalInstall = false
	private var _backgroundTaskToken: String?
	private var _completedBackgroundInstalls = Set<UUID>()
	private var _backgroundQueueTotal = 1
	private var _backgroundObserver: NSObjectProtocol?
	
	private struct StoredInstallation: Codable {
		let app: AppSnapshot
		let method: Int
		let serverMethod: Int
	}
	private static let queueStorageKey = "Aether.pendingInstallations"

	private init() {
		_backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				guard let self, self.isInstalling else { return }
				#if !targetEnvironment(macCatalyst)
				if self._backgroundTaskToken.map({ BackgroundTaskManager.shared.hasExecution(for: $0) }) != true {
					self._interruptInstallation(generation: self.installGeneration)
				}
				#endif
			}
		}
		guard let data = UserDefaults.standard.data(forKey: Self.queueStorageKey),
			let records = try? JSONDecoder().decode([StoredInstallation].self, from: data) else { return }
		let requests = records.compactMap { record -> InstallationRequest? in
			guard Storage.shared.getAppDirectory(for: record.app) != nil else { return nil }
			return InstallationRequest(app: record.app, method: record.method, serverMethod: record.serverMethod)
		}
		guard let first = requests.first else {
			UserDefaults.standard.removeObject(forKey: Self.queueStorageKey)
			return
		}
		// The device may have completed installation while Aether was terminated.
		// Preserve the request, but require Retry/Cancel instead of installing twice.
		currentRequest = first
		activeApp = first.app
		queuedInstalls = Array(requests.dropFirst())
		let model = InstallerStatusViewModel(isIdevice: first.method == 1)
		model.status = .broken(InstallationBackgroundError())
		viewModel = model
		lastErrorMessage = InstallationBackgroundError().localizedDescription
		_log("Restored interrupted install queue; waiting for Retry/Cancel.", category: "Background", level: .notice)
	}

	private func _persistInstallQueue() {
		let requests = (currentRequest.map { [$0] } ?? []) + queuedInstalls
		let records = requests.compactMap { request -> StoredInstallation? in
			#if DEBUG
			if request.isMock { return nil }
			#endif
			if request.id == currentRequest?.id, hasCompletedSuccessfully { return nil }
			return StoredInstallation(app: request.app, method: request.method, serverMethod: request.serverMethod)
		}
		if records.isEmpty { UserDefaults.standard.removeObject(forKey: Self.queueStorageKey) }
		else if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.queueStorageKey) }
	}
	
	var isInstalling: Bool {
		if retirementTask != nil || iDevicePreflightTask != nil || installTask != nil {
			return true
		}
		if !queuedInstalls.isEmpty, hasCompletedSuccessfully { return true }
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

	var hasPendingInstalls: Bool { isInstalling || !queuedInstalls.isEmpty }

	func containsInstallation(for app: AppInfoPresentable) -> Bool {
		let key = InstallationRequest.appKey(for: app)
		return currentRequest?.appKey == key || retiringAppKey == key || queuedInstalls.contains { $0.appKey == key }
	}

	private var hasCompletedSuccessfully: Bool {
		if case .completed(.success) = viewModel?.status { return true }
		return false
	}
	
	func startInstall(app: AppInfoPresentable) {
		let request = InstallationRequest(
			app: AppSnapshot(app),
			method: UserDefaults.standard.integer(forKey: "Aether.installationMethod"),
			serverMethod: UserDefaults.standard.object(forKey: "Aether.serverMethod") as? Int ?? 1
		)
		guard app.identifier != Bundle.main.bundleIdentifier || request.method == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
		_enqueue(request)
	}

	private func _enqueue(_ request: InstallationRequest) {
		AppTabManager.shared.switchTo(.installed)
		if currentRequest?.appKey == request.appKey, !hasCompletedSuccessfully {
			if case .broken = viewModel?.status { retryActiveInstall() }
			return
		}
		guard !queuedInstalls.contains(where: { $0.appKey == request.appKey }) else { return }
		queuedInstalls.append(request)
		_persistInstallQueue()
		_log("Install queued for \(request.app.name ?? request.app.identifier ?? .localized("app")).", category: "Install", level: .notice)
		if hasCompletedSuccessfully {
			_finishCompletedInstall(generation: installGeneration)
		} else {
			_startNextIfPossible()
		}
	}

	func cancelQueuedInstall(id: UUID) {
		queuedInstalls.removeAll { $0.id == id }
		_persistInstallQueue()
	}

	func retryActiveInstall() {
		guard let request = currentRequest, case .broken = viewModel?.status else { return }
		queuedInstalls.insert(request, at: 0)
		cancel()
	}

	private func _startNextIfPossible() {
		guard currentRequest == nil, retirementTask == nil, !queuedInstalls.isEmpty else { return }
		let request = queuedInstalls.removeFirst()
		let generation = UUID()
		installGeneration = generation
		let context = InstallationContext(method: request.method, serverMethod: request.serverMethod)
		let statusVM = InstallerStatusViewModel(isIdevice: request.method == 1)
		viewModel = statusVM
		activeApp = request.app
		currentRequest = request
		_persistInstallQueue()
		lastErrorMessage = nil
		_hasLaunchedSemiLocalInstall = false
		statusVM.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] status in
				self?._handleStatusChange(status, context: context, generation: generation)
			}
			.store(in: &cancellables)

		#if DEBUG
		if request.isMock {
			statusVM.installProgress = 0.62
			statusVM.status = .installing
			return
		}
		#endif

		guard _startInstallationExecution(request, generation: generation) else {
			statusVM.status = .broken(InstallationBackgroundError())
			return
		}
		statusVM.$packageProgress.combineLatest(statusVM.$uploadProgress, statusVM.$installProgress)
			.throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
			.sink { [weak self, weak statusVM] _ in
				guard let self, let statusVM, self.installGeneration == generation else { return }
				self._updateInstallationExecution(statusVM)
			}
			.store(in: &cancellables)

		guard request.method == 1 else {
			_beginInstall(request.app, context: context, statusVM: statusVM, generation: generation)
			return
		}
		iDevicePreflightTask = Task { [weak self] in
			do {
				try await DeviceConnectionManager.shared.ensureConnected()
				try Task.checkCancellation()
				guard let self, self.installGeneration == generation else { return }
				self.iDevicePreflightTask = nil
				self._beginInstall(request.app, context: context, statusVM: statusVM, generation: generation)
			} catch {
				guard !Task.isCancelled, let self, self.installGeneration == generation else { return }
				self.iDevicePreflightTask = nil
				self.lastErrorMessage = error.localizedDescription
				statusVM.status = .broken(error)
				self._showIDevicePreflightAlert(title: .localized("Device Connection Unavailable"), message: error.localizedDescription)
			}
		}
	}

	private func _beginInstall(
		_ appSnapshot: AppSnapshot,
		context: InstallationContext,
		statusVM: InstallerStatusViewModel,
		generation: UUID
	) {
		_log("Preparing \(context.method == 1 ? "device" : "server") install for \(appSnapshot.name ?? appSnapshot.identifier ?? .localized("app")).", category: "Install")

		#if !targetEnvironment(macCatalyst)
		if context.method == 0 {
			BackgroundAudioManager.shared.start("installation")
		}
		#endif
		
		let diagnosticLog: (@Sendable (String) -> Void)?
		if DebugLogManager.shared.isLoggingEnabled {
			diagnosticLog = { message in
				_ = Task<Void, Never> { @MainActor in
					DebugLogManager.shared.log(message, category: "Install Transfer", level: .notice)
				}
			}
		} else {
			diagnosticLog = nil
		}
		let diagnosticProvider = DeviceConnectionManager.shared.tunnelMethod.displayName
		if context.method == 1, diagnosticLog != nil {
			_log("transfer[\(generation.uuidString)] app=\(appSnapshot.name ?? "unknown") version=\(appSnapshot.version ?? "unknown") provider=\(diagnosticProvider) compression=\(ArchiveHandler.compressionLevel().rawValue) diagnosticSchema=2", category: "Install Transfer", level: .notice)
		}
		installTask = Task.detached { [weak self, appSnapshot] in
			defer {
				Task { @MainActor [weak self] in
					self?._installWorkerDidFinish(generation: generation)
				}
			}
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
				let preparationStarted = diagnosticLog == nil ? 0 : ProcessInfo.processInfo.systemUptime
				try await handler.move()
				let packagingStarted = diagnosticLog == nil ? 0 : ProcessInfo.processInfo.systemUptime
				try Task.checkCancellation()
				
				let packageUrl = try await handler.archive()
				if let diagnosticLog {
					let now = ProcessInfo.processInfo.systemUptime
					let bytes = (try? packageUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
					diagnosticLog("transfer[\(generation.uuidString)] preparationSeconds=\(now - preparationStarted) moveSeconds=\(packagingStarted - preparationStarted) packagingSeconds=\(now - packagingStarted) packagedBytes=\(bytes)")
				}
				try Task.checkCancellation()
				
				if context.method == 0 {
					let serverInstaller = try await MainActor.run {
						try ServerInstaller(app: appSnapshot, viewModel: statusVM, serverMethod: context.serverMethod)
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
				} else {
					defer { handler.clean() }
					let proxy = await InstallationProxy(viewModel: statusVM)
					await MainActor.run {
						self?._log("Sending install to the connected device.", category: "Install", level: .notice)
					}
					try await proxy.install(
						at: packageUrl,
						suspend: appSnapshot.identifier == Bundle.main.bundleIdentifier,
						diagnosticID: generation.uuidString,
						diagnosticLog: diagnosticLog
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

	private func _installWorkerDidFinish(generation: UUID) {
		guard installGeneration == generation else { return }
		installTask = nil
		_releaseBackgroundConnectionIfIdle()
	}

	private func _releaseBackgroundConnectionIfIdle() {
		guard UIApplication.shared.applicationState == .background, !isInstalling else { return }
		DeviceConnectionManager.shared.handleAppBackground()
	}

	private func _showIDevicePreflightAlert(title: String, message: String) {
		UIAlertController.showAlertWithOk(title: title, message: message)
	}
	
	private func _handleStatusChange(
		_ newStatus: InstallerStatusViewModel.InstallerStatus,
		context: InstallationContext,
		generation: UUID
	) {
		guard installGeneration == generation, let app = activeApp, let statusVM = viewModel else { return }
		if case .completed(.failure(let error)) = newStatus {
			statusVM.status = .broken(error)
			return
		}
		#if DEBUG
		let isMock = currentRequest?.isMock == true
		#else
		let isMock = false
		#endif
		
		if context.method == 0 {
			if case .ready = newStatus, let installer = self.installer {
				if context.serverMethod == 0 {
					if let installURL = URL(string: installer.iTunesLink) {
						UIApplication.shared.open(installURL)
					}
			} else if context.serverMethod == 1, !_hasLaunchedSemiLocalInstall {
				_hasLaunchedSemiLocalInstall = true
				let installerID = installer.id
				installer.launchSemiLocalInstall { [weak self] in
					guard self?.installer?.id == installerID else { return }
					self?.isWebviewPresenting = true
				}
				}
			}
			
			if case .sendingPayload = newStatus, context.serverMethod == 1 {
				self.isWebviewPresenting = false
			}
			
			if case .installing = newStatus, !isMock, let bundleIdentifier = app.identifier {
				if progressTask == nil {
					progressTask = startInstallProgressPolling(bundleID: bundleIdentifier, viewModel: statusVM, generation: generation)
				}
			}
			
		}

		_updateInstallationExecution(statusVM)
		switch newStatus {
		case .completed:
			isFinishingInstallation = false
			if let request = currentRequest { _completedBackgroundInstalls.insert(request.id) }
			_updateInstallationExecution(statusVM)
			_persistInstallQueue()
			_log("Install completed for \(app.name ?? app.identifier ?? .localized("app")).", category: "Install", level: .notice)
			progressTask?.cancel()
			progressTask = nil
			NotificationCenter.default.post(name: Notification.Name("Aether.installedAppsRefresh"), object: nil)
			_finishCompletedInstall(generation: generation)
		case .broken:
			isFinishingInstallation = false
			_endInstallationExecution(success: false)
			_log("Install failed for \(app.name ?? app.identifier ?? .localized("app")). Queue paused.", category: "Install", level: .error)
			progressTask?.cancel()
			progressTask = nil
			settlementTask?.cancel()
			let worker = installTask
			settlementTask = Task { [weak self] in
				await worker?.value
				guard !Task.isCancelled, let self, self.installGeneration == generation else { return }
				self._cleanupInstallResources()
				self.settlementTask = nil
				self._releaseBackgroundConnectionIfIdle()
			}
		default:
			break
		}
	}

	private func _finishCompletedInstall(generation: UUID) {
		settlementTask?.cancel()
		let worker = installTask
		settlementTask = Task { [weak self] in
			await worker?.value
			guard !Task.isCancelled, let self, self.installGeneration == generation else { return }
			self._cleanupInstallResources()
			// Keep the final success card briefly; a waiting app advances immediately.
			if self.queuedInstalls.isEmpty {
				do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
			}
			guard !Task.isCancelled, self.installGeneration == generation else { return }
			self.settlementTask = nil
			self.cancel()
		}
	}

	private func startInstallProgressPolling(
		bundleID: String, viewModel: InstallerStatusViewModel, generation: UUID
	) -> Task<Void, Never> {
		return Task { [weak self, weak viewModel] in
			var progressMonitor = ServerInstallProgress()
			var lastPublishedProgress = -1.0
			while !Task.isCancelled {
				guard let self, let viewModel, self.installGeneration == generation else { return }
				let raw = UIApplication.installProgress(for: bundleID, makeSynchronous: false)
				// Match Feather's progress lifecycle; this is not installed-state verification.
				if progressMonitor.observe(progress: raw) {
					viewModel.installProgress = 1
					viewModel.status = .completed(.success(()))
					return
				}
				let progress = progressMonitor.hasStarted ? min(1, max(0, ((raw ?? 0) - 0.6) / 0.3)) : 0
				if abs(progress - lastPublishedProgress) >= 0.005 {
					lastPublishedProgress = progress
					viewModel.installProgress = progress
				}
				// Avoid Feather's 1 ms polling loop and per-poll logging.
				do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
			}
		}
	}

	func cancel() {
		// Once the native install call has begun, its side effects cannot be
		// rolled back by cancelling a Swift task. Keep the real operation visible.
		if currentRequest?.method == 1, case .installing = viewModel?.status, installTask != nil {
			isFinishingInstallation = true
			_log("Cancel requested after iOS accepted installation; waiting for its result.", category: "Install", level: .notice)
			return
		}
		isFinishingInstallation = false
		if !(hasCompletedSuccessfully && !queuedInstalls.isEmpty) {
			_endInstallationExecution(success: hasCompletedSuccessfully)
		}
		guard currentRequest != nil || activeApp != nil || installTask != nil || iDevicePreflightTask != nil else { return }
		installGeneration = UUID()
		settlementTask?.cancel()
		settlementTask = nil
		let worker = installTask
		let preflight = iDevicePreflightTask
		if worker != nil || preflight != nil { retiringAppKey = currentRequest?.appKey }
		worker?.cancel()
		preflight?.cancel()
		installTask = nil
		iDevicePreflightTask = nil
		progressTask?.cancel()
		progressTask = nil
		cancellables.removeAll()
		isWebviewPresenting = false
		activeApp = nil
		viewModel = nil
		currentRequest = nil
		lastErrorMessage = nil
		_hasLaunchedSemiLocalInstall = false
		_persistInstallQueue()

		guard worker != nil || preflight != nil else {
			_cleanupInstallResources()
			_startNextIfPossible()
			_releaseBackgroundConnectionIfIdle()
			return
		}
		// Cancellation can be cooperative: retain resources and wait for the old
		// worker to exit before allowing another archive or device install to start.
		retirementTask = Task { [weak self] in
			await preflight?.value
			await worker?.value
			guard let self else { return }
			self._cleanupInstallResources()
			self.retiringAppKey = nil
			self.retirementTask = nil
			self._startNextIfPossible()
			self._releaseBackgroundConnectionIfIdle()
		}
	}

	func dismiss() {
		cancel()
	}
	
	private func _cleanupInstallResources() {
		archiveHandler?.clean()
		archiveHandler = nil
		installer = nil
		isWebviewPresenting = false
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop("installation")
		#endif
	}

	private func _startInstallationExecution(_ request: InstallationRequest, generation: UUID) -> Bool {
		#if !targetEnvironment(macCatalyst)
		let token = _backgroundTaskToken ?? "installation-\(generation.uuidString)"
		_backgroundTaskToken = token
		let accepted = BackgroundTaskManager.shared.startWork(for: token,
			title: request.app.name ?? .localized("Installing App"), subtitle: .localized("Preparing Installation"),
			progress: 0, installation: true) { [weak self] in
			self?._interruptInstallation(generation: generation)
		}
		if !accepted {
			_backgroundTaskToken = nil
			_log("Installation background execution unavailable.", category: "Background", level: .notice)
			return UIApplication.shared.applicationState == .active
		}
		#endif
		return true
	}

	private func _interruptInstallation(generation: UUID) {
		guard installGeneration == generation, !hasCompletedSuccessfully else { return }
		_endInstallationExecution(success: false)
		installTask?.cancel()
		iDevicePreflightTask?.cancel()
		progressTask?.cancel()
		lastErrorMessage = InstallationBackgroundError().localizedDescription
		viewModel?.status = .broken(InstallationBackgroundError())
		_persistInstallQueue()
		_log("Installation background time expired; queue paused for Retry/Cancel. transfer[\(generation.uuidString)] status=\(String(describing: viewModel?.status))", category: "Background", level: .notice)
	}

	private func _updateInstallationExecution(_ model: InstallerStatusViewModel) {
		#if !targetEnvironment(macCatalyst)
		guard let token = _backgroundTaskToken else { return }
		let phaseProgress = min(0.99, max(0, model.packageProgress) * 0.25
			+ max(0, model.uploadProgress) * 0.45 + max(0, model.installProgress) * 0.30)
		let remaining = installationCards.filter { !_completedBackgroundInstalls.contains($0.id) }.count
		_backgroundQueueTotal = max(_backgroundQueueTotal, _completedBackgroundInstalls.count + remaining)
		let currentProgress = currentRequest.map { _completedBackgroundInstalls.contains($0.id) } == true ? 0 : phaseProgress
		let progress = (Double(_completedBackgroundInstalls.count) + currentProgress) / Double(_backgroundQueueTotal)
		BackgroundTaskManager.shared.updateWork(for: token,
			title: activeApp?.name ?? .localized("Installing App"), subtitle: model.statusLabel,
			progress: progress)
		#endif
	}

	private func _endInstallationExecution(success: Bool) {
		#if !targetEnvironment(macCatalyst)
		if let token = _backgroundTaskToken { BackgroundTaskManager.shared.stopTask(for: token, success: success) }
		#endif
		_backgroundTaskToken = nil
		_completedBackgroundInstalls.removeAll()
		_backgroundQueueTotal = 1
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
		queuedInstalls.removeAll()
		cancel()
		enqueueMockInstall(name: "Delta", identifier: "com.rileytestut.Delta")
		viewModel?.installProgress = progress
		viewModel?.status = status
	}

	func enqueueMockInstall(name: String, identifier: String) {
		var app = MockAppPresentable()
		app.name = name
		app.identifier = identifier
		app.uuid = identifier
		var request = InstallationRequest(app: AppSnapshot(app), method: 0, serverMethod: 1)
		request.isMock = true
		_enqueue(request)
	}
}
#endif

private struct InstallationBackgroundError: LocalizedError {
	var errorDescription: String? {
		.localized("iOS interrupted background installation. Open Aether and retry. If the app was already installed, refresh the Device list first.")
	}
}
