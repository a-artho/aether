"""Exercise the production native-callback handoff without suspending an app."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
proxy = (root / 'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift').read_text()
contexts = proxy[proxy.index('private final class UploadProgressPublisher'):proxy.index('public class InstallationProxy')]

def swift_method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

checks = r'''
import Foundation
CONTEXTS
@MainActor final class Counts {
 var handoffs=0
 var progress:[Double]=[]
}
@main struct Checks {
 @MainActor static func drain() async throws {try await Task.sleep(for:.milliseconds(20))}
 @MainActor static func main() async throws {
  let counts=Counts()
  let publisher=UploadProgressPublisher {counts.progress.append($0)}
  let context=InstallationProgressContext(publisher:publisher,onCommandSent:{counts.handoffs+=1})
  await Task.detached {
   DispatchQueue.concurrentPerform(iterations:200) {context.report(UInt64($0 % 100))}
  }.value
  try await drain()
  precondition(counts.handoffs==0,"Percentage responses must not trigger backgrounding")
  await Task.detached {
   DispatchQueue.concurrentPerform(iterations:200) {_ in context.commandSent()}
  }.value
  try await drain()
  precondition(counts.handoffs==1,"Concurrent command notifications hand off once")
  precondition(counts.progress.last==0.99,"Progress still coalesces monotonically")
  context.cancel();publisher.cancel()

  for _ in [false,true] {
   let counts=Counts(), publisher=UploadProgressPublisher {_ in}
   let context=InstallationProgressContext(publisher:publisher,onCommandSent:{counts.handoffs+=1})
   context.commandSent()
   context.cancel() // The Install command is already flushed; closing progress must not discard handoff.
   try await drain()
   precondition(counts.handoffs==1,"A flushed Install command still hands off if native completion/cancellation races delivery")
   context.commandSent()
   try await drain()
   precondition(counts.handoffs==1,"A flushed command can hand off only once")
   publisher.cancel()
  }

  let zero=Counts(), zeroPublisher=UploadProgressPublisher {_ in}
  let zeroContext=InstallationProgressContext(publisher:zeroPublisher,onCommandSent:{zero.handoffs+=1})
  zeroContext.commandSent();try await drain()
  precondition(zero.handoffs==1,"Command transmission triggers handoff without any progress response")
  zeroContext.cancel();zeroPublisher.cancel()

  let normal=Counts()
  let normalPublisher=UploadProgressPublisher {normal.progress.append($0)}
  let normalContext=InstallationProgressContext(publisher:normalPublisher,onCommandSent:nil)
  normalContext.commandSent();normalContext.report(50);try await drain()
  precondition(normal.progress==[0.5] && normal.handoffs==0,"Other apps retain progress without a self-update handoff")
  normalContext.cancel();normalPublisher.cancel()
  print("Self-update handoff checks passed: progress independence, one-shot command delivery, no-response handoff, completion/cancellation retirement and normal-app progress")
 }
}
'''.replace('CONTEXTS', contexts)
with tempfile.TemporaryDirectory(prefix='aether-self-handoff-') as directory:
    folder = Path(directory)
    swift = folder / 'Checks.swift'
    swift.write_text(checks)
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks')], check=True, timeout=15)

# Keep the app-level handoff narrow and ordered: only an iDevice install of the
# running bundle can take this path; the embedded VPN is stopped before the
# continued task ends, and suspension waits for the stop confirmation.
installation = (root / 'Aether/Backend/Observable/AppInstallationManager.swift').read_text()
device = (root / 'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
tunnel = (root / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
execution = (root / 'Aether/Utilities/AppOperationExecution.swift').read_text()
background = (root / 'Aether/Utilities/BackgroundTaskManager.swift').read_text()
begin_install = swift_method(installation, 'private func _beginInstall(')
assert 'if context.method == 1, appSnapshot.identifier == Bundle.main.bundleIdentifier' in begin_install
handoff = swift_method(installation, 'private func _handoffSelfUpdateAfterCommandSent(')
for requirement in ('currentRequest?.method == 1',
                    'currentRequest?.app.identifier == Bundle.main.bundleIdentifier',
                    'guard connection.tunnelMethod == .inApp else',
                    'connection.beginSelfUpdateTunnelHandoff()',
                    'execution?.finishForHandoff()',
                    'let tunnelStopped = await connection.waitForSelfUpdateTunnelHandoff()',
                    'Could not disconnect Aether VPN. Turn it off and retry.'):
    assert requirement in handoff, f'Missing self-update handoff guard/step: {requirement}'
stop_request = handoff.index('connection.beginSelfUpdateTunnelHandoff()')
task_finish = handoff.index('execution?.finishForHandoff()')
wait_result = handoff.index('let tunnelStopped = await connection.waitForSelfUpdateTunnelHandoff()')
confirmed_suspend = handoff.index('perform(#selector(NSXPCConnection.suspend))', wait_result)
assert stop_request < task_finish < wait_result < confirmed_suspend, 'VPN stop must precede task release and confirmed suspension'
assert handoff.index('guard tunnelStopped else') < confirmed_suspend, 'A failed VPN stop must not suspend Aether'

begin_tunnel_handoff = swift_method(device, 'func beginSelfUpdateTunnelHandoff()')
assert 'guard tunnelMethod == .inApp else { return false }' in begin_tunnel_handoff
assert begin_tunnel_handoff.index('EmbeddedTunnelManager.shared.requestStopIfRunning()') < begin_tunnel_handoff.index('setConnection(enabled: false'), 'Issue the immediate stop request before asynchronous tunnel cleanup'
wait_tunnel_handoff = swift_method(device, 'func waitForSelfUpdateTunnelHandoff()')
assert 'state == .disconnected' in wait_tunnel_handoff and '!EmbeddedTunnelManager.shared.isRunning' in wait_tunnel_handoff
assert 'EmbeddedTunnelManager.shared.waitForSelfUpdateDisconnection()' in wait_tunnel_handoff
waiter = swift_method(tunnel, 'func waitForSelfUpdateDisconnection()')
assert 'await waitForDisconnected()' in waiter, 'Self-update handoff must use the existing NetworkExtension status waiter'
for signature in ('public func connectAutomaticallyIfNeeded()', 'private func _connectForIDeviceMode(',
                  'public func handleAppForeground()', 'public func handleAppBackground()',
                  'public func setConnection(', 'public func verifyForAppRefresh()',
                  'private func _verifyAndRecoverForAppRefresh()', 'public func reconcile('):
    assert '!selfUpdateHandoffPending' in swift_method(device, signature), f'{signature} can race/restart the VPN during self-update'

finish_for_handoff = swift_method(execution, 'func finishForHandoff()')
assert 'finishTaskForHandoff(for: token)' in finish_for_handoff
finish_task = swift_method(background, 'func finishTaskForHandoff(')
assert '_stopTask(for: token, success: true, markProgressComplete: false)' in finish_task
stop_task = swift_method(background, 'private func _stopTask(')
assert 'if success && markProgressComplete' in stop_task, 'Handoff completion must not report installation at 100%'
print('Self-update lifecycle checks passed: exact app/iDevice scope, In-App-only stop, stop/task/suspend ordering, retryable stop failure and reconnect suppression')
