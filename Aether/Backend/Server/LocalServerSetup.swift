import Foundation
import SwiftUI
import UIKit
import Vapor
import OSLog

/// Publishes readiness only on demand; no idle/background polling or persistent setup server.
@MainActor
final class LocalServerSetup: ObservableObject {
    static let shared = LocalServerSetup()
    @Published private(set) var state: LocalServerSetupState = .checking
    @Published private(set) var isSettingUp = false
    @Published var error: String?
    private var refreshGeneration = UUID()
    private var setupServer: Application?
    private var setupGeneration: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func refresh() async {
        guard !isSettingUp else { return }
        let generation = UUID(); refreshGeneration = generation
        let result = await Task.detached(priority: .utility) { LocalServerCertificates.shared.state() }.value
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        state = result
    }

    func setUp() async {
        guard !isSettingUp, !AppInstallationManager.shared.hasPendingInstalls else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        error = nil
        isSettingUp = true; refreshGeneration = UUID()
        defer { isSettingUp = false }
        do {
            let (profile, readiness) = try await Task.detached(priority: .userInitiated) {
                let store = LocalServerCertificates.shared
                let profile = try store.setupProfile()
                return (profile, store.state())
            }.value
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active else {
                throw CocoaError(.userCancelled)
            }
            await stopSetupServer()
            let server = Application(ServerInstaller.env)
            // Assign before configuration/start so partial failure is always shut down.
            setupServer = server
            server.threadPool = .init(numberOfThreads: 1)
            server.http.server.configuration.address = .hostname("127.0.0.1", port: 0)
            server.http.server.configuration.shutdownTimeout = .seconds(1)
            server.get("aether-local-server.mobileconfig") { _ in
                Logger.misc.info("Local server CA profile requested by browser.")
                return Response(status: .ok, headers: ["Content-Type": "application/x-apple-aspen-config",
                    "Cache-Control": "no-store",
                    "Content-Disposition": "attachment; filename=\"Aether-Local-Server.mobileconfig\""], body: .init(data: profile))
            }
            try server.server.start()
            guard let port = server.http.server.shared.localAddress?.port,
                let url = URL(string: "http://127.0.0.1:\(port)/aether-local-server.mobileconfig") else {
                throw LocalServerCertificates.Failure.generationFailed
            }
            // Redownloading an already trusted profile must not report it as untrusted.
            state = readiness
            let generation = UUID(); setupGeneration = generation
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Aether CA handoff") { [weak self] in
                Task { @MainActor in
                    guard self?.setupGeneration == generation else { return }
                    await self?.stopSetupServer()
                }
            }
            cleanupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.stopSetupServer()
            }
            let opened = await withCheckedContinuation { continuation in
                UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
            }
            guard opened else { throw CocoaError(.featureUnsupported) }
            Logger.misc.info("Local server CA profile handed off to the browser.")
        } catch {
            await stopSetupServer()
            self.error = error.localizedDescription
            Logger.misc.error("Local server CA setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func reset() async -> Bool {
        guard !isSettingUp, !AppInstallationManager.shared.hasPendingInstalls else { return false }
        isSettingUp = true; refreshGeneration = UUID()
        defer { isSettingUp = false }
        await stopSetupServer()
        do {
            try await Task.detached(priority: .utility) {
                try LocalServerCertificates.shared.reset()
            }.value
            error = nil
            state = .setupRequired
            return true
        } catch {
            self.error = error.localizedDescription
            Logger.misc.error("Local server CA reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func stopSetupServer() async {
        cleanupTask?.cancel(); cleanupTask = nil
        setupGeneration = nil
        let token = backgroundTask; backgroundTask = .invalid
        if let server = setupServer {
            setupServer = nil
            await Task.detached(priority: .utility) {
                server.server.shutdown()
                server.shutdown()
            }.value
        }
        if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
    }
}
