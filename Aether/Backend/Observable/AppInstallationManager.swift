//
//  AppInstallationManager.swift
//  Aether
//
//  Created by samara on 28.09.2026.
//

import SwiftUI
import Combine
import Foundation
import CoreData
import IDeviceSwift

@MainActor
final class AppInstallationManager: ObservableObject {
	private struct InstallationContext: Sendable {
		let method: Int
		let serverMethod: Int
	}

	struct InstallationRequest: Identifiable, Sendable {
		let id = UUID()
		var app: AppSnapshot
		let method: Int
		let serverMethod: Int
		var signing: SigningInput?
		var installRequested = true
		#if DEBUG
		var isMock = false
		#endif

		var appKey: String { Self.appKey(for: app) }

		static func appKey(for app: AppInfoPresentable) -> String {
			let identity = app.uuid ?? app.source?.absoluteString ?? "\(app.identifier ?? "")|\(app.version ?? "")"
			return "\(app.isSigned)|\(identity)"
		}
	}

	struct SigningInput: Codable, Sendable {
		let options: Options
		let iconData: Data?
		let certificateUUID: String?
	}

	static let shared = AppInstallationManager()
    @Published private var completedArtifacts = Set(UserDefaults.standard.stringArray(forKey: "Aether.completedInstallArtifacts") ?? [])
    func installActionTitle(for app: AppInfoPresentable) -> String {
        completedArtifacts.contains(InstallationRequest.appKey(for: app)) ? .localized("Reinstall") : .localized("Install")
    }

