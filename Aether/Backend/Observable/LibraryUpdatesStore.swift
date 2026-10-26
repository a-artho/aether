import Combine
import SwiftUI
import UIKit

/// Owns the Library refresh from activation through the final update matches.
/// Views forward events and display its phase; tab appearance never owns work.
@MainActor
final class LibraryUpdatesStore: ObservableObject {
	static let shared = LibraryUpdatesStore()

	enum Phase: Equatable { case idle, connecting, checking }
	private enum Reason: Sendable { case activation, manual, configuration, deviceChanged, inputs }
	@Published private(set) var phase: Phase = .idle
	@Published private(set) var updateContexts: [String: [SourceAppCatalogContext]] = [:]
	@Published private(set) var hasVerifiedUpdates = false
	@Published private(set) var noUpdatesUntil: Date?

	private var sources: [AltSource] = []
	private var installationMode = UserDefaults.standard.integer(forKey: "Aether.installationMethod")
	private var isForeground = false
	private var observations = Set<AnyCancellable>()
	private var refreshTask: Task<Void, Never>?
	private var announcementTask: Task<Void, Never>?
	private var manualRepositories: Task<Void, Never>?
	private var refreshID = UUID()
	private var pendingReason: Reason?
	private var deviceRefreshRequired = false
	private var inputRevision = 0
	private var verificationGeneration = UUID()
	private var lastMatchedInputs: [String]?
	private var checkingStarted: ContinuousClock.Instant?

	init() {
		DeviceConnectionManager.shared.$state.removeDuplicates().dropFirst().sink { [weak self] state in
			MainActor.assumeIsolated {
				guard let self else { return }
				if state != .connected {
					self.invalidateVerification()
					InstalledAppsStore.shared.invalidateConnection()
					if self.phase == .checking { self.cancelRefresh() }
				} else if self.refreshTask == nil {
					self.request(.activation)
				}
			}
		}.store(in: &observations)

		let repositories = SourcesViewModel.shared
		let installed = InstalledAppsStore.shared
		// Observe only inputs and completion boundaries, never progress or tabs.
		let changes: [AnyPublisher<Void, Never>] = [
			repositories.$catalogRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
			repositories.$isFinished.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			repositories.$isRefreshRequested.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			installed.$apps.map { $0.flatMap { [$0.bundleIdentifier, $0.version ?? ""] } }
				.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			installed.$isLoading.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			installed.$hasLoadedApps.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			installed.$errorMessage.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
			IgnoredAppUpdates.shared.$identifiers.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
		]
		Publishers.MergeMany(changes).receive(on: DispatchQueue.main).sink { [weak self] in
			self?.inputsChanged()
		}.store(in: &observations)
	}

	func setSources(_ sources: [AltSource]) {
		self.sources = sources
		inputRevision &+= 1
		verificationGeneration = UUID()
		let keys = Set(sources.map { $0.objectID.uriRepresentation().absoluteString })
			.union([AetherBuiltInRepository.key])
		updateContexts = updateContexts.mapValues { $0.filter { keys.contains($0.sourceObjectURI) } }
		request(.configuration)
	}

	func setInstallationMode(_ mode: Int) {
		guard installationMode != mode else { return }
		installationMode = mode
		cancelRefresh()
		invalidateVerification()
		InstalledAppsStore.shared.invalidateConnection()
		request(.activation)
	}

	func activate() {
		guard !isForeground else { return }
		isForeground = true
		InstalledAppsStore.shared.beginRefreshEpisode()
		request(.activation)
	}

	func didEnterBackground() {
		guard isForeground else { return }
		isForeground = false
		cancelRefresh()
		clearAnnouncement()
		let connection = DeviceConnectionManager.shared
		if installationMode == 1, connection.tunnelMethod == .inApp, connection.isDisconnectWhenIdleEnabled, !connection.hasActiveTunnelDependencies {
			invalidateVerification()
			InstalledAppsStore.shared.invalidateConnection()
		}
	}

