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
  print("Self-update handoff checks passed: progress independence, one-shot command delivery, no-response command handoff, cancellation retirement and normal-app progress")
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
# running bundle through In-App VPN uses the flushed Install command + a
# four-second grace period; task end and suspension follow confirmed disconnect.
installation = (root / 'Aether/Backend/Observable/AppInstallationManager.swift').read_text()
device = (root / 'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
tunnel = (root / 'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
execution = (root / 'Aether/Utilities/AppOperationExecution.swift').read_text()
background = (root / 'Aether/Utilities/BackgroundTaskManager.swift').read_text()
begin_install = swift_method(installation, 'private func _beginInstall(')
assert 'if context.method == 1, appSnapshot.identifier == Bundle.main.bundleIdentifier' in begin_install
assert 'onInstallationCommandSent = { [weak self] in' in begin_install

handoff = swift_method(installation, 'private func _handoffSelfUpdateAfterCommandSent(')
for requirement in ('currentRequest?.method == 1',
                    'currentRequest?.app.identifier == Bundle.main.bundleIdentifier',
                    'tunnelMethod == .inApp',
                    'attempt.sentInstallationCommand = true',
                    'connection.prepareSelfUpdateTunnelHandoff()',
                    'Task.sleep(nanoseconds: 4_000_000_000)',
                    'connection.stopSelfUpdateTunnelForHandoff()',
                    'let tunnelStopped = await connection.waitForSelfUpdateTunnelHandoff()',
                    'execution?.finishForHandoff()',
                    'Could not disconnect Aether VPN. Turn it off and retry.',
                    'case .some(.installing), .some(.completed(.success))',
                    'error is InstallationBackgroundError',
                    'Self-install reported a failure before the handoff; leaving the VPN connected'):
    assert requirement in handoff, f'Missing self-update handoff guard/step: {requirement}'
prepare = handoff.index('connection.prepareSelfUpdateTunnelHandoff()')
grace = handoff.index('Task.sleep(nanoseconds: 4_000_000_000)')
stop_request = handoff.index('connection.stopSelfUpdateTunnelForHandoff()')
wait_result = handoff.index('let tunnelStopped = await connection.waitForSelfUpdateTunnelHandoff()')
task_finish = handoff.index('execution?.finishForHandoff()')
confirmed_suspend = handoff.index('perform(#selector(NSXPCConnection.suspend))', task_finish)
local_suspend = handoff.index('perform(#selector(NSXPCConnection.suspend))')
assert local_suspend < prepare < grace < stop_request < wait_result < task_finish < confirmed_suspend, 'LocalDevVPN behavior and In-App grace, confirmed VPN stop, task end, and suspension must stay ordered'
assert handoff.index('guard tunnelStopped else') < task_finish, 'A failed VPN stop must not end the handoff task or suspend Aether'
assert handoff.index('error is InstallationBackgroundError') < handoff.index('Self-install reported a failure before the handoff'), 'An iOS background interruption must not be mistaken for a definite install rejection'
assert handoff.count('error is InstallationBackgroundError') >= 3, 'Background-task interruption must be tolerated both when the flush callback arrives and after the grace period'

prepare_tunnel_handoff = swift_method(device, 'func prepareSelfUpdateTunnelHandoff()')
assert 'guard tunnelMethod == .inApp else { return false }' in prepare_tunnel_handoff
assert 'selfUpdateHandoffPending = true' in prepare_tunnel_handoff
assert 'requestStopIfRunning' not in prepare_tunnel_handoff, 'The grace period must keep the VPN running'
stop_tunnel_handoff = swift_method(device, 'func stopSelfUpdateTunnelForHandoff()')
assert 'guard tunnelMethod == .inApp, selfUpdateHandoffPending else { return false }' in stop_tunnel_handoff
assert stop_tunnel_handoff.index('EmbeddedTunnelManager.shared.requestStopIfRunning()') < stop_tunnel_handoff.index('setConnection(enabled: false'), 'Issue the stop request before asynchronous tunnel cleanup'
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
# The release build applies this checked-in patch to the pinned idevice source.
# Handoff must be signaled by the flushed command without waiting for a reply.
native_patch = (root / 'IDeviceKitten/Native/self-install-handoff.patch').read_text()
for requirement in ('install_with_callback_and_handoff',
                    'on_command_sent().await;',
                    'command_sent_handoff_does_not_wait_for_progress_or_completion',
                    'failed_transmission_does_not_handoff',
                    'command_sent_does_not_assert_service_success'):
    assert requirement in native_patch, f'Missing native command-flush regression guard: {requirement}'
assert 'service_accepted' not in native_patch and 'installation_proxy_install_with_acceptance' not in native_patch, 'The self-update handoff must not depend on a service-response hook'
print('Self-update lifecycle checks passed: exact app/iDevice scope, LocalDevVPN timing, In-App command-flush/grace/stop/task/suspend ordering, stop-failure handling and reconnect suppression')
