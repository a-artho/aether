"""Exercise the production native-callback handoff without suspending an app."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
proxy = (root / 'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift').read_text()
contexts = proxy[proxy.index('private final class UploadProgressPublisher'):proxy.index('public class InstallationProxy')]
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

  for completed in [false,true] {
   let counts=Counts(), publisher=UploadProgressPublisher {_ in}
   let context=InstallationProgressContext(publisher:publisher,onCommandSent:{counts.handoffs+=1})
   context.commandSent()
   context.cancel() // Either native completion or caller cancellation retires queued suspension.
   if !completed {context.report(80)}
   try await drain()
   precondition(counts.handoffs==0,"Retired calls cannot suspend the app later")
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
