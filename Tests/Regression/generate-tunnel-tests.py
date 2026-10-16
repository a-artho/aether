"""Check production startup state, preference coalescing and event-driven VPN waits."""
import pathlib,sys
repo=pathlib.Path(__file__).resolve().parents[2]
device=(repo/'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
vpn=(repo/'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
def method(source,signature):
 start=source.index(signature); brace=source.index('{',start); level=1; end=brace+1
 while level:
  if source[end]=='{':level+=1
  elif source[end]=='}':level-=1
  end+=1
 return source[start:end]
startup=method(device,'private func _connectForIDeviceMode()').replace('private func','func',1).replace('UIApplication','TunnelApplication')
load=method(vpn,'func loadManagers()')
wait=method(vpn,'func waitForStatus(')
invalidate=method(vpn,'public func invalidateConfigurationCache()').replace('#if os(iOS) && !targetEnvironment(macCatalyst)','').replace('#endif','')
head=r'''
import Foundation
import XCTest
@MainActor private final class TunnelApplication { enum State { case active,inactive,background }; static let shared=TunnelApplication(); var applicationState=State.active }
private enum StartupDiagnostic { case checking,pairingMissing,tunnelUnavailable }
@MainActor private final class StartupGate {
 var waiting:CheckedContinuation<Void,Never>?
 func wait() async { await withCheckedContinuation { waiting=$0 } }
 func release() { waiting?.resume();waiting=nil }
}
@MainActor private final class StartupFixture {
 var isIDeviceInstallationMode=true;var isConnected=false;var hasPairingFile=true
 var awaitingInitialActivation=false
 var connectionEpoch:UInt64=0;var activeVerificationID:UUID?
 var connectionPreparation:UUID?;var diagnostic=StartupDiagnostic.tunnelUnavailable
 var isUpdating:Bool { connectionPreparation != nil }
 var profile=true;var starts=0;let gate=StartupGate()
 func _syncPairingRecord() {}
 func _finishTransition(to:StartupState,diagnostic:StartupDiagnostic) { connectionPreparation=nil;self.diagnostic=diagnostic }
 enum StartupState { case disconnected }
 func _hasRequiredTunnelProfile() async -> Bool { await gate.wait();return profile }
 func setConnection(enabled:Bool) { starts += 1 }
'''
handoff=vpn[vpn.index('// The system callback transfers'):vpn.index('@MainActor', vpn.index('deinit { cancel() }'))]
preferences=r'''
}
private enum NEVPNStatus { case invalid,disconnected,connecting,connected }
private final class NEVPNConnection:NSObject { var status=NEVPNStatus.disconnected }
private extension Notification.Name { static let NEVPNStatusDidChange=Self("TunnelTestStatus") }
@MainActor private final class NETunnelProviderManager {
 static var callbacks:[([NETunnelProviderManager]?,Error?)->Void]=[]
 let connection=NEVPNConnection()
 static func loadAllFromPreferences(completionHandler:@escaping ([NETunnelProviderManager]?,Error?)->Void) { callbacks.append(completionHandler) }
}
@MainActor private final class VPNFixture {
 var manager:NETunnelProviderManager?=NETunnelProviderManager()
 var cachedManagers:[NETunnelProviderManager]?;var managersLoadedAt:TimeInterval=0;var managersRevision=UUID()
 var managersLoad:(id:UUID,task:Task<TunnelManagersHandoff,Error>)?
'''
preferences=preferences.replace('@MainActor private final class VPNFixture', handoff+'@MainActor private final class VPNFixture')
tests=r'''
}
final class TunnelOptimizationTests:XCTestCase {
 @MainActor func testPreparationShowsConnectingAndCoalescesLaunchRequests() async {
  let fixture=StartupFixture()
  fixture._connectForIDeviceMode();XCTAssertTrue(fixture.isUpdating);XCTAssertEqual(fixture.diagnostic,.checking)
  fixture._connectForIDeviceMode()
  while fixture.gate.waiting == nil { await Task.yield() }
  fixture.gate.release()
  while fixture.isUpdating { await Task.yield() }
  XCTAssertEqual(fixture.starts,1)
 }
 @MainActor func testMissingProfileAndCancelledPreparationNeverStartVPN() async {
  for cancelled in [false,true] {
   let fixture=StartupFixture();fixture.profile=false;fixture._connectForIDeviceMode()
   while fixture.gate.waiting == nil { await Task.yield() }
   if cancelled { fixture.connectionPreparation=nil }
   fixture.gate.release()
   for _ in 0..<10 { await Task.yield() }
   XCTAssertEqual(fixture.starts,0);XCTAssertFalse(fixture.isUpdating)
   if !cancelled { XCTAssertEqual(fixture.diagnostic,.tunnelUnavailable) }
  }
 }
 @MainActor func testBackgroundWakeAndBackgroundDuringPreparationDoNotStartVPN() async {
  let fixture=StartupFixture()
  TunnelApplication.shared.applicationState = .background
  fixture._connectForIDeviceMode();XCTAssertFalse(fixture.isUpdating);XCTAssertEqual(fixture.starts,0)
  TunnelApplication.shared.applicationState = .active
  fixture._connectForIDeviceMode()
  while fixture.gate.waiting == nil { await Task.yield() }
  TunnelApplication.shared.applicationState = .background
  fixture.gate.release()
  while fixture.isUpdating { await Task.yield() }
  XCTAssertEqual(fixture.starts,0)
  TunnelApplication.shared.applicationState = .active
 }
 @MainActor func testPreferenceRequestsShareLoadAndInvalidationRejectsStaleCache() async throws {
  NETunnelProviderManager.callbacks=[]
  let fixture=VPNFixture(), first=Task { try await fixture.loadManagers() }
  while NETunnelProviderManager.callbacks.isEmpty { await Task.yield() }
  let second=Task { try await fixture.loadManagers() }
  for _ in 0..<10 { await Task.yield() }
  XCTAssertEqual(NETunnelProviderManager.callbacks.count,1)
  fixture.invalidateConfigurationCache()
  NETunnelProviderManager.callbacks[0]([NETunnelProviderManager()],nil)
  _=try await first.value;_=try await second.value
  XCTAssertNil(fixture.cachedManagers)
  let fresh=Task { try await fixture.loadManagers() }
  while NETunnelProviderManager.callbacks.count < 2 { await Task.yield() }
  NETunnelProviderManager.callbacks[1]([NETunnelProviderManager()],nil)
  _=try await fresh.value;_=try await fixture.loadManagers()
  XCTAssertEqual(NETunnelProviderManager.callbacks.count,2)
 }
 @MainActor func testVPNWaitRespondsToStatusAndTimesOut() async {
  let fixture=VPNFixture(), task=Task { await fixture.waitForStatus(.connected,timeout:1_000_000_000) }
  for _ in 0..<10 { await Task.yield() }
  fixture.manager!.connection.status = .connected
  NotificationCenter.default.post(name:.NEVPNStatusDidChange,object:fixture.manager!.connection)
  let ready=await task.value;XCTAssertTrue(ready)
  fixture.manager!.connection.status = .disconnected
  let timedOut=await fixture.waitForStatus(.connected,timeout:20_000_000);XCTAssertFalse(timedOut)
 }
}
'''
pathlib.Path(sys.argv[1],'TunnelOptimizationTests.swift').write_text(head+startup+preferences+load+"\n"+invalidate+"\n"+wait+tests)
# Execute the actual automation controls against an isolated preferences suite.
controls='\n'.join(method(device, signature) for signature in [
 'public func setDisconnectWhenIdle(', 'public func setConnectAutomatically(',
 'public func handleAppForeground()', 'public func handleAppBackground()',
 'private func _restoreInstallationMode()'
]).replace('private func _restoreInstallationMode','func _restoreInstallationMode')
for old,new in [('UserDefaults.standard','automationDefaults'),('CellularAssistManager','AutoCellular'),('EmbeddedTunnelManager','AutoEmbedded'),('AppInstallationManager','AutoInstaller'),('OnDevicePairingManager','AutoPairing'),('UIApplication','TunnelApplication')]: controls=controls.replace(old,new)
assignments='\n'.join(line.strip().replace('UserDefaults.standard','automationDefaults') for line in device.splitlines() if line.strip().startswith(('isDisconnectWhenIdleEnabled = UserDefaults','isConnectAutomaticallyEnabled = UserDefaults')))
automation=r'''
private let automationDefaults=UserDefaults(suiteName:"AetherAutomationTest-"+UUID().uuidString)!
@MainActor private final class AutoCellular {
 static let shared=AutoCellular();var isBusy=false
 func handleApplicationDidBecomeActive() {}
}
@MainActor private final class AutoEmbedded { static let shared=AutoEmbedded();func invalidateConfigurationCache() {} }
@MainActor private final class AutoInstaller { static let shared=AutoInstaller();var isInstalling=false }
@MainActor private final class AutoPairing { static let shared=AutoPairing();var isActive=false }
@MainActor private final class AutomationFixture {
 static let disconnectWhenIdleKey="Aether.autoTunnelLifecycle",connectAutomaticallyKey="Aether.connectAutomatically",unresolvedSimulationKey="AutoTestSimulation"
 var isDisconnectWhenIdleEnabled:Bool;var isConnectAutomaticallyEnabled:Bool
 var awaitingInitialActivation=false;var hasPairingFile=true
 var lastVerifiedAt:TimeInterval=0;var isIDeviceInstallationMode=true;var isConnected=false;var isUpdating=false
 var state=StartupFixture.StartupState.disconnected;var diagnostic=StartupDiagnostic.tunnelUnavailable
 var hasActiveTunnelDependencies=false;var starts=0;var stops=0
 enum Level { case notice }
 func _log(_ message:String,category:String,level:Level) {}
 func _scheduleForegroundRecovery() {}
 func _cancelForegroundRecovery() {}
 func _connectForIDeviceMode() { starts += 1 }
 func setConnection(enabled:Bool) { if !enabled { stops += 1 } }
 init() {
'''+assignments+r'''
 }
'''+controls+r'''
}
final class TunnelAutomationTests:XCTestCase {
 override func tearDown() {
  automationDefaults.removeObject(forKey:AutomationFixture.connectAutomaticallyKey)
  automationDefaults.removeObject(forKey:AutomationFixture.disconnectWhenIdleKey)
 }
 @MainActor func testBackgroundRestorationWaitsForForeground() {
  let fixture=AutomationFixture()
  TunnelApplication.shared.applicationState = .background
  fixture._restoreInstallationMode();XCTAssertEqual(fixture.starts,0)
  TunnelApplication.shared.applicationState = .active
  fixture.handleAppForeground();XCTAssertEqual(fixture.starts,1)
 }
 @MainActor func testDefaultsAndSavedChoices() {
  automationDefaults.removeObject(forKey:AutomationFixture.connectAutomaticallyKey)
  automationDefaults.set(true,forKey:AutomationFixture.disconnectWhenIdleKey)
  let initial=AutomationFixture()
  XCTAssertTrue(initial.isConnectAutomaticallyEnabled);XCTAssertTrue(initial.isDisconnectWhenIdleEnabled)
  initial.setConnectAutomatically(false);initial.setDisconnectWhenIdle(false)
  let restored=AutomationFixture()
  XCTAssertFalse(restored.isConnectAutomaticallyEnabled);XCTAssertFalse(restored.isDisconnectWhenIdleEnabled)
 }
 @MainActor func testAllFourCombinationsRemainIndependent() {
  for connect in [false,true] { for disconnect in [false,true] {
   automationDefaults.set(connect,forKey:AutomationFixture.connectAutomaticallyKey)
   automationDefaults.set(disconnect,forKey:AutomationFixture.disconnectWhenIdleKey)
   let fixture=AutomationFixture()
   fixture._restoreInstallationMode();fixture.handleAppForeground()
   XCTAssertEqual(fixture.starts,connect ? 2 : 0)
   fixture.isConnected=true;TunnelApplication.shared.applicationState = .background;fixture.handleAppBackground()
   XCTAssertEqual(fixture.stops,disconnect ? 1 : 0)
   fixture.hasActiveTunnelDependencies=true;fixture.handleAppBackground()
   XCTAssertEqual(fixture.stops,disconnect ? 1 : 0)
   TunnelApplication.shared.applicationState = .active
  }}
 }
 @MainActor func testEnablingDisconnectDoesNotConnectAndServerDoesNotAutoConnect() {
  automationDefaults.set(false,forKey:AutomationFixture.connectAutomaticallyKey)
  automationDefaults.set(false,forKey:AutomationFixture.disconnectWhenIdleKey)
  let fixture=AutomationFixture()
  fixture.setDisconnectWhenIdle(true);XCTAssertEqual(fixture.starts,0)
  fixture.setConnectAutomatically(true);XCTAssertEqual(fixture.starts,1)
  fixture.isIDeviceInstallationMode=false
  fixture._restoreInstallationMode();fixture.handleAppForeground();XCTAssertEqual(fixture.starts,1)
 }
}
'''
# XCTest teardown is nonisolated; use literal keys rather than actor-isolated statics.
automation=automation.replace('automationDefaults.removeObject(forKey:AutomationFixture.connectAutomaticallyKey)','automationDefaults.removeObject(forKey:"Aether.connectAutomatically")').replace('automationDefaults.removeObject(forKey:AutomationFixture.disconnectWhenIdleKey)','automationDefaults.removeObject(forKey:"Aether.autoTunnelLifecycle")')
with pathlib.Path(sys.argv[1],'TunnelOptimizationTests.swift').open('a') as file: file.write(automation)
