"""Exercise cellular deadlines, native cancellation, and Library failure priority."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
device = (root / 'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
embedded = (root / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
library = (root / 'Aether/Views/Library/LibraryView.swift').read_text()
pairing = (root / 'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/PairingVerification.swift').read_text()
native = (root / 'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat+start.swift').read_text()

def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('public ', '').replace('private ', '')

helper = embedded[embedded.index('private final class TunnelOperationReply'):embedded.index('#if os(iOS)')]
# Keep the same deadline and retry semantics at a shorter fixture timescale.
verify = declaration(device, 'public func verifyCellularTransport()')
verify = verify.replace('CACurrentMediaTime() + 4', 'CACurrentMediaTime() + 0.12').replace('min(0.2,', 'min(0.01,')
source = r'''
import Foundation
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
extension String { static func localized(_ text: String) -> String { text } }
enum DeviceTunnelMethod { case inApp, localDevVPN }
enum PhysicalNetworkState { case unknown, wifiOrWired, cellularOnly, offline }
struct AppInfo: Sendable {}
struct PairingRecordIdentity: Equatable { let id = UUID() }
DIAGNOSTIC
CHECK
HELPER
@MainActor final class EmbeddedTunnelManager {
 static let shared = EmbeddedTunnelManager(); var isConnected = true
}
@MainActor final class CellularAssistManager {
 static let shared = CellularAssistManager()
 enum State: Equatable { case idle, establishingTransport, waitingForManualRecovery, failed(String) }
 var state = State.establishingTransport
 var isBusy: Bool { state == .establishingTransport }
 var isWaitingForManualRecovery: Bool { state == .waitingForManualRecovery }
}
final class HeartbeatManager: @unchecked Sendable {
 static let shared = HeartbeatManager()
 private let condition = NSCondition()
 private var held = false; private var replies: [DeviceConnectionCheck] = []
 private var callCount = 0; private var browsed = false
 func configure(_ replies: [DeviceConnectionCheck], hold: Bool = false) {
  condition.lock(); defer { condition.unlock() }
  precondition(!held); self.replies = replies; held = hold; callCount = 0; browsed = false
 }
 func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
 var calls: Int { condition.lock(); defer { condition.unlock() }; return callCount }
 var requestedApps: Bool { condition.lock(); defer { condition.unlock() }; return browsed }
 func checkDeviceConnection(timeoutInSeconds: Double, includeApps: Bool = false) -> DeviceConnectionCheck {
  condition.lock(); defer { condition.unlock() }
  callCount += 1; browsed = browsed || includeApps
  let reply = replies.isEmpty ? DeviceConnectionCheck(isConnected: false, errorCode: 1) : replies.removeFirst()
  while held { condition.wait() }
  return reply // Deliberately allows a late native result after caller cancellation.
 }
}
struct VerificationState {
 mutating func beginChecking(_ record: PairingRecordIdentity) {}
 mutating func finishChecking(_ record: PairingRecordIdentity, succeeded: Bool) {}
}
@MainActor final class Driver {
 enum State { case disconnected, connected }
 enum Level { case notice }
 var isIDeviceInstallationMode = true; var tunnelMethod = DeviceTunnelMethod.inApp
 var hasPairingFile = true; var providerAvailable = true
 var networkGeneration=UUID();var connectionEpoch: UInt64 = 0; var activeVerificationID: UUID?
 var record: PairingRecordIdentity? = PairingRecordIdentity()
 var pairingVerification = VerificationState(); var lastVerifiedAt = 0.0
 var lastVerifiedRecord: PairingRecordIdentity?; var automaticRetryBlocked = false
 var state = State.disconnected; var diagnostic = DeviceDiagnosticStatus.tunnelUnavailable
 var retired = 0; var discarded = 0
 var isConnected: Bool { state == .connected }
 func _syncPairingRecord() -> PairingRecordIdentity? { record }
 func _providerIsAvailable() -> Bool { providerAvailable }
 func _recordStillMatches(_ checked: PairingRecordIdentity?) -> Bool { checked == record }
 func _cancelReconciliation() {}
 func _finishTransition(to state: State, diagnostic: DeviceDiagnosticStatus) {
  self.state = state; self.diagnostic = diagnostic; activeVerificationID = nil
 }
 func _expireConnectionAttempt() {
  retired += 1; connectionEpoch += 1; automaticRetryBlocked = true
  _finishTransition(to: .disconnected, diagnostic: .error("Timed out"))
 }
 func _discardRejectedRecord(_ result: DeviceConnectionCheck, record: PairingRecordIdentity?) async -> Bool {
  discarded += 1; hasPairingFile = false
  _finishTransition(to: .disconnected, diagnostic: .pairingMissing); return true
 }
 func _log(_ text: String, category: String, level: Level) {}
VERIFY
}
struct UIConnection { var isAwaitingAutomaticConnection = false;
 var hasPairingFile = true; var requiresInAppTunnelSetup = false; var isConnected = false
 var diagnostic = DeviceDiagnosticStatus.tunnelUnavailable
 var tunnelMethod = DeviceTunnelMethod.inApp; var physicalNetworkState = PhysicalNetworkState.cellularOnly
 var needsLocalDevVPNCellularRecovery = false
}
struct UIStore { var apps: [Int] = [] }
struct UIUpdates { enum Phase { case idle, connecting }; var phase = Phase.idle }
@MainActor struct UIProbe {
 var connection = UIConnection(); var store = UIStore(); var updates = UIUpdates()
 let cellularAssist = CellularAssistManager.shared
 var installationMethod = 1; var isConnectingTunnel = false; var isLoadingInstalledApps = false
STATUS_TYPE
FAILURE_STATUS
STATUS
PLACEHOLDER
GUIDANCE
MANUAL
}
struct IdeviceFfiError {}
typealias AdapterHandle = Int
typealias RsdHandshakeHandle = Int
struct IDeviceSwiftError: Error { init(_ pointer: UnsafeMutablePointer<IdeviceFfiError>) {} }
enum IDeviceConnectionError: Error { case rsdTunnelUnavailable(String) }
final class NativeCancellation: @unchecked Sendable {
 let rsdConnectionLock = NSLock(); var rsdAdapter: Int? = 1; var rsdHandshake: Int? = 2
 var ensured = 0
 func didEnter(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now()) == .success }
 func hold() { rsdConnectionLock.lock() }; func release() { rsdConnectionLock.unlock() }
 func _ensureRSDTunnelLocked(discoveryTimeout: TimeInterval?,shouldProceed:(()->Bool)?=nil) throws { ensured += 1 }
 static func shouldRetryRSDService(_ error: IDeviceSwiftError) -> Bool { false }
 func _invalidateRSDTunnelLocked() {}
 func invoke() throws { try connectRSDServiceOnce(discoveryTimeout: 1) { _, _ in nil } }
NATIVE
}
@main struct Checks {
 @MainActor static func drain() async { for _ in 0..<100 { await Task.yield() } }
 @MainActor static func main() async throws {
  let native = HeartbeatManager.shared
  native.configure([.init(isConnected: false, errorCode: 1), .init(isConnected: true)])
  let settling = Driver(); let began = CACurrentMediaTime()
  let settled = await settling.verifyCellularTransport()
  precondition(settled && settling.isConnected && native.calls == 2,
   "Transient route settlement retries within one verification budget")
  precondition(!native.requestedApps && CACurrentMediaTime() - began < 0.12,
   "Authentication restores data promptly without waiting for app browsing")

  native.configure([.init(isConnected: true), .init(isConnected: true)], hold: true)
  let rerouted = Driver(); let rerouting = Task { await rerouted.verifyCellularTransport() }
  while native.calls == 0 { await Task.yield() }
  rerouted.networkGeneration = UUID()
  native.release()
  let currentRoute = await rerouting.value
  precondition(currentRoute && native.calls == 2,
   "A route change retires the old probe while preserving recovery ownership and its deadline")

  native.configure([.init(isConnected: true)], hold: true)
  let timeout = Driver(); let timeoutBegan = CACurrentMediaTime()
  let timedOut = await timeout.verifyCellularTransport()
  precondition(!timedOut && timeout.retired == 1 && CACurrentMediaTime() - timeoutBegan < 0.6,
   "A blocked native call cannot hold Mobile Data off past the outer deadline")
  native.release(); try await Task.sleep(for: .milliseconds(20))
  precondition(!timeout.isConnected, "Late authentication cannot overwrite a timed-out operation")

  native.configure([.init(isConnected: true)], hold: true)
  let cancelled = Driver(); let old = Task { await cancelled.verifyCellularTransport() }
  while native.calls == 0 { await Task.yield() }
  old.cancel(); let cancellationResult = await old.value
  precondition(!cancellationResult && cancelled.retired == 0, "Cancellation returns without retiring a replacement attempt")
  native.release(); try await Task.sleep(for: .milliseconds(20))
  precondition(!cancelled.isConnected)

  native.configure([.init(isConnected: false, errorCode: 18)])
  let rejected = Driver(); let rejectionResult = await rejected.verifyCellularTransport()
  precondition(!rejectionResult && rejected.discarded == 1 && native.calls == 1,
   "Pairing rejection is terminal and does not retry")
  native.configure([.init(isConnected: false, error: "Unreadable pairing file")])
  let malformed = Driver(); let malformedResult = await malformed.verifyCellularTransport()
  precondition(!malformedResult && native.calls == 1 && malformed.automaticRetryBlocked,
   "Unclassified or permanent failures do not become a transient retry loop")

  let stale = NativeCancellation(); stale.hold(); let entered = DispatchSemaphore(value: 0)
  let pending = Task.detached { entered.signal(); try stale.invoke() }
  while !stale.didEnter(entered) { await Task.yield() }
  pending.cancel(); stale.release()
  do { try await pending.value; preconditionFailure("Expected cancellation after native lock wait") }
  catch is CancellationError {} catch { preconditionFailure("Wrong native cancellation error") }
  precondition(stale.ensured == 0, "Cancelled native work cannot recreate RSD after acquiring its lock")
  try stale.invoke(); precondition(stale.ensured == 1)

  CellularAssistManager.shared.state = .idle
  var ui = UIProbe(); ui.connection.tunnelMethod = .localDevVPN
  ui.connection.needsLocalDevVPNCellularRecovery = true
  precondition(ui.deviceStatus.busy == false && ui.deviceStatus.action == .reconnect,
   "Manual cellular guidance is actionable rather than an indefinite spinner")
  ui.connection.diagnostic = .providerMissing(.localDevVPN); ui.updates.phase = .connecting
  precondition(ui.showsDevicePlaceholder && ui.deviceStatus.title == "LocalDevVPN Missing",
   "Known missing provider overrides stale cellular guidance and refresh progress")
  ui.connection.hasPairingFile = false
  precondition(ui.deviceStatus.title == "Pairing File Missing", "Pairing prerequisite remains first")
  ui.connection.hasPairingFile = true; ui.connection.requiresInAppTunnelSetup = true
  precondition(ui.deviceStatus.title == "VPN Setup Required")
  ui.connection.requiresInAppTunnelSetup = false; ui.connection.tunnelMethod = .inApp
  ui.connection.diagnostic = .tunnelUnavailable; ui.isConnectingTunnel = true
  precondition(!ui.showsDevicePlaceholder, "Cold launch pending state creates no unavailable placeholder")
  ui.connection.diagnostic = .error("A specific failure")
  precondition(ui.showsDevicePlaceholder && ui.deviceStatus.description == "A specific failure",
   "Known errors take priority over unrelated pending UI state")
  print("Cellular verification checks passed: hard deadline, no browse, route settlement, permanent failures, stale replies, native lock cancellation and placeholder priority")
 }
}
'''
replacements = {
    'DIAGNOSTIC': declaration(device, 'public enum DeviceDiagnosticStatus:'),
    'CHECK': declaration(pairing, 'public struct DeviceConnectionCheck:'),
    'HELPER': helper,
    'VERIFY': verify,
    'STATUS_TYPE': declaration(library, 'private struct DeviceStatus'),
    'FAILURE_STATUS': declaration(library, 'private var failureDeviceStatus:'),
    'STATUS': declaration(library, 'private var deviceStatus:'),
    'PLACEHOLDER': declaration(library, 'private var showsDevicePlaceholder:'),
    'GUIDANCE': declaration(library, 'private var _showsCellularConnectionGuidance:'),
    'MANUAL': declaration(library, 'private var _needsManualCellularRefresh:'),
    'NATIVE': declaration(native, 'private func connectRSDServiceOnce('),
}
for marker, value in replacements.items():
    source = source.replace('\n' + marker + '\n', '\n' + value + '\n')
with tempfile.TemporaryDirectory(prefix='aether-cellular-verification-') as temporary:
    folder = Path(temporary); swift = folder / 'Checks.swift'; swift.write_text(source)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
