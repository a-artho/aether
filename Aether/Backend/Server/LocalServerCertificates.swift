import Foundation
import Security
import CryptoKit
import AetherServerCrypto
import OSLog

struct LocalServerTLSMaterial: Sendable {
    let certificateDER: Data
    let privateKeyPEM: Data
}

enum LocalServerSetupState: Equatable, Sendable {
    case checking, setupRequired, trustRequired, ready
}

/// Serializes setup/renewal, stores one atomic credential set, and never caches private keys.
final class LocalServerCertificates: @unchecked Sendable {
    static let shared = LocalServerCertificates()
    static let hostname = "127.0.0.1"
    private let lock = NSLock()
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("identity.plist") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AetherLocalServer", isDirectory: true)) {
        self.directory = directory
    }

    private struct Identity: Codable {
        let rootDER: Data
        let rootKeyPEM: Data
        var serverDER: Data
        var serverKeyPEM: Data
    }

    enum Failure: LocalizedError {
        case setupRequired, trustRequired, generationFailed
        var errorDescription: String? {
            switch self {
            case .setupRequired: return .localized("Set up the local server certificate in Settings → Installation → Server before using Fully Local installation.")
            case .trustRequired: return .localized("Install Aether’s local CA and enable full trust in iOS Settings before using Fully Local installation.")
            case .generationFailed: return .localized("Could not generate the local server certificate. Please try again.")
            }
        }
    }

    func state() -> LocalServerSetupState {
        lock.lock(); defer { lock.unlock() }
        do {
            let identity = try validIdentity()
            return isSystemTrusted(identity) ? .ready : .trustRequired
        } catch {
            Logger.misc.debug("Local server setup is unavailable: \(error.localizedDescription, privacy: .public)")
            return .setupRequired
        }
    }

    /// Must be called on a worker before packaging; trusting our own anchor here would give a false Ready.
    func prepareTLS() throws -> LocalServerTLSMaterial {
        lock.lock(); defer { lock.unlock() }
        let identity = try validIdentity()
        guard isSystemTrusted(identity) else { throw Failure.trustRequired }
        return .init(certificateDER: identity.serverDER, privateKeyPEM: identity.serverKeyPEM)
    }

    /// Only explicit setup may replace a missing/invalid/expiring root; leaf renewal keeps the trusted root.
    func setupProfile() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var identity: Identity
        if let existing = try? load(), rootIsValid(existing) {
            identity = try renewingServerIfNeeded(existing)
        } else {
            guard let root = aether_create_local_certificate(nil, nil),
                let rootDER = root["certificateDER"], let rootKey = root["privateKeyPEM"],
                let server = aether_create_local_certificate(rootDER, rootKey),
                let serverDER = server["certificateDER"], let serverKey = server["privateKeyPEM"] else {
                throw Failure.generationFailed
            }
            identity = Identity(rootDER: rootDER, rootKeyPEM: rootKey, serverDER: serverDER, serverKeyPEM: serverKey)
            try save(identity)
        }
        let fingerprint = SHA256.hash(data: identity.rootDER).map { String(format: "%02x", $0) }.joined()
        let identifier = "com.aether.localserver." + fingerprint
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": identifier, "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Aether Local Server", "PayloadOrganization": "Aether",
            "PayloadDescription": String.localized("Enables HTTPS for Aether’s Fully Local installer on this device."),
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": identifier + ".ca", "PayloadUUID": UUID().uuidString,
                "PayloadDisplayName": "Aether Local Server CA", "PayloadContent": identity.rootDER
            ]]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Deletes only Aether's generated CA, private keys, and HTTPS certificate.
    /// iOS-installed configuration profiles must be removed manually in Settings.
    func reset() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        Logger.misc.info("Local server CA and HTTPS credentials reset.")
    }

    private func load() throws -> Identity {
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.setupRequired }
        return try PropertyListDecoder().decode(Identity.self, from: Data(contentsOf: file))
    }

    private func save(_ identity: Identity) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var resourceDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceDirectory.setResourceValues(values)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try PropertyListEncoder().encode(identity).write(to: file, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func rootIsValid(_ identity: Identity) -> Bool {
        aether_validate_local_certificate(identity.rootDER, identity.rootKeyPEM, nil, true, 30 * 86400)
    }

    private func validIdentity() throws -> Identity {
        guard let identity = try? load(), rootIsValid(identity) else { throw Failure.setupRequired }
        return try renewingServerIfNeeded(identity)
    }

    private func renewingServerIfNeeded(_ identity: Identity) throws -> Identity {
        if aether_validate_local_certificate(identity.serverDER, identity.serverKeyPEM, identity.rootDER, false, 14 * 86400) {
            return identity
        }
        guard let server = aether_create_local_certificate(identity.rootDER, identity.rootKeyPEM),
            let der = server["certificateDER"], let key = server["privateKeyPEM"] else { throw Failure.generationFailed }
        var renewed = identity; renewed.serverDER = der; renewed.serverKeyPEM = key
        try save(renewed)
        return renewed
    }

    private func isSystemTrusted(_ identity: Identity) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, identity.serverDER as CFData),
            let root = SecCertificateCreateWithData(nil, identity.rootDER as CFData) else { return false }
        let policy = SecPolicyCreateSSL(true, Self.hostname as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, policy, &trust) == errSecSuccess,
            let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        // No SecTrustSetAnchorCertificates: only iOS system/user trust is accepted.
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        if !trusted {
            Logger.misc.debug("Local server certificate is not system-trusted: \(String(describing: error), privacy: .public)")
        }
        return trusted
    }
}
