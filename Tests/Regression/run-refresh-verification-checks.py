"""Exercise the production shared Library/foreground verification owner."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
device = (root / 'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
embedded = (root / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
def declaration(text, marker):
    start = text.index(marker); end = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end].replace('private ', '').replace('public ', '')
methods = '\n'.join(declaration(device, marker) for marker in [
    'public func verifyForAppRefresh()', 'private func _waitForInitialActivation()', 'private func _joinAppRefreshConnection(',
    'private func _verifyAndRecoverForAppRefresh()', 'private func _waitForRefreshConnection()',
    'public func reconcile('])
helper = embedded[embedded.index('private final class TunnelOperationReply'):embedded.index('#if os(iOS)')]
# Shorten the real callback watchdog without changing its control flow.
helper = helper.replace('timeout: Double = 4', 'timeout: Double = 0.08')
source = r'''
import Foundation
import Combine
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
extension String { static func localized(_ text: String) -> String { text } }
@MainActor final class UIApplication {
 static let shared = UIApplication()
 enum State { case active, background }; var applicationState = State.active
}
@MainActor final class CellularAssistManager: ObservableObject {
 static let shared = CellularAssistManager()
 @Published var isBusy = false
}
@MainActor final class Gate {
 var pending: CheckedContinuation<Void,Never>?
 func wait() async { await withCheckedContinuation { pending = $0 } }
 func release() { pending?.resume(); pending = nil }
}
HELPER
@MainActor final class Driver: ObservableObject {
 enum State { case connected, disconnected, connecting, disconnecting }
 enum Method { case inApp, localDevVPN }
 enum Level { case warning }
 enum Diagnostic { case error(String) }
 func _finishTransition(to state: State, diagnostic: Diagnostic) {self.state=state}
 @Published var state = State.connected
 var hasCompletedInitialActivation=true
 var connectionWorkWaiters:[UUID:AsyncStream<Void>.Continuation]=[:]
 func wakeActivationWaiters() {for waiter in connectionWorkWaiters.values {waiter.yield(())}}
 @Published var appRefreshConnectionID: UUID?
 var appRefreshConnectionTask: Task<Bool,Never>?
 var reconciliationTask: Task<Bool,Never>?
 var reconciliationID: UUID?; var reconciliationRequiresFreshProbe = false
 var connectionEpoch: UInt64 = 0; var tunnelMethod = Method.inApp
 var transitionExpectedState: Bool?; var transitionDeadline = 0.0; var hasActiveTunnelDependencies = false
 var isIDeviceInstallationMode = true; var isConnectAutomaticallyEnabled = true
 var prerequisites = true; var checks = 0; var starts = 0; var expired = 0
 var result = true; var hold = false; let gate = Gate()
 var isConnected: Bool { state == .connected }
 var isUpdating: Bool { state == .connecting || state == .disconnecting }
 func _automaticConnectionPrerequisitesReady() -> Bool { prerequisites }
 func _connectForIDeviceMode() { starts += 1; connectionEpoch += 1; state = .connecting }
 func complete(_ success: Bool) { state = success ? .connected : .disconnected }
 func _reconcile(force: Bool, cellularAssistTransaction: Bool) async -> Bool {
  checks += 1
  let epoch = connectionEpoch
  if hold { await gate.wait() }
  guard !Task.isCancelled, epoch == connectionEpoch else { return false }
  state = result ? .connected : .disconnected
  return result
 }
 func _cancelReconciliation() { reconciliationTask?.cancel(); reconciliationTask=nil;reconciliationID=nil }
 func _expireConnectionAttempt() { expired += 1;connectionEpoch += 1;state = .disconnected }
 func _log(_ message: String, category: String, level: Level) {}
 func cancel() { appRefreshConnectionTask?.cancel();state = .disconnected }
 METHODS
}
@main struct Checks {
 @MainActor static func drain() async { for _ in 0..<100 { await Task.yield() } }
 @MainActor static func main() async throws {
  let early=Driver();early.hasCompletedInitialActivation=false
  let pending=Task {await early.verifyForAppRefresh()};await drain()
  precondition(early.checks==0 && early.starts==0 && !early.connectionWorkWaiters.isEmpty,
   "A Library refresh before activation waits without probing or failing")
  early.hasCompletedInitialActivation=true;early.wakeActivationWaiters()
  let activated=await pending.value
  precondition(activated && early.checks==1 && early.connectionWorkWaiters.isEmpty)
  let cancelledStartup=Driver();cancelledStartup.hasCompletedInitialActivation=false
  let cancelledWait=Task {await cancelledStartup.verifyForAppRefresh()};await drain();cancelledWait.cancel()
  let cancelledResult=await cancelledWait.value
  precondition(!cancelledResult && cancelledStartup.connectionWorkWaiters.isEmpty && cancelledStartup.checks==0)
  let backgroundStartup=Driver();backgroundStartup.hasCompletedInitialActivation=false
  let backgroundWait=Task {await backgroundStartup.verifyForAppRefresh()};await drain()
  UIApplication.shared.applicationState = .background;backgroundStartup.wakeActivationWaiters()
  let backgroundResult=await backgroundWait.value
  precondition(!backgroundResult && backgroundStartup.connectionWorkWaiters.isEmpty && backgroundStartup.checks==0)
  UIApplication.shared.applicationState = .active
  let shared = Driver();shared.hold=true
  let first = Task {await shared.verifyForAppRefresh()}
  await drain()
  let second = Task {await shared.verifyForAppRefresh()}
  await drain()
  precondition(shared.checks == 1, "Concurrent refreshes join one actual verification")
  shared.gate.release()
  let a = await first.value;let b = await second.value
  precondition(a && b && shared.appRefreshConnectionTask == nil)

  let failed = Driver();failed.result=false
  let recovery = Task {await failed.verifyForAppRefresh()}
  await drain();precondition(failed.starts == 1 && failed.isUpdating)
  failed.complete(false)
  let failure = await recovery.value
  precondition(!failure && failed.starts == 1, "A failed recovery must not recurse")

  let off = Driver();off.result=false;off.isConnectAutomaticallyEnabled=false
  let disabled = await off.verifyForAppRefresh()
  precondition(!disabled && off.checks == 1 && off.starts == 0)
  let setup = Driver();setup.result=false;setup.prerequisites=false
  let missing = await setup.verifyForAppRefresh()
  precondition(!missing && setup.starts == 0, "Setup failures do not launch recovery")

  let cancellation = Driver();cancellation.hold=true
  let leaving = Task {await cancellation.verifyForAppRefresh()};await drain()
  let staying = Task {await cancellation.verifyForAppRefresh()};await drain()
  leaving.cancel();let cancelled = await leaving.value
  precondition(!cancelled && cancellation.checks == 1)
  cancellation.gate.release();let joined = await staying.value
  precondition(joined, "Cancelling one caller does not cancel the shared owner")

  let stopping = Driver();stopping.state = .disconnecting;stopping.result=false
  let resumed = Task {await stopping.verifyForAppRefresh()};await drain()
  precondition(stopping.starts == 0)
  stopping.complete(false);await drain()
  precondition(stopping.starts == 1, "Return waits for stop before a single reconnect")
  stopping.complete(true);let ready = await resumed.value;precondition(ready)

  let stale = Driver();stale.hold=true;stale.result=false
  let outdated = Task {await stale.verifyForAppRefresh()};await drain()
  stale.connectionEpoch += 1;stale.gate.release()
  let obsolete = await outdated.value
  precondition(!obsolete && stale.starts == 0, "A superseded verification cannot initiate recovery")
  print("Refresh verification checks passed: shared results, single recovery, automatic-off, prerequisites, caller cancellation, stop/start ordering and stale generations")
 }
}
'''.replace('HELPER', helper).replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='aether-refresh-verify-') as folder:
    swift = Path(folder) / 'Checks.swift'; swift.write_text(source)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',folder+'/checks'],check=True,timeout=45)
    subprocess.run([folder+'/checks'],check=True,timeout=15)
