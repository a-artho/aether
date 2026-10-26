"""Exercise production connection owners with stalled and late lifecycle callbacks."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
device = (root / 'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
embedded = (root / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
native = (root / 'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat+start.swift').read_text()
def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

helper = embedded[embedded.index('private final class TunnelOperationReply'):embedded.index('#if os(iOS)')]
methods = '\n'.join(declaration(device, marker) for marker in [
    'public func setConnectAutomatically(', 'private func _cancelTransition()', 'public func reconnectForIDeviceMode()', 'public var isAwaitingAutomaticConnection:', 'public var isUpdating:',
    'private func _signalConnectionWorkChanged()', 'private func _cancelForegroundRecovery()',
    'private func _cancelReconciliation()', 'private func _armAttemptTimeout(',
    'private func _expireConnectionAttempt()', 'private func _connectForIDeviceMode(',
    'public func setConnection(', 'public func handleAppBackground()',
    'private func _setEmbeddedTunnelConnection(', 'private func _finishTransition(',
    'private func _beginCellularAssistIfEligible()', 'private func _beginTransportRecovery(', 'private func _startTransitionPolling(',
    'public func reconcile(', 'public func setUpInAppTunnel()'])
methods = methods.replace('public func reconcile(', '@discardableResult public func reconcile(').replace('private ', '').replace('public ', '')
source = r'''
import Foundation
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
extension String { static func localized(_ value: String) -> String { value } }
HELPER
@MainActor final class Gate {
 var replies: [CheckedContinuation<Void, Never>] = []
 func wait() async { await withCheckedContinuation { replies.append($0) } }
 func release() { let pending = replies; replies = []; for reply in pending { reply.resume() } }
}
@MainActor final class UIApplication {
 static let shared = UIApplication()
 enum State { case active, background }; var applicationState = State.active
}
@MainActor final class EmbeddedTunnelManager {
 static let shared = EmbeddedTunnelManager()
 enum State { case disconnected, connecting, connected, error(String) }; var state = State.disconnected
 var starts = 0; var stops = 0; var invalidations = 0
 var delaysApproval = false; let approvalGate = Gate()
 var delaysStart = false; let startGate = Gate()
 func prepare(shouldProceed: () -> Bool) async throws -> Bool {
  if delaysApproval { await approvalGate.wait() }
  guard shouldProceed() else { throw CancellationError() }; return true
 }
 var isConnected: Bool { if case .connected = state { return true }; return false }
 var isRunning: Bool { isConnected || stateIsConnecting }
 var stateIsConnecting: Bool { if case .connecting = state { return true }; return false }
 func start(shouldStart: () -> Bool) async throws {
  guard shouldStart(), !Task.isCancelled else { throw CancellationError() }
  starts += 1; state = .connecting
  if delaysStart { await startGate.wait() }
  guard shouldStart(), !Task.isCancelled else { throw CancellationError() }
  state = .connected
 }
 func stop(shouldProceed: () -> Bool = { true }) async { guard shouldProceed() else{return}; stops += 1; state = .disconnected }
 func requestStopIfRunning() { state = .disconnected }
 func invalidateConfigurationCache() { invalidations += 1 }
}
final class HeartbeatManager: @unchecked Sendable {
 static let shared = HeartbeatManager()
 let rsdConnectionLock = NSLock(); var invalidations = 0
 func hold() { rsdConnectionLock.lock() }; func release() { rsdConnectionLock.unlock() }
 func _invalidateRSDTunnelLocked() { invalidations += 1 }
NATIVE_RESET
}
@MainActor final class SpoofSession { static var existing: SpoofSession?; var requiresBackgroundExecution = false }
@MainActor final class AppInstallationManager { static let shared = AppInstallationManager(); var isInstalling = false }
@MainActor final class OnDevicePairingManager { static let shared = OnDevicePairingManager(); var isActive = false }
@MainActor final class CellularAssistManager {
 static let shared = CellularAssistManager(); var isBusy = false; var requiresTunnelConnection = false; var isWaitingForManualRecovery = false
 var automatic = true; var requests = 0
 func handleApplicationDidEnterBackground(){}
 func networkNoLongerNeedsManualRecovery(){isWaitingForManualRecovery=false}
 func cancelAndRestoreIfNeeded(){requiresTunnelConnection=false;isBusy=false}
 func rearmAutomaticRecovery(){}
 func beginBootstrapIfPossible(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
  guard automatic, cellularOnly, tunnelIsRunning else { return false }
  requests += 1; requiresTunnelConnection = true; return true
 }
 func beginManualRecoveryIfNeeded(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
  guard !automatic, cellularOnly, tunnelIsRunning else { return false }
  requests += 1; isWaitingForManualRecovery = true; return true
 }
}
@MainActor final class IdleTunnelStopLease { func end() {} }
@MainActor final class Driver {
 enum State { case connected, disconnected, connecting, disconnecting }
 enum Diagnostic: Equatable { case ready, checking, tunnelUnavailable, pairingMissing, invalidPairing, providerMissing(Method), error(String); var localizedDescription: String { "fixture" } }
 enum Method { case inApp, localDevVPN; var displayName: String { "fixture" } }
 typealias DeviceConnectionState = State
 typealias DeviceDiagnosticStatus = Diagnostic
 enum Level { case notice, warning, error }
 var state = State.disconnected { didSet { _signalConnectionWorkChanged() } }
 var diagnostic = Diagnostic.tunnelUnavailable
 var isConnected: Bool { state == .connected }
 var connectionPreparation: UUID? { didSet { _signalConnectionWorkChanged() } }
 var preparationTask: Task<Void, Never>?
 var connectionTask: Task<Void, Never>?
 var attemptTimeoutTask: Task<Void, Never>?
 var rsdCleanupTask: Task<Void, Never>?
 var transitionTask: Task<Void, Never>?
 var foregroundRecoveryTask: Task<Void, Never>?
 var foregroundRecoveryID: UUID?
 var connectionWorkWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
 var appRefreshConnectionID: UUID?; var appRefreshConnectionTask: Task<Bool,Never>?; var reconciliationRequiresFreshProbe = false
 var reconciliationTask: Task<Bool, Never>? { didSet { _signalConnectionWorkChanged() } }
 var reconciliationID: UUID?
 var reconciliationPending = false; var pendingReconciliationForce = false
 var pendingCellularAssistReconciliation = false
 var transitionGeneration: UUID?; var activeVerificationID: UUID?
 var pendingTunnelMethod: Method?; var transitionExpectedState: Bool?
 var automaticAttemptEpoch:UInt64?
 var connectionEpoch: UInt64 = 0; var transitionDeadline = 0.0; var lastVerifiedAt = 0.0
 var hasReturnedFromLocalDevVPN=false
 var automaticRetryBlocked=false;var localDevVPNHandoffGeneration:UUID?
 var awaitingInitialActivation = false; var tunnelMethod = Method.inApp
 var hasCompletedInitialActivation=true
 enum Network { case wifi, cellularOnly }; var physicalNetworkState = Network.wifi
 var cellularPauses = 0
 func _pauseForCellularRecovery(manual: Bool) { cellularPauses += 1; attemptTimeoutTask?.cancel(); attemptTimeoutTask = nil }
 var isIDeviceInstallationMode = true; var isConnectAutomaticallyEnabled = true
 var isDisconnectWhenIdleEnabled = true; var hasActiveTunnelDependencies = false
 var hasPairingFile = true; var delayProfile = false; var delayReset = false; var delayVerification = false
 var requiresInAppTunnelSetup = false
 let profileGate = Gate(), resetGate = Gate(), verificationGate = Gate()
 static let connectAutomaticallyKey="Aether.Audit.Automatic"
 static let unresolvedSimulationKey = "fixture"
 func _syncPairingRecord() {}
 func _providerIsAvailable()->Bool {true}
 func _hasRequiredTunnelProfile() async -> Bool { if delayProfile { await profileGate.wait() }; return true }
 func _resetRSDTunnel() async -> Bool { if delayReset { await resetGate.wait() }; return !Task.isCancelled }
 func _setLocalDevVPNConnection(enabled: Bool, generation: UUID) {}
 func _stateDescription(_ state: State) -> String { "fixture" }
 func setTunnelMethod(_ method: Method) { tunnelMethod = method }
 func _log(_ text: String, category: String = "Tunnel", level: Level = .notice) {}
 func _reconcile(force: Bool, cellularAssistTransaction: Bool) async -> Bool {
  if delayVerification { await verificationGate.wait() }
  guard !Task.isCancelled else { return false }
  if EmbeddedTunnelManager.shared.isConnected { _finishTransition(to: .connected, diagnostic: .ready); return true }
  return false
 }
METHODS
}
@main struct Checks {
 @MainActor static func drain() async { for _ in 0..<100 { await Task.yield() } }
 @MainActor static func main() async throws {
  var lateReply: (@Sendable (Result<Int, Error>) -> Void)?
  do {
   let _: Int = try await awaitTunnelReply(timeout: 0.02) { lateReply = $0 }
   preconditionFailure("A missing callback must time out")
  } catch {}
  lateReply?(.success(7)); lateReply?(.success(8))
  let cancelled = Task { @MainActor in
   let _: Int = try await awaitTunnelReply { _ in }
  }
  await drain(); cancelled.cancel()
  do { try await cancelled.value; preconditionFailure("Cancellation must release the waiter") }
  catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
  let success: Int = try await awaitTunnelReply { $0(.success(1)); $0(.success(2)) }
  precondition(success == 1)
  let native = HeartbeatManager(); native.hold()
  let retiredCleanup = Task.detached { native.resetRSDTunnel() }
  retiredCleanup.cancel(); native.release(); await retiredCleanup.value
  precondition(native.invalidations == 0, "Retired cleanup must not reset a replacement session after acquiring the lock")
  await Task.detached { native.resetRSDTunnel() }.value
  precondition(native.invalidations == 1, "Current cleanup still releases native handles")

  let setup = Driver(); EmbeddedTunnelManager.shared.delaysApproval = true
  setup.setUpInAppTunnel(); await drain()
  precondition(setup.isUpdating && setup.attemptTimeoutTask == nil,
   "User approval is not a running connection attempt's timeout")
  EmbeddedTunnelManager.shared.delaysApproval = false
  EmbeddedTunnelManager.shared.approvalGate.release(); await drain()
  precondition(setup.isConnected, "Profile approval starts a bounded connection afterward")

  EmbeddedTunnelManager.shared.state = .disconnected
  let interrupted = Driver(); interrupted.delayProfile = true
  interrupted._connectForIDeviceMode(); await drain()
  precondition(interrupted.isUpdating && !interrupted.profileGate.replies.isEmpty)
  UIApplication.shared.applicationState = .background
  interrupted.handleAppBackground(); await drain()
  precondition(!interrupted.isUpdating && interrupted.preparationTask == nil,
   "Idle stop must retire preparation even if its callback has not returned")
  UIApplication.shared.applicationState = .active
  interrupted.delayProfile = false; interrupted._connectForIDeviceMode(); await drain()
  let starts = EmbeddedTunnelManager.shared.starts
  precondition(interrupted.isConnected)
  interrupted.profileGate.release(); await drain()
  precondition(EmbeddedTunnelManager.shared.starts == starts && interrupted.isConnected,
   "A late preparation callback cannot start or overwrite the replacement")

  let stopping = Driver(); stopping.state = .connecting; stopping.delayReset = true
  UIApplication.shared.applicationState = .background
  let stops = EmbeddedTunnelManager.shared.stops
  stopping.handleAppBackground(); await drain()
  precondition(EmbeddedTunnelManager.shared.stops == stops + 1 && !stopping.isUpdating,
   "VPN stop must not wait behind RSD cleanup")

  let retained = Driver(); retained.state = .connected; retained.hasActiveTunnelDependencies = true
  retained.handleAppBackground(); precondition(retained.isConnected)
  let off = Driver(); off.state = .connected; off.isDisconnectWhenIdleEnabled = false
  off.handleAppBackground(); precondition(off.isConnected)
  let helper = Driver(); helper.state = .connecting; helper.tunnelMethod = .localDevVPN
  helper.handleAppBackground(); precondition(helper.isUpdating, "Keep LocalDevVPN's deliberate handoff")

  UIApplication.shared.applicationState = .active
  EmbeddedTunnelManager.shared.state = .disconnected
  let expired = Driver(); expired.delayProfile = true
  expired._connectForIDeviceMode(); await drain()
  expired._armAttemptTimeout(epoch: expired.connectionEpoch, seconds: 0.02)
  try await Task.sleep(for: .milliseconds(40)); await drain()
  precondition(!expired.isUpdating && expired.preparationTask == nil)
  expired.profileGate.release(); await drain()
  precondition(!expired.isConnected, "Expired preparation cannot revive itself")

  EmbeddedTunnelManager.shared.state = .disconnected
  let owner = Driver(); owner.delayVerification = true
  let old = Task { await owner.reconcile() }; await drain()
  owner._cancelReconciliation(); owner.delayVerification = false
  owner._connectForIDeviceMode(); await drain()
  owner.verificationGate.release(); _ = await old.value; await drain()
  precondition(owner.isConnected, "A cancelled old reconciliation cannot clear the new owner's result")
  let autoTransport = Driver();autoTransport._beginTransportRecovery()
  precondition(autoTransport.automaticAttemptEpoch == autoTransport.connectionEpoch,"Route recovery records automatic ownership")
  autoTransport.setConnectAutomatically(false)
  precondition(!autoTransport.isUpdating,"Disabling automatic connection retires automatic route recovery")
  let explicitTransport = Driver();explicitTransport._beginTransportRecovery(automatically:false)
  explicitTransport.setConnectAutomatically(false)
  precondition(explicitTransport.isUpdating,"Disabling automation must not cancel an explicit route recovery")
  explicitTransport._cancelTransition()
  let localIdle = Driver();localIdle.tunnelMethod = .localDevVPN;localIdle.isDisconnectWhenIdleEnabled = true;localIdle.state = .connected
  UIApplication.shared.applicationState = .background;localIdle.handleAppBackground()
  precondition(localIdle.isConnected,"A persisted idle preference must never disconnect LocalDevVPN")
  UIApplication.shared.applicationState = .active
  let cellular = CellularAssistManager.shared
  for automatic in [true, false] {
   EmbeddedTunnelManager.shared.state = .disconnected
   EmbeddedTunnelManager.shared.delaysStart = true
   cellular.automatic = automatic; cellular.requiresTunnelConnection = false
   cellular.isWaitingForManualRecovery = false; cellular.requests = 0
   let sequence = Driver(); sequence.physicalNetworkState = .cellularOnly
   precondition(!sequence._beginCellularAssistIfEligible(), "No cellular prompt before VPN startup")
   sequence.setConnection(enabled: true); await drain()
   precondition(EmbeddedTunnelManager.shared.stateIsConnecting && cellular.requests == 0,
    "Starting a VPN must precede both automatic and manual Mobile Data guidance")
   EmbeddedTunnelManager.shared.startGate.release(); await drain()
   precondition(EmbeddedTunnelManager.shared.isConnected && cellular.requests == 1 && sequence.cellularPauses == 1,
    "Only a connected VPN can hand off to cellular recovery")
  }
  cellular.requiresTunnelConnection = false; cellular.isWaitingForManualRecovery = false
  EmbeddedTunnelManager.shared.delaysStart = false
  EmbeddedTunnelManager.shared.state = .disconnected
  let disabledPreparing=Driver();disabledPreparing.delayProfile=true
  let startsBeforeDisable=EmbeddedTunnelManager.shared.starts
  disabledPreparing._connectForIDeviceMode();await drain()
  disabledPreparing.setConnectAutomatically(false)
  disabledPreparing.profileGate.release();await drain()
  precondition(EmbeddedTunnelManager.shared.starts==startsBeforeDisable && !disabledPreparing.isUpdating,"Disabling automatic connection cancels pending automatic preparation")
  EmbeddedTunnelManager.shared.state = .disconnected;EmbeddedTunnelManager.shared.delaysStart=true
  let adopted=Driver();adopted.delayProfile=true
  adopted._connectForIDeviceMode();await drain()
  adopted.automaticAttemptEpoch=nil // An explicit device operation adopts preparation.
  adopted.setConnectAutomatically(false)
  adopted.profileGate.release();await drain()
  EmbeddedTunnelManager.shared.startGate.release();await drain()
  precondition(adopted.isConnected,"Explicit ownership survives disabling automatic launch during profile lookup")

  EmbeddedTunnelManager.shared.state = .disconnected
  let disabledStarting=Driver();disabledStarting._connectForIDeviceMode();await drain()
  disabledStarting.setConnectAutomatically(false)
  EmbeddedTunnelManager.shared.startGate.release();await drain()
  precondition(!EmbeddedTunnelManager.shared.isRunning && !disabledStarting.isConnected,"A cancelled start cannot turn VPN on after automatic connection is disabled")
  EmbeddedTunnelManager.shared.delaysStart=false
  let explicit=Driver();explicit.isConnectAutomaticallyEnabled=false
  explicit.reconnectForIDeviceMode();await drain()
  precondition(explicit.isConnected,"Explicit Retry still works with automatic connection disabled")
  UserDefaults.standard.removeObject(forKey:Driver.connectAutomaticallyKey)
  print("Tunnel lifecycle checks passed: callback timeout/cancellation, background preparation, prompt idle stop, protected work, idle off, helper handoff, stale completion and reconciliation ownership")
 }
}
'''.replace('HELPER', helper).replace('METHODS', methods).replace('NATIVE_RESET', declaration(native, 'public func resetRSDTunnel()'))
with tempfile.TemporaryDirectory(prefix='aether-tunnel-lifecycle-') as temporary:
    folder = Path(temporary)
    swift = folder / 'Checks.swift'; swift.write_text(source)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