	/// Manual pulls always bypass data freshness; repeated pulls join the owner.
	func startRefresh() {
		guard isForeground, manualRepositories == nil else { return }
		InstalledAppsStore.shared.beginRefreshEpisode()
		manualRepositories = SourcesViewModel.shared.startRefresh(sources)
		deviceRefreshRequired = true
		request(.manual)
	}

	/// Installation completion requires a new device snapshot, not a repo fetch.
	func refreshInstalledApps() {
		InstalledAppsStore.shared.beginRefreshEpisode()
		deviceRefreshRequired = true
		request(.deviceChanged)
	}

	private func inputsChanged() {
		inputRevision &+= 1
		verificationGeneration = UUID()
		request(.inputs)
	}

	private func request(_ reason: Reason) {
		guard isForeground else { return }
		if refreshTask != nil {
			// Data changed during a browse, so perform one trailing refresh.
			// Ordinary input publications and repeated pulls join the current work.
			if reason == .manual { pendingReason = .manual }
			else if reason == .configuration, pendingReason != .manual { pendingReason = .configuration }
			else if reason == .deviceChanged, pendingReason == nil { pendingReason = .deviceChanged }
			return
		}
		if reason == .inputs {
			guard installationMode == 1, DeviceConnectionManager.shared.isConnected else { return }
			let repositories = SourcesViewModel.shared
			if repositories.isFinished, !repositories.isRefreshRequested,
				!InstalledAppsStore.shared.isLoading, hasVerifiedUpdates,
				let inputs = matchingInputs(), inputs.complete, lastMatchedInputs == inputs.signature { return }
		}
		let id = UUID()
		refreshID = id
		clearAnnouncement()
		refreshTask = Task { [weak self] in
			guard let self else { return }
			await self.run(reason, id: id)
		}
	}

	private func run(_ initialReason: Reason, id: UUID) async {
		defer {
			if refreshID == id {
				refreshTask = nil
				manualRepositories = nil
				phase = .idle
				checkingStarted = nil
			}
		}
		var reason = initialReason
		while isCurrent(id) {
			pendingReason = nil
			let currentReason = reason
			async let repositories: Void = refreshRepositories(currentReason)
			async let deviceReady: Bool = refreshDevice(currentReason)
			await repositories
			let ready = await deviceReady
			guard isCurrent(id) else { return }
			var matchedRevision: Int?
			if ready {
				// Publications during a scan invalidate its commit and are matched
				// again against the latest inputs, without re-fetching either source.
				repeat {
					let revision = inputRevision
					if let inputs = matchingInputs() {
						await matchUpdates(versions: inputs.versions, contexts: inputs.contexts,
							ignored: inputs.ignored, complete: inputs.complete)
					}
					guard isCurrent(id) else { return }
					if InstalledAppsStore.shared.isLoading || !SourcesViewModel.shared.isFinished || SourcesViewModel.shared.isRefreshRequested {
						if pendingReason == nil { pendingReason = .inputs }
						break
					}
					if revision == inputRevision { matchedRevision = revision; break }
				} while isCurrent(id)
			}
			if let pendingReason { reason = pendingReason; continue }
			if ready, let started = checkingStarted {
				do { try await Task.sleep(until: started.advanced(by: .seconds(1)), clock: .continuous) }
				catch { return }
			}
			guard isCurrent(id) else { return }
			if let pendingReason { reason = pendingReason; continue }
			// A data change during the presentation minimum still needs matching;
			// it must not be lost just because the coordinator already has an owner.
			if ready, matchedRevision != inputRevision { reason = .inputs; continue }
			if ready, let inputs = matchingInputs(), inputs.complete,
				hasVerifiedUpdates, lastMatchedInputs == inputs.signature, InstalledAppsStore.shared.errorMessage == nil,
				!InstalledAppsStore.shared.apps.isEmpty, updateContexts.values.allSatisfy({ $0.isEmpty }) {
				announceNoUpdates()
			}
			return
		}
	}

