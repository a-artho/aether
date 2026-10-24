import Combine
import SwiftUI
import UIKit

/// App-owned update results. A tab's appearance never starts or cancels this work.
@MainActor
final class LibraryUpdatesStore: ObservableObject {
	static let shared = LibraryUpdatesStore()
	@Published private(set) var updateContexts: [String: [SourceAppCatalogContext]] = [:]
	@Published private(set) var hasVerifiedUpdates = false
	@Published private(set) var isMatching = false
	@Published private(set) var awaitingMatch = true
	@Published private(set) var refreshInProgress = false
	@Published private(set) var showsAppRefresh = false
	@Published private(set) var noUpdatesUntil: Date?
	@Published private(set) var deviceRevision = 0
	private var connectionObservation: AnyCancellable?
	private var sources: [AltSource] = []
	private var refreshTask: Task<Void, Never>?
	private var verificationGeneration = UUID()
	private var checkID: UUID?
	private var lastMatchedInputs: [String]?
	private var updateIndicatorStarted: ContinuousClock.Instant?

	init() {
		// Connection changes must invalidate synchronously even while SwiftUI is
		// suspended, including an idle stop after a background install finishes.
		connectionObservation = DeviceConnectionManager.shared.$state.dropFirst().sink { [weak self] state in
			MainActor.assumeIsolated {
				guard state != .connected else { return }
				self?.invalidateVerification()
				InstalledAppsStore.shared.invalidateConnection()
			}
		}
	}

	func setSources(_ sources: [AltSource]) {
		self.sources = sources
		// A result computed against a removed/replaced source cannot commit later.
		verificationGeneration = UUID()
		checkID = nil
		isMatching = false
		awaitingMatch = true
		let keys = Set(sources.map { $0.objectID.uriRepresentation().absoluteString })
		updateContexts = updateContexts.mapValues { $0.filter { keys.contains($0.sourceObjectURI) } }
	}

	/// Keep the cache for reuse, but never present it as verified after disconnecting.
	/// Disable animations before suspension so no removal animation resumes onscreen.
	func invalidateVerification() {
		verificationGeneration = UUID()
		checkID = nil
		var transaction = Transaction(animation: nil)
		transaction.disablesAnimations = true
		withTransaction(transaction) {
			deviceRevision &+= 1
			hasVerifiedUpdates = false
			awaitingMatch = true
			isMatching = false
			showsAppRefresh = false
			updateIndicatorStarted = nil
			noUpdatesUntil = nil
		}
	}

	func matchUpdates(versions: [String: String], contexts: [SourceAppCatalogContext], ignored: Set<String>, complete: Bool) async {
		guard !Task.isCancelled else { return }
		let inputs = versions.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
			+ contexts.sorted { $0.sourceObjectURI < $1.sourceObjectURI }.flatMap {
				[$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision]
			}
			+ ignored.sorted()
		// Fresh device/catalog inputs can validate the retained result without
		// scanning catalogs again. View appearance is never part of the signature.
		if complete, lastMatchedInputs == inputs {
			let revalidating = !hasVerifiedUpdates || awaitingMatch
			awaitingMatch = false
			hasVerifiedUpdates = true
			if revalidating, !versions.isEmpty, updateContexts.values.allSatisfy({ $0.isEmpty }) {
				noUpdatesUntil = Date().addingTimeInterval(2)
			}
			return
		}
		let generation = verificationGeneration
		let id = UUID()
		checkID = id
		isMatching = true
		noUpdatesUntil = nil
		defer {
			if checkID == id { checkID = nil; isMatching = false }
		}
		do {
			let matches = try await InstalledAppUpdateCatalog.shared.updates(
				installedVersions: versions, contexts: contexts, ignoredIdentifiers: ignored)
			try Task.checkCancellation()
			guard generation == verificationGeneration, checkID == id else { return }
			awaitingMatch = false
			publishUpdateMatches(matches, complete: complete)
			if complete {
				lastMatchedInputs = inputs
				hasVerifiedUpdates = true
				if !versions.isEmpty, matches.values.allSatisfy({ $0.isEmpty }) {
					noUpdatesUntil = Date().addingTimeInterval(2)
				}
			}
		} catch is CancellationError {} catch {
			guard generation == verificationGeneration, checkID == id, !Task.isCancelled else { return }
			awaitingMatch = false
			DebugLogManager.shared.log("Update check failed: \(error.localizedDescription)", category: "Library", level: .error)
		}
	}

	private func publishUpdateMatches(_ matches: [String: [SourceAppCatalogContext]], complete: Bool) {
		if complete {
			updateContexts = matches
		} else {
			lastMatchedInputs = nil
			updateContexts.merge(matches) { previous, fresh in fresh.isEmpty ? previous : fresh }
		}
	}

	/// Pull-to-refresh hands ownership here before the native pull control returns.
	func startRefresh() {
		guard refreshTask == nil else { return }
		refreshInProgress = true
		awaitingMatch = true
		noUpdatesUntil = nil
		let repositories = SourcesViewModel.shared.startRefresh(sources)
		refreshTask = Task { @MainActor in
			defer { refreshTask = nil; refreshInProgress = false }
			async let installed: Void = InstalledAppsStore.shared.refresh(force: true)
			await repositories.value
			await installed
		}
	}

