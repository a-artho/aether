"""Run the complete Cellular Assist coordinator with controllable shortcut replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
production = (root / 'Aether/Backend/Observable/CellularAssistManager.swift').read_text()
production = production.replace('import UIKit', '').replace('import NimbleExtensions', '')
production = production.replace('NSObject, ObservableObject, @preconcurrency UIDocumentInteractionControllerDelegate', 'NSObject, ObservableObject')
production = production.replace('public ', '')
production = production.replace('UserDefaults.standard', 'preferences')
# Preserve callback grace semantics while keeping this deterministic check short.
production = production.replace('ProcessInfo.processInfo.systemUptime + 2', 'ProcessInfo.processInfo.systemUptime + 0.02')
stubs = r'''
import Foundation
import Combine
import CoreGraphics
let suite = "Aether.CellularAudit." + UUID().uuidString
@MainActor let preferences = UserDefaults(suiteName: suite)!
extension String {static func localized(_ text:String)->String{text}}
enum DebugLogItem {enum Level {case info,notice,warning}}
@MainActor final class DebugLogManager {
 static let shared=DebugLogManager()
 func log(_ text:String,category:String,level:DebugLogItem.Level){}
}
@MainActor final class UIApplication {
 static let shared=UIApplication()
 enum State {case active,background};var applicationState=State.active
 var installed=true;var acceptsOpen=true;var requests:[URL]=[]
 func canOpenURL(_ url:URL)->Bool{installed}
 func open(_ url:URL,options:[String:String]=[:],completionHandler:((Bool)->Void)?=nil){requests.append(url);completionHandler?(acceptsOpen)}
 static func topViewController()->Controller?{Controller()}
}
@MainActor final class Controller {let view=View()}
@MainActor final class View {let bounds=CGRect.zero}
@MainActor final class UIDocumentInteractionController {
 weak var delegate:AnyObject?
 init(url:URL){}
 func presentOpenInMenu(from:CGRect,in:View,animated:Bool)->Bool{false}
}
@MainActor final class UIAlertAction {
 enum Style{case `default`}
 init(title:String,style:Style,handler:@escaping (UIAlertAction)->Void){}
}
@MainActor enum UIAlertController {
 static func showAlertWithCancel(title:String,message:String,actions:[UIAlertAction]){}
 static func showAlertWithOk(title:String,message:String){}
}
@MainActor final class DeviceConnectionManager {
 static let shared=DeviceConnectionManager()
 var verificationCalls=0;var finishCalls=0;var failureMessage:String?
 var reply:CheckedContinuation<Bool,Never>?
 func verifyCellularTransport() async->Bool {
  verificationCalls+=1
  return await withCheckedContinuation{reply=$0}
 }
 func cellularRecoveryDidFinish(){finishCalls+=1}
 func complete(_ result:Bool){let callback=reply;reply=nil;callback?.resume(returning:result)}
}
'''
checks = r'''
@main struct Checks {
 @MainActor static func drain() async {for _ in 0..<100{await Task.yield()}}
 @MainActor static func reset() {
  preferences.removePersistentDomain(forName:suite)
  CellularAssistManager.shared.requestEnabled(false)
  UIApplication.shared.requests=[];UIApplication.shared.installed=true
  UIApplication.shared.acceptsOpen=true;UIApplication.shared.applicationState = .active
  DeviceConnectionManager.shared.failureMessage=nil
 }
 @MainActor static func callback(_ result:String,status:String="success") {
  let request=URLComponents(url:UIApplication.shared.requests.last!,resolvingAgainstBaseURL:false)!
  let url=request.queryItems!.first{$0.name == "x-" + status}!.value!
  var reply=URLComponents(string:url)!
  reply.queryItems!.append(.init(name:"result",value:result))
  CellularAssistManager.shared.handleCallback(reply.url!)
 }
 @MainActor static func enable() {
  CellularAssistManager.shared.requestEnabled(true)
  callback("AETHER_CELLULAR_HELPER_V1")
  precondition(CellularAssistManager.shared.isEnabled)
 }
 @MainActor static func main() async throws {
  defer{preferences.removePersistentDomain(forName:suite)}
  let cellular=CellularAssistManager.shared
  reset();UIApplication.shared.installed=false
  cellular.requestEnabled(true)
  precondition(!cellular.isEnabled && !cellular.isBusy && UIApplication.shared.requests.isEmpty)

  reset();cellular.requestEnabled(true)
  precondition(cellular.isBusy)
  cellular.handleApplicationDidBecomeActive()
  try await Task.sleep(for:.milliseconds(50))
  precondition(!cellular.isBusy && !cellular.isEnabled,"An abandoned helper probe cannot block connection forever")
  let lostProbeOpens=UIApplication.shared.requests.count
  cellular.handleApplicationDidBecomeActive();await drain()
  precondition(UIApplication.shared.requests.count==lostProbeOpens,"Lost verification is terminal until explicit retry")

  reset();cellular.requestEnabled(true)
  callback("missing",status:"error")
  precondition(!cellular.isBusy && !cellular.isEnabled,"Missing helper falls back from setup")

  reset();enable()
  precondition(cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true))
  precondition(cellular.requiresTunnelConnection && preferences.bool(forKey:"Aether.cellularAssistNeedsDataRestore"))
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  precondition(DeviceConnectionManager.shared.reply != nil)
  let calls=DeviceConnectionManager.shared.verificationCalls
  cellular.cancelAndRestoreIfNeeded()
  let afterCancel=UIApplication.shared.requests.count
  DeviceConnectionManager.shared.complete(false);await drain()
  precondition(UIApplication.shared.requests.count==afterCancel,"An obsolete transport completion cannot launch another restore")
  callback("AETHER_CELLULAR_HELPER_V1_ON")
  precondition(!preferences.bool(forKey:"Aether.cellularAssistNeedsDataRestore") && !cellular.isBusy)
  precondition(DeviceConnectionManager.shared.verificationCalls==calls,"No repeated verification loop")

  reset();enable()
  _=cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true)
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  DeviceConnectionManager.shared.complete(true);await drain()
  precondition(cellular.state == .restoringData)
  callback("missing",status:"error")
  let failedRestoreOpens=UIApplication.shared.requests.count
  cellular.handleApplicationDidBecomeActive();cellular.handleApplicationDidBecomeActive()
  cellular.cancelAndRestoreIfNeeded();await drain()
  precondition(UIApplication.shared.requests.count==failedRestoreOpens,"Known missing helper must not reopen on every activation or cancellation")
  precondition(preferences.bool(forKey:"Aether.cellularAssistNeedsDataRestore"),"A failed helper must not erase restoration debt")

  reset();enable()
  _=cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true)
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  DeviceConnectionManager.shared.complete(true);await drain()
  cellular.handleApplicationDidBecomeActive()
  try await Task.sleep(for:.milliseconds(50))
  let lostRestoreOpens=UIApplication.shared.requests.count
  cellular.handleApplicationDidBecomeActive();await drain()
  precondition(!cellular.isBusy && UIApplication.shared.requests.count==lostRestoreOpens,"A missing data-on callback cannot create a restore loop")
  precondition(preferences.bool(forKey:"Aether.cellularAssistNeedsDataRestore"))

  reset();enable()
  _=cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true)
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  DeviceConnectionManager.shared.complete(true);await drain()
  cellular.handleApplicationDidBecomeActive()
  UIApplication.shared.applicationState = .background
  cellular.handleApplicationDidEnterBackground()
  try await Task.sleep(for:.milliseconds(50))
  precondition(cellular.state == .restoringData && cellular.isEnabled,"Foreground callback grace cannot fail a valid operation after the next background handoff")
  UIApplication.shared.applicationState = .active
  cellular.handleApplicationDidBecomeActive()
  callback("AETHER_CELLULAR_HELPER_V1_ON")
  try await Task.sleep(for:.milliseconds(50))
  precondition(cellular.state == .idle,"The current restoration callback cancels its grace timer")

  reset();enable()
  _=cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true)
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  DeviceConnectionManager.shared.failureMessage="The device connection timed out. Retry connecting."
  DeviceConnectionManager.shared.complete(false);await drain()
  callback("AETHER_CELLULAR_HELPER_V1_ON")
  precondition(cellular.state == .failed("The device connection timed out. Retry connecting."),"Restoring data preserves the original connection failure")

  // Once ON has been launched, repeated cancels/activations join that command.
  reset();enable()
  _=cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true)
  callback("AETHER_CELLULAR_HELPER_V1_OFF");await drain()
  DeviceConnectionManager.shared.complete(true);await drain()
  let restoringOpens=UIApplication.shared.requests.count
  cellular.cancelAndRestoreIfNeeded();cellular.cancelAndRestoreIfNeeded()
  cellular.handleApplicationDidBecomeActive();cellular.handleApplicationDidBecomeActive()
  precondition(UIApplication.shared.requests.count==restoringOpens,"Pending restoration must keep the same shortcut and callback identity")
  callback("AETHER_CELLULAR_HELPER_V1_ON")
  precondition(cellular.state == .idle && !preferences.bool(forKey:"Aether.cellularAssistNeedsDataRestore"))
  precondition(!cellular.beginBootstrapIfPossible(cellularOnly:true,tunnelIsRunning:true),"A completed recovery episode cannot immediately run OFF again")

  // Repeated foreground notifications must not push the grace deadline back.
  reset();cellular.requestEnabled(true)
  cellular.handleApplicationDidBecomeActive()
  for _ in 0..<5 {
   try await Task.sleep(for:.milliseconds(8))
   cellular.handleApplicationDidBecomeActive()
  }
  precondition(!cellular.isBusy,"Repeated activation cannot extend callback recovery indefinitely")

  reset();cellular.requestEnabled(true);callback("bad",status:"error")
  let failure=cellular.state
  precondition(!cellular.beginManualRecoveryIfNeeded(cellularOnly:true,tunnelIsRunning:true) && cellular.state == failure,"Manual fallback cannot overwrite a specific helper failure")
  cellular.rearmAutomaticRecovery()
  precondition(cellular.state == .idle,"Explicit retry clears the acknowledged failure")
  reset()
  _=cellular.beginManualRecoveryIfNeeded(cellularOnly:true,tunnelIsRunning:true)
  precondition(cellular.isWaitingForManualRecovery && !cellular.requiresTunnelConnection,
   "Idle manual guidance does not hold a background VPN")
  cellular.networkNoLongerNeedsManualRecovery()
  precondition(!cellular.isWaitingForManualRecovery)
  precondition(DeviceConnectionManager.shared.finishCalls>0,"Terminal cellular states release their lifecycle ownership")
  print("Cellular lifecycle checks passed: missing app/helper, lost probe and restore callbacks, restoration debt, stale verification, one verification budget and manual idle guidance")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-cellular-lifecycle-') as temporary:
    folder = Path(temporary); swift = folder / 'Checks.swift'
    swift.write_text(stubs + production + checks)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