	private func isCurrent(_ id: UUID) -> Bool {
		!Task.isCancelled && isForeground && refreshID == id
	}

	private func refreshRepositories(_ reason: Reason) async {
		let repositories = SourcesViewModel.shared
		switch reason {
		case .manual: await (manualRepositories ?? repositories.startRefresh(sources)).value
		case .activation, .configuration: await repositories.refreshIfNeeded(sources)
		case .deviceChanged, .inputs: break
		}
		guard !Task.isCancelled else { return }
		await waitForWork(Publishers.Merge(repositories.$isFinished.map { _ in () },
			repositories.$isRefreshRequested.map { _ in () }).eraseToAnyPublisher()) {
			repositories.isFinished && !repositories.isRefreshRequested
		}
	}

	/// Buffer completion publications while the async consumer is resuming.
	/// AsyncPublisher.values can drop a rapid final publication without demand.
	private func waitForWork(_ publisher: AnyPublisher<Void, Never>, until ready: () -> Bool) async {
		let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let observation = publisher.sink { continuation.yield(()) }
		defer { observation.cancel(); continuation.finish() }
		continuation.yield(())
		for await _ in changes {
			if Task.isCancelled || ready() { return }
		}
	}

	private func refreshDevice(_ reason: Reason) async -> Bool {
		guard installationMode == 1 else { return false }
		let connection = DeviceConnectionManager.shared
		let cellular = CellularAssistManager.shared
		// The connection manager owns verification, recovery and handoff waits.
		// Library never treats a previously published Connected value as proof.
		phase = .connecting
		guard await connection.verifyForAppRefresh(), !Task.isCancelled,
			!connection.isUpdating, !cellular.isBusy else { return false }
		let installed = InstalledAppsStore.shared
		if reason == .inputs, !installed.hasLoadedApps, !installed.isLoading { return false }
		if phase != .checking { checkingStarted = .now; phase = .checking }
		if installed.isLoading {
			await waitForWork(installed.$isLoading.map { _ in () }.eraseToAnyPublisher()) { !installed.isLoading }
			if !Task.isCancelled, reason != .inputs, deviceRefreshRequired {
				deviceRefreshRequired = false
				await installed.refresh(force: true)
			}
		} else if reason != .inputs {
			let force = reason == .manual || deviceRefreshRequired
			deviceRefreshRequired = false
			if force { await installed.refresh(force: true) }
			else { await installed.refreshOnForeground() }
		}
		return !Task.isCancelled && connection.isConnected && installed.hasLoadedApps
	}

	@MainActor private struct MatchingInputs {
		let versions: [String: String]
		let contexts: [SourceAppCatalogContext]
		let ignored: Set<String>
		let complete: Bool
		var signature: [String] { LibraryUpdatesStore.signature(versions: versions, contexts: contexts, ignored: ignored) }
	}