	func updateRefreshIndicator(checking: Bool, higherPriority: Bool) async {
		guard !higherPriority else {
			showsAppRefresh = false
			updateIndicatorStarted = nil
			return
		}
		if checking {
			if !showsAppRefresh { updateIndicatorStarted = .now }
			showsAppRefresh = true
		} else if showsAppRefresh {
			let elapsed = updateIndicatorStarted?.duration(to: .now) ?? .seconds(0.5)
			do { try await Task.sleep(for: max(.zero, .seconds(0.5) - elapsed)) } catch { return }
			guard !Task.isCancelled else { return }
			showsAppRefresh = false
			updateIndicatorStarted = nil
		}
	}

	func expireNoUpdatesMessage() async {
		guard let deadline = noUpdatesUntil else { return }
		do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
		guard !Task.isCancelled, noUpdatesUntil == deadline else { return }
		noUpdatesUntil = nil
	}
}

/// Mounted above TabView so launch/foreground work also runs from Sources or Settings.
@MainActor
struct LibraryLifecycleModifier: ViewModifier {
	@Environment(\.scenePhase) private var scenePhase
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@ObservedObject private var updates = LibraryUpdatesStore.shared
	@ObservedObject private var installed = InstalledAppsStore.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var repositories = SourcesViewModel.shared
	@ObservedObject private var ignored = IgnoredAppUpdates.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared

	func body(content: Content) -> some View {
		content
			.onChange(of: sourceIdentities, initial: true) { _, _ in updates.setSources(Array(sources)) }
			.onChange(of: installationMethod) { _, mode in
				if mode != 1 { invalidateDeviceSnapshot() }
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				guard UIApplication.shared.applicationState == .background,
					installationMethod == 1, connection.isDisconnectWhenIdleEnabled,
					!connection.hasActiveTunnelDependencies else { return }
				// Happens before the next foreground frame, even if the VPN's
				// asynchronous stop has not published Disconnected yet.
				invalidateDeviceSnapshot()
			}
			.task(id: scenePhase) {
				if scenePhase == .active { connection.connectAutomaticallyIfNeeded() }
			}
			.task(id: repositoryRequest) {
				guard scenePhase == .active else { return }
				await repositories.refreshIfNeeded(Array(sources))
			}
			.task(id: deviceRequest) {
				guard scenePhase == .active, installationMethod == 1, connection.isConnected,
					!connection.isUpdating, !connection.isAwaitingAutomaticConnection else { return }
				await installed.refreshOnForeground()
			}
			.task(id: matchingRequest) {
				guard scenePhase == .active, installationMethod == 1, connection.isConnected,
					!connection.isUpdating, !connection.isAwaitingAutomaticConnection,
					installed.hasLoadedApps, !installed.isLoading, !updates.refreshInProgress,
					repositories.isFinished, !repositories.isRefreshRequested else { return }
				let contexts = sources.compactMap { source -> SourceAppCatalogContext? in
					guard let repository = repositories.repository(for: source) else { return nil }
					return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
						sourceURL: source.sourceURL, repository: repository, revision: repositories.revision(for: source))
				}
				let versions = installed.apps.reduce(into: [String: String]()) { values, app in
					if let version = app.version { values[app.bundleIdentifier] = version }
				}
				await updates.matchUpdates(versions: versions, contexts: contexts, ignored: ignored.identifiers,
					complete: repositories.refreshErrors.isEmpty && contexts.count == sources.count && installed.errorMessage == nil)
			}
			.task(id: indicatorRequest) {
				let request = indicatorRequest
				await updates.updateRefreshIndicator(checking: request[0], higherPriority: request[1])
			}
			.task(id: updates.noUpdatesUntil) { await updates.expireNoUpdatesMessage() }
	}

	private func invalidateDeviceSnapshot() {
		updates.invalidateVerification()
		installed.invalidateConnection()
	}

	private var sourceIdentities: [String] {
		sources.flatMap { [$0.objectID.uriRepresentation().absoluteString, $0.sourceURL?.absoluteString ?? ""] }
	}
	private var repositoryRequest: [String] { [String(scenePhase == .active)] + sourceIdentities }
	private var deviceRequest: [String] {
		[String(scenePhase == .active), String(installationMethod), String(connection.isConnected),
			String(connection.isUpdating), String(connection.isAwaitingAutomaticConnection), String(updates.deviceRevision)]
	}
	private var matchingRequest: [String] {
		deviceRequest + [String(installed.isLoading), String(installed.hasLoadedApps), installed.errorMessage ?? "",
			String(repositories.catalogRevision), String(repositories.isFinished), String(repositories.isRefreshRequested),
			String(updates.refreshInProgress)] + ignored.identifiers.sorted()
			+ installed.apps.flatMap { [$0.bundleIdentifier, $0.version ?? ""] } + sourceIdentities
	}
	private var indicatorRequest: [Bool] {
		[installed.isLoading || !installed.hasLoadedApps || updates.awaitingMatch || updates.isMatching
		 || updates.refreshInProgress || repositories.isRefreshRequested || !repositories.isFinished,
		 scenePhase != .active || installationMethod != 1 || !connection.isConnected || connection.isUpdating
		 || connection.isAwaitingAutomaticConnection || cellularAssist.isBusy || installed.errorMessage != nil]
	}
}