    func forgetInstallation(of app: AppInfoPresentable) {
        completedArtifacts.remove(InstallationRequest.appKey(for: app))
        UserDefaults.standard.set(Array(completedArtifacts), forKey: "Aether.completedInstallArtifacts")
    }
    func forgetInstallations(bundleIdentifier: String) {
        let storage = Storage.shared
        for entity in ["Signed", "Imported"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "identifier == %@", bundleIdentifier)
            for object in (try? storage.context.fetch(request)) ?? [] {
                if let app = object as? AppInfoPresentable { forgetInstallation(of: app) }
            }
        }
    }

	@Published private(set) var currentRequest: InstallationRequest?
	@Published private(set) var uninstallingBundleIdentifiers = Set<String>()
	private var retiringBundleIdentifier: String?
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
	private var installTask: Task<Void, Never>? {
		didSet { execution?.setWorker(installTask) }
	}
	@Published private var retirementTask: Task<Void, Never>?
	private var retiringAppKey: String?
	private var settlementTask: Task<Void, Never>?
	private var installGeneration = UUID()
	private var cancellables = Set<AnyCancellable>()
	private var _hasLaunchedSemiLocalInstall = false
	private var execution: AppOperationExecution?
	private var _backgroundObserver: NSObjectProtocol?
	private var _foregroundObserver: NSObjectProtocol?
	
	private struct StoredInstallation: Codable {
		let app: AppSnapshot
		let method: Int
		let serverMethod: Int
		var signing: SigningInput?
		var installRequested: Bool
	}
	private static let queueStorageKey = "Aether.pendingInstallations"

	private init() {
		_foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in self?._startNextIfPossible() }
		}

		_backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
			object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				guard let self, UIApplication.shared.applicationState == .background, self.isInstalling else { return }
				#if !targetEnvironment(macCatalyst)
				if self.execution?.hasExecution != true {
					self._interruptInstallation(generation: self.installGeneration)
				}
				#endif
			}
		}
		guard let data = UserDefaults.standard.data(forKey: Self.queueStorageKey),
			let records = try? JSONDecoder().decode([StoredInstallation].self, from: data) else { return }
		let requests = records.compactMap { record -> InstallationRequest? in
			guard Storage.shared.getAppDirectory(for: record.app) != nil else { return nil }
			return InstallationRequest(app: record.app, method: record.method, serverMethod: record.serverMethod, signing: record.signing, installRequested: record.installRequested)
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
			return StoredInstallation(app: request.app, method: request.method, serverMethod: request.serverMethod, signing: request.signing, installRequested: request.installRequested)
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

	var hasPendingInstalls: Bool {
		isInstalling || !queuedInstalls.isEmpty || (currentRequest != nil && !hasCompletedSuccessfully)
	}

	var hasRetiringWork: Bool { retirementTask != nil }

	func blocksUninstall(bundleIdentifier: String) -> Bool {
		uninstallingBundleIdentifiers.contains(bundleIdentifier)
			|| retiringBundleIdentifier == bundleIdentifier
			|| installationCards.contains { request in
				request.installRequested && (request.app.identifier == bundleIdentifier
					|| request.signing?.options.appIdentifier == bundleIdentifier)
			}
	}

	func beginUninstall(bundleIdentifier: String) -> Bool {
		guard !AppMaintenanceGuard.isResetting, !OnDevicePairingManager.shared.isActive, !blocksUninstall(bundleIdentifier: bundleIdentifier) else { return false }
		uninstallingBundleIdentifiers.insert(bundleIdentifier)
		return true
	}

	func endUninstall(bundleIdentifier: String) {
		uninstallingBundleIdentifiers.remove(bundleIdentifier)
	}

	func containsInstallation(for app: AppInfoPresentable) -> Bool {
		let key = InstallationRequest.appKey(for: app)
		return currentRequest?.appKey == key || retiringAppKey == key || queuedInstalls.contains { $0.appKey == key }
	}

	// Job ownership also protects files during signing and retirement; only
	// unfinished install requests should make a Library button say Queued.
	func hasPendingInstallation(for app: AppInfoPresentable) -> Bool {
		let key = InstallationRequest.appKey(for: app)
		if queuedInstalls.contains(where: { $0.appKey == key && $0.installRequested }) { return true }
		return currentRequest?.appKey == key && currentRequest?.installRequested == true && !hasCompletedSuccessfully
	}

	func isSigningOrQueuedToSign(_ app: AppInfoPresentable) -> Bool {
		let key = InstallationRequest.appKey(for: app)
		if queuedInstalls.contains(where: { $0.appKey == key && $0.signing != nil }) { return true }
		guard currentRequest?.appKey == key, currentRequest?.signing != nil,
			let status = viewModel?.status else { return false }
		switch status {
		case .broken, .completed: return false
		default: return true
		}
	}

	private var hasCompletedSuccessfully: Bool {
		if case .completed(.success) = viewModel?.status { return true }
		return false
	}
	
	@discardableResult
	func startInstall(app: AppInfoPresentable) -> Bool {
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
			return false
		}
		return _enqueue(request)
	}

	func startSigning(app: AppInfoPresentable, options: Options, icon: UIImage?, certificate: CertificatePair?) -> Bool {
		let request = InstallationRequest(app: AppSnapshot(app),
			method: UserDefaults.standard.integer(forKey: "Aether.installationMethod"),
			serverMethod: UserDefaults.standard.object(forKey: "Aether.serverMethod") as? Int ?? 1,
			signing: SigningInput(options: options, iconData: icon?.pngData(), certificateUUID: certificate?.uuid),
			installRequested: options.post_installAppAfterSigned)
		return _enqueue(request)
	}

	private func _enqueue(_ request: InstallationRequest) -> Bool {
		guard !AppMaintenanceGuard.isResetting else { return false }
		if request.installRequested, OnDevicePairingManager.shared.isActive {
			UIAlertController.showAlertWithOk(title: .localized("Install"),
				message: .localized("Wait for on-device pairing to finish before installing apps."))
			return false
		}
		if request.installRequested,
			[request.app.identifier, request.signing?.options.appIdentifier].compactMap({ $0 })
				.contains(where: { uninstallingBundleIdentifiers.contains($0) }) {
			UIAlertController.showAlertWithOk(title: .localized("Install"),
				message: .localized("Wait for this app to finish uninstalling before installing it."))
			return false
		}
		if request.signing == nil { AppTabManager.shared.showInstallQueue() }
		if currentRequest?.appKey == request.appKey, !hasCompletedSuccessfully {
			if case .broken = viewModel?.status {
				if request.signing != nil {
					queuedInstalls.insert(request, at: 0)
					cancel()
					return true
				}
				retryActiveInstall()
			}
			return false
		}
		guard !queuedInstalls.contains(where: { $0.appKey == request.appKey }) else { return false }

		queuedInstalls.append(request)
		execution?.updateQueue(pendingJobs: installationCards.count - (hasCompletedSuccessfully ? 1 : 0))
		_persistInstallQueue()
		_log("Install queued for \(request.app.name ?? request.app.identifier ?? .localized("app")).", category: "Install", level: .notice)
		if hasCompletedSuccessfully {
			_finishCompletedInstall(generation: installGeneration)
		} else {
			_startNextIfPossible()
		}
		return true
	}

	/// Resolve at activation time: a menu can remain open while a queued job starts.
	func cancelRequest(id: UUID) {
		if currentRequest?.id == id { cancel() }
		else { cancelQueuedInstall(id: id) }
	}

	func cancelQueuedInstall(id: UUID) {
		guard queuedInstalls.contains(where: { $0.id == id }) else {
			_log("Cancel ignored for retired queue request id=\(id).", category: "Signing", level: .debug)
			return
		}
		queuedInstalls.removeAll { $0.id == id }
		_log("Cancelled queued request id=\(id); remaining=\(queuedInstalls.count).", category: "Signing", level: .notice)
		execution?.updateQueue(pendingJobs: installationCards.count - (hasCompletedSuccessfully ? 1 : 0))
		_persistInstallQueue()
		_startNextIfPossible()
	}

	func retryActiveInstall() {
		guard let request = currentRequest, case .broken = viewModel?.status else { return }
		queuedInstalls.insert(request, at: 0)
		cancel()
	}

	private func _startNextIfPossible() {
		guard !queuedInstalls.isEmpty else { return }
		guard currentRequest == nil, retirementTask == nil else {
			_log("Queue waiting current=\(currentRequest?.id.uuidString ?? "none") retiring=\(retirementTask != nil) queued=\(queuedInstalls.count).", category: "Signing", level: .debug)
			return
		}
		guard UIApplication.shared.applicationState == .active || execution?.hasExecution == true else {
			_log("Queue waiting for foreground execution; queued=\(queuedInstalls.count).", category: "Signing", level: .debug)
			return
		}
		if execution == nil || execution?.isFinished == true { execution = AppOperationExecution() }
		let request = queuedInstalls.removeFirst()
		let generation = UUID()
		installGeneration = generation
		let context = InstallationContext(method: request.method, serverMethod: request.serverMethod)
		let statusVM = InstallerStatusViewModel(isIdevice: request.method == 1,
			signsBeforeInstalling: request.signing != nil && request.installRequested)
		viewModel = statusVM
		activeApp = request.app
		currentRequest = request
		_persistInstallQueue()
		lastErrorMessage = nil
		_hasLaunchedSemiLocalInstall = false
		statusVM.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] status in
				guard let self, self.installGeneration == generation else { return }
				self.objectWillChange.send()
				self._handleStatusChange(status, context: context, generation: generation)
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

		if let signing = request.signing {
			statusVM.status = .signing
			let certificate = signing.certificateUUID.flatMap { uuid in Storage.shared.getAllCertificates().first { $0.uuid == uuid } }
			let snapshot = SigningCertificateSnapshot(certificate)
			if signing.certificateUUID != nil, snapshot == nil {
				let error = SigningFileHandlerError.missingCertifcate
				statusVM.status = .broken(error)
				return
			}
			installTask = FR.signPackageFile(request.app, using: signing.options,
				iconData: signing.iconData, certificate: snapshot,
				progress: { [weak self, weak statusVM] progress in
					guard let self, self.installGeneration == generation else { return }
					statusVM?.signingProgress = progress
					self.execution?.updateSigning(progress: progress)
				}) { [weak self, weak statusVM] result in
				guard let self, let statusVM, self.installGeneration == generation else { return }
				self.installTask = nil
				if self.execution?.isInterrupted == true {
					self._interruptInstallation(generation: generation)
					return
				}
				switch result {
				case .failure(let error):
					if case .broken = statusVM.status {} else { statusVM.status = .broken(error) }
				case .success(let uuid):
					guard let signedApp = Storage.shared.signedApp(uuid: uuid) else {
						let error = SigningFileHandlerError.appNotFound
						statusVM.status = .broken(error)
						return
					}
					var signedRequest = request
					signedRequest.app = AppSnapshot(signedApp)
					signedRequest.signing = nil
					self.currentRequest = signedRequest
					self.activeApp = signedRequest.app
					if signing.options.post_installAppAfterSigned {
						self._persistInstallQueue()
						AppTabManager.shared.showInstallQueue()
						statusVM.status = .none
						self._startTransportInstallation(signedRequest, context: context, statusVM: statusVM, generation: generation)
					} else {
						statusVM.status = .completed(.success(()))
						self._persistInstallQueue()
					}
				}
			}
			return
		}
		if request.installRequested {
			_startTransportInstallation(request, context: context, statusVM: statusVM, generation: generation)
		} else { statusVM.status = .completed(.success(())) }
	}

	private func _startTransportInstallation(_ request: InstallationRequest, context: InstallationContext,
		statusVM: InstallerStatusViewModel, generation: UUID) {
		guard request.app.identifier != Bundle.main.bundleIdentifier || request.method == 1 else {
			statusVM.status = .broken(NSError(domain: "Aether.Install", code: 1,
				userInfo: [NSLocalizedDescriptionKey: String.localized("Use another app to update Aether in server mode.")]))
			return
		}
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
			execution?.startServerAudio()
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
				guard await MainActor.run(body: { [weak self] in
					self?.installGeneration == generation && !Task.isCancelled
				}) else {
					handler.clean()
					return
				}
				await MainActor.run { [weak self] in
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
					guard await MainActor.run(body: { [weak self] in
						self?.installGeneration == generation && !Task.isCancelled
					}) else {
						handler.clean()
						return
					}
					await MainActor.run { [weak self] in
						self?.installer = serverInstaller
						serverInstaller.packageUrl = packageUrl
						statusVM.status = .ready
					}
				} else {
					defer { handler.clean() }
					let proxy = InstallationProxy(viewModel: statusVM)
					await MainActor.run { [weak self] in
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
				guard await MainActor.run(body: { [weak self] in
					self?.installGeneration == generation && !Task.isCancelled
				}) else { return }
				
				await MainActor.run { [weak self] in
					self?.progressTask?.cancel()
					self?.archiveHandler = nil
					self?.installer = nil
					#if !targetEnvironment(macCatalyst)
					self?.execution?.stopServerAudio()
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
			execution?.completeJob()
			_persistInstallQueue()
			_log("Queue job completed for \(app.name ?? app.identifier ?? .localized("app")).", category: currentRequest?.installRequested == true ? "Install" : "Signing", level: .notice)
			progressTask?.cancel()
			progressTask = nil
			if currentRequest?.installRequested == true {
                completedArtifacts.insert(InstallationRequest.appKey(for: app))
                UserDefaults.standard.set(Array(completedArtifacts), forKey: "Aether.completedInstallArtifacts")
				if let id = app.identifier { InstallationAppProxy.invalidateAppIcon(for: id) }
				NotificationCenter.default.post(name: Notification.Name("Aether.installedAppsRefresh"), object: nil)
			}
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
			// Retain installation success briefly; signing returns directly to its signed row.
			if self.queuedInstalls.isEmpty && self.currentRequest?.installRequested == true {
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
		if queuedInstalls.isEmpty || execution?.hasExecution != true {
			_endInstallationExecution(success: hasCompletedSuccessfully)
		} else if !hasCompletedSuccessfully { execution?.completeJob() }
		guard currentRequest != nil || activeApp != nil || installTask != nil || iDevicePreflightTask != nil else { return }
		installGeneration = UUID()
		settlementTask?.cancel()
		settlementTask = nil
		let worker = installTask
		let preflight = iDevicePreflightTask
		if worker != nil || preflight != nil {
			retiringAppKey = currentRequest?.appKey
			retiringBundleIdentifier = currentRequest?.app.identifier
		}
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
			self.retiringBundleIdentifier = nil
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
		execution?.stopServerAudio()
		#endif
	}

	private func _startInstallationExecution(_ request: InstallationRequest, generation: UUID) -> Bool {
		execution?.updateQueue(pendingJobs: installationCards.count - (hasCompletedSuccessfully ? 1 : 0))
		let accepted = execution?.beginJob(title: request.app.name ?? .localized("Installing App"),
			signing: request.signing != nil, installsAfterSigning: request.signing?.options.post_installAppAfterSigned ?? true) { [weak self] in
			self?._interruptInstallation(generation: generation)
		} == true
		if !accepted { _log("Queue background execution unavailable.", category: "Background", level: .notice) }
		return accepted || UIApplication.shared.applicationState == .active
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
		if case .signing = model.status { execution?.updateSigning(progress: model.signingProgress); return }
		let progress = model.isCompleted ? 1 : min(0.99, max(0, model.packageProgress) * 0.25
			+ max(0, model.uploadProgress) * 0.45 + max(0, model.installProgress) * 0.30)
		execution?.updateInstallation(subtitle: model.statusLabel, progress: progress)
	}

	private func _endInstallationExecution(success: Bool) {
		execution?.finish(success: success)
		execution = nil
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
		_ = _enqueue(request)
	}
}
#endif

struct InstallationBackgroundError: LocalizedError {
	var errorDescription: String? {
		.localized("iOS interrupted background installation. Open Aether and retry. If the app was already installed, refresh the Device list first.")
	}
}