	private func matchingInputs() -> MatchingInputs? {
		let installed = InstalledAppsStore.shared
		let repositories = SourcesViewModel.shared
		guard installationMode == 1, DeviceConnectionManager.shared.isConnected,
			installed.hasLoadedApps, !installed.isLoading, repositories.isFinished, !repositories.isRefreshRequested else { return nil }
		let userContexts = sources.compactMap { source -> SourceAppCatalogContext? in
			guard let repository = repositories.repository(for: source) else { return nil }
			return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
				sourceURL: source.sourceURL, repository: repository, revision: repositories.revision(for: source))
		}
		var contexts = userContexts
		if let aetherContext = repositories.builtInAetherUpdateContext(
			installedBundleIdentifier: Bundle.main.bundleIdentifier
		) {
			contexts.append(aetherContext)
		}
		let versions = installed.apps.reduce(into: [String: String]()) { values, app in
			if let version = app.version { values[app.bundleIdentifier] = version }
		}
		return MatchingInputs(versions: versions, contexts: contexts, ignored: IgnoredAppUpdates.shared.identifiers,
			complete: repositories.refreshErrors.isEmpty && userContexts.count == sources.count && installed.errorMessage == nil)
	}

	private static func signature(versions: [String: String], contexts: [SourceAppCatalogContext], ignored: Set<String>) -> [String] {
		versions.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
			+ contexts.sorted { $0.sourceObjectURI < $1.sourceObjectURI }.flatMap {
				[$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision]
			} + ignored.sorted()
	}

	private func matchUpdates(versions: [String: String], contexts: [SourceAppCatalogContext], ignored: Set<String>, complete: Bool) async {
		guard !Task.isCancelled else { return }
		let inputs = Self.signature(versions: versions, contexts: contexts, ignored: ignored)
		if complete, lastMatchedInputs == inputs { hasVerifiedUpdates = true; return }
		let generation = verificationGeneration
		do {
			let matches = try await InstalledAppUpdateCatalog.shared.updates(
				installedVersions: versions, contexts: contexts, ignoredIdentifiers: ignored)
			try Task.checkCancellation()
			guard generation == verificationGeneration,
				let latest = matchingInputs(), latest.signature == inputs,
				!complete || latest.complete else { return }
			if complete {
				updateContexts = matches
				lastMatchedInputs = inputs
				hasVerifiedUpdates = true
			} else {
				lastMatchedInputs = nil
				updateContexts.merge(matches) { previous, fresh in fresh.isEmpty ? previous : fresh }
			}
		} catch is CancellationError {} catch {
			guard generation == verificationGeneration, !Task.isCancelled else { return }
			DebugLogManager.shared.log("Update check failed: \(error.localizedDescription)", category: "Library", level: .error)
		}
	}

	private func invalidateVerification() {
		verificationGeneration = UUID()
		inputRevision &+= 1
		var transaction = Transaction(animation: nil)
		transaction.disablesAnimations = true
		withTransaction(transaction) { hasVerifiedUpdates = false; clearAnnouncement() }
	}

	private func cancelRefresh() {
		refreshID = UUID()
		refreshTask?.cancel()
		refreshTask = nil
		manualRepositories = nil
		pendingReason = nil
		checkingStarted = nil
		phase = .idle
	}

	private func clearAnnouncement() {
		announcementTask?.cancel()
		announcementTask = nil
		noUpdatesUntil = nil
	}

	private func announceNoUpdates() {
		clearAnnouncement()
		let deadline = Date().addingTimeInterval(3)
		noUpdatesUntil = deadline
		announcementTask = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(3)) } catch { return }
			guard !Task.isCancelled, self?.noUpdatesUntil == deadline else { return }
			self?.noUpdatesUntil = nil
			self?.announcementTask = nil
		}
	}
}

/// The app shell forwards lifecycle and configuration only. All refresh work and
/// subscriptions remain with the coordinator, regardless of the selected tab.
@MainActor
struct LibraryLifecycleModifier: ViewModifier {
	@Environment(\.scenePhase) private var scenePhase
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@ObservedObject private var updates = LibraryUpdatesStore.shared

	func body(content: Content) -> some View {
		content
			.onChange(of: sourceIdentities, initial: true) { _, _ in updates.setSources(Array(sources)) }
			.onChange(of: installationMethod, initial: true) { _, mode in updates.setInstallationMode(mode) }
			.onChange(of: scenePhase, initial: true) { _, phase in
				if phase == .active {
					DeviceConnectionManager.shared.handleInitialActivationIfNeeded()
					updates.activate()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				if UIApplication.shared.applicationState == .background { updates.didEnterBackground() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.installedAppsRefresh"))) { _ in
				updates.refreshInstalledApps()
			}
	}

	private var sourceIdentities: [String] {
		sources.flatMap { [$0.objectID.uriRepresentation().absoluteString, $0.sourceURL?.absoluteString ?? ""] }
	}
}
