"""Exercise the native idle-stop and finite cleanup lease with platform doubles."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
def declaration(path,start):
 s=(repo/path).read_text();a=s.index(start);b=s.index('{',a+len(start))+1;depth=1
 while depth:
  depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
stop=declaration('Aether/Backend/Observable/EmbeddedTunnelManager.swift','public func stop(shouldProceed: () -> Bool = { true }) async')
stop='func stop(shouldProceed: () -> Bool = { true }) async {\n'+stop.split('#elseif os(iOS) && !targetEnvironment(macCatalyst)')[1].split('#else')[0]+'\n}'
lease=declaration('Aether/Backend/Observable/DeviceConnectionManager.swift','private final class IdleTunnelStopLease').replace('private final','@MainActor final',1)
embedded=(repo/'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
a=embedded.index('Task { @MainActor [weak self] in', embedded.index('statusObserver = NotificationCenter'))
b=embedded.index('{',a)+1;depth=1
while depth:
 depth+=(embedded[b]=='{')-(embedded[b]=='}');b+=1
status_delivery=embedded[a:b]
s=r'''
import Foundation
extension String {static func localized(_ s:String)->String{s}}
enum State:Equatable {case connected,disconnected,disconnecting,unavailable;case error(String)}
enum VPNStatus {case disconnected,invalid,connecting,connected}
enum Level {case notice,warning}
@MainActor final class Connection {
 var status=VPNStatus.connecting;var stops=0
 func stopVPNTunnel(){stops+=1;status = .disconnected}
}
@MainActor final class Manager {let connection=Connection()}
@MainActor final class Probe {
 var manager:Manager?;var saved:Manager?;var refreshes=0;var state=State.disconnected
 var delayStop=false;var stopReply:CheckedContinuation<Void,Never>?
 func refresh() async {refreshes+=1;await Task.yield();manager=saved}
 func waitForDisconnected() async ->Bool {if delayStop {await withCheckedContinuation{stopReply=$0}};return manager?.connection.status == .disconnected}
 func notify(_ connection:Connection)->Task<Void,Never> {
  let identity=ObjectIdentifier(connection)
  return STATUS_DELIVERY
 }
 func updateState(for status:VPNStatus){state = status == .connected ? .connected : .disconnected}
 func _setState(_ value:State){state=value}
 func _log(_ s:String,level:Level = .notice){}
'''+stop+r'''
}
struct UIBackgroundTaskIdentifier:Equatable {let raw:Int;static let invalid=Self(raw:-1)}
@MainActor final class UIApplication {
 static let shared=UIApplication();enum State {case active,background};var applicationState=State.background
 var begins=0;var ends=0;var expiration:(()->Void)?
 func beginBackgroundTask(withName:String,expirationHandler:@escaping ()->Void)->UIBackgroundTaskIdentifier {begins+=1;expiration=expirationHandler;return .init(raw:begins)}
 func endBackgroundTask(_ id:UIBackgroundTaskIdentifier){ends+=1}
}
'''+lease+r'''
@main struct Checks {
 @MainActor static func main() async {
  let notification=Probe();notification.manager=Manager()
  let current=notification.manager!.connection
  current.status = .disconnected
  let queued=notification.notify(current)
  current.status = .connected
  await queued.value
  precondition(notification.state == .connected,"Queued VPN notifications read the latest native status")
  let obsolete=notification.notify(current)
  notification.manager=Manager();notification.state = .disconnected
  await obsolete.value
  precondition(notification.state == .disconnected,"Notifications from an old profile cannot update its replacement")
  let cold=Probe(),profile=Manager();cold.saved=profile
  await cold.stop()
  precondition(cold.refreshes==1 && profile.connection.stops==1 && cold.state == .disconnected)
  let known=Probe();known.manager=Manager();await known.stop()
  precondition(known.refreshes==0 && known.manager!.connection.stops==1)
  let absent=Probe();await absent.stop();precondition(absent.state == .disconnected)
  let stale=Probe();stale.manager=Manager();stale.delayStop=true
  let oldStop=Task {await stale.stop()}
  while stale.stopReply == nil {await Task.yield()}
  oldStop.cancel();stale.state = .error("newer attempt")
  stale.stopReply?.resume();await oldStop.value
  precondition(stale.state == .error("newer attempt"),"A cancelled stop callback cannot overwrite a replacement attempt")
  let lease=IdleTunnelStopLease();precondition(UIApplication.shared.begins==1)
  lease.end();lease.end();precondition(UIApplication.shared.ends==1)
  let expires=IdleTunnelStopLease();UIApplication.shared.expiration?()
  for _ in 0..<20 {await Task.yield()}
  expires.end();precondition(UIApplication.shared.ends==2)
  UIApplication.shared.applicationState = .active
  let foreground=IdleTunnelStopLease();foreground.end();precondition(UIApplication.shared.begins==2)
  print("Idle tunnel stop checks passed: profile loading, pending VPN stop, finite lease and expiration")
 }
}
'''
s=s.replace('STATUS_DELIVERY',status_delivery)
with tempfile.TemporaryDirectory(prefix='aether-idle-stop-') as d:
 p=Path(d);(p/'Checks.swift').write_text(s)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
