#!/usr/bin/env python3
"""Exercise production activation recovery against controlled lifecycle/transport state."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
source=(repo/'Aether/Backend/Observable/DeviceConnectionManager.swift').read_text()
def declaration(start):
 a=source.index(start);b=source.index('{',a)+1;depth=1
 while depth:
  depth+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[a:b]
s=r'''
import Foundation
func CACurrentMediaTime()->Double {ProcessInfo.processInfo.systemUptime}
@MainActor final class UIApplication {static let shared=UIApplication();enum State {case active,inactive,background};var applicationState=State.active;var providerAvailable=true;var providerQueries=0;func canOpenURL(_ url:URL)->Bool {providerQueries+=1;return providerAvailable}}
@MainActor final class CellularAssistManager {static let shared=CellularAssistManager();var isBusy=false;var requiresTunnelConnection=false;var isWaitingForManualRecovery=false;func handleApplicationDidEnterBackground(){};func handleApplicationDidBecomeActive(){};func networkNoLongerNeedsManualRecovery(){isWaitingForManualRecovery=false}}
@MainActor final class EmbeddedTunnelManager {static let shared=EmbeddedTunnelManager();var isRunning=false;var isProviderAvailable=true}
@MainActor final class SpoofSession {static var existing: SpoofSession?;var requiresBackgroundExecution=false}
@MainActor final class AppInstallationManager {static let shared=AppInstallationManager();var isInstalling=false}
@MainActor final class OnDevicePairingManager {static let shared=OnDevicePairingManager();var isActive=false}
@MainActor final class Driver {
 var foregroundRecoveryTask:Task<Void,Never>?;var foregroundRecoveryID:UUID?
 var connectionWorkWaiters:[UUID:AsyncStream<Void>.Continuation]=[:]
 var appRefreshConnectionID:UUID?;var appRefreshConnectionTask:Task<Bool,Never>?;var reconciliationTask:Task<Void,Never>? {didSet {_signalConnectionWorkChanged()}};var lastVerifiedAt=0.0
 enum State {case disconnected,disconnecting};var state=State.disconnected
 enum Diagnostic {case tunnelUnavailable,providerMissing(Method)};var diagnostic=Diagnostic.tunnelUnavailable
 enum Method {case inApp,localDevVPN};var tunnelMethod=Method.inApp
 var hasPairingFile=true
 var awaitingInitialActivation=false;var awaitingIdleReconnect=false;var requiresInAppTunnelSetup=false;var hasCompletedInitialActivation=false
 var isConnectAutomaticallyEnabled=true;var isIDeviceInstallationMode=true
 var isConnected=true;var isUpdating=false {didSet {_signalConnectionWorkChanged()}};var starts=0;var checks=0;var verified=false
 var isDisconnectWhenIdleEnabled=true;var hasActiveTunnelDependencies=false;var stops=0
 static let unresolvedSimulationKey="test"
 var forcedStop=false
 var localDevVPNHandoffGeneration:UUID?;var transitionGeneration:UUID?;var transitionDeadline=0.0;var connectionEpoch:UInt64=0;var transitionExpectedState:Bool?
 var hasReturnedFromLocalDevVPN=false
 enum Network {case wifi,cellularOnly};var physicalNetworkState=Network.wifi
 LOCALDEV_GUIDANCE
 var automaticRetryBlocked=false
 func _automaticConnectionPrerequisitesReady()->Bool {hasPairingFile && !requiresInAppTunnelSetup && !automaticRetryBlocked && !needsLocalDevVPNCellularRecovery && _providerIsAvailable()}
 func _finishTransition(to state:State,diagnostic:Diagnostic){self.state=state;self.diagnostic=diagnostic;isUpdating=false;awaitingInitialActivation=false}
 func _armAttemptTimeout(epoch:UInt64,seconds:Double){}
 func _startTransitionPolling(generation:UUID,expectedState:Bool){}
 func setConnection(enabled:Bool,force:Bool=false){forcedStop=force;if !enabled {stops+=1;_cancelForegroundRecovery()}}
 enum Level {case notice}
 func _log(_ s:String,category:String,level:Level){}
 func _connectForIDeviceMode(){starts+=1;isUpdating=true}
 func verifyForAppRefresh() async -> Bool {await reconcile();if !isConnected {_connectForIDeviceMode()};return isConnected}
 func reconcile(force:Bool=false) async {guard reconciliationTask == nil else{return};checks+=1;isConnected=verified}
 func cancel(){_cancelForegroundRecovery()}
 func _expireConnectionAttempt(){isUpdating=false;isConnected=false;automaticRetryBlocked=true}
 func _waitForForegroundConnectionToSettleForTest(id:UUID,deadline:Double) async ->Bool {await _waitForForegroundConnectionToSettle(id:id,deadline:deadline)}
 func finishStart(){isUpdating=false;isConnected=true;verified=true}
 func providerAvailableForTest()->Bool {_providerIsAvailable()}
'''
for method in ['public var isAwaitingAutomaticConnection:', 'public func prepareForForeground()', 'public func handleInitialActivationIfNeeded()', 'public func handleAppForeground()', 'private func _providerIsAvailable()', 'private func _scheduleForegroundRecovery()', 'private func _signalConnectionWorkChanged()', 'private func _waitForForegroundConnectionToSettle(', 'private func _cancelForegroundRecovery()', 'public func handleAppBackground()']:
 s+=declaration(method)+'\n'
s+=declaration('private func _restoreInstallationMode()').replace('private func', 'func', 1)+'\n'
s+='}\n'
s=s.replace('LOCALDEV_GUIDANCE',declaration('public var needsLocalDevVPNCellularRecovery:').replace('public ', ''))
s+=r'''
func check(_ value:@autoclosure()->Bool,_ label:String){precondition(value(),label)}
@main struct Checks {
 @MainActor static func settled(_ driver:Driver) async throws {
  for _ in 0..<200 {if driver.foregroundRecoveryTask == nil{return};try await Task.sleep(nanoseconds:10_000_000)}
  preconditionFailure("Recovery did not settle")
 }
 @MainActor static func main() async throws {
  UIApplication.shared.applicationState = .active
  UIApplication.shared.providerAvailable=false
  let cold=Driver();cold.isConnected=false;cold.tunnelMethod = .localDevVPN
  cold._restoreInstallationMode()
  check(cold.isAwaitingAutomaticConnection && cold.starts==0 && UIApplication.shared.providerQueries==0,
   "An Active value during construction cannot query LocalDevVPN or start a handoff")
  check(!cold.providerAvailableForTest() && UIApplication.shared.providerQueries==0 && cold.isAwaitingAutomaticConnection,
   "Premature provider checks must not publish a missing-provider failure")
  UIApplication.shared.providerAvailable=true
  cold.handleInitialActivationIfNeeded()
  check(cold.hasCompletedInitialActivation && cold.starts==1 && UIApplication.shared.providerQueries==1,
   "Scene activation starts LocalDevVPN after its availability query is valid")
  cold.finishStart();try await settled(cold)
  cold.handleInitialActivationIfNeeded()
  check(cold.starts==1,"Repeated scene activation cannot start a second initial connection")
  UIApplication.shared.providerAvailable=false
  let missing=Driver();missing.isConnected=false;missing.tunnelMethod = .localDevVPN
  missing._restoreInstallationMode();missing.handleAppForeground()
  check(missing.starts==0 && !missing.isAwaitingAutomaticConnection,"A missing provider remains actionable after activation")
  if case .providerMissing(.localDevVPN)=missing.diagnostic {} else {preconditionFailure("Expected LocalDevVPN Missing")}
  UIApplication.shared.providerAvailable=true
  UIApplication.shared.applicationState = .inactive
  let launch=Driver();launch.isConnected=false;launch._restoreInstallationMode()
  check(launch.isAwaitingAutomaticConnection && launch.starts==0,"Inactive cold launch is pending, not unavailable; VPN waits for activation")
  let manual=Driver();manual.isConnectAutomaticallyEnabled=false;manual._restoreInstallationMode()
  check(!manual.isAwaitingAutomaticConnection,"Automatic connect off never shows pending")
  let unpaired=Driver();unpaired.hasPairingFile=false;unpaired._restoreInstallationMode()
  check(!unpaired.isAwaitingAutomaticConnection,"Missing pairing retains setup guidance")
  let server=Driver();server.isIDeviceInstallationMode=false;server._restoreInstallationMode()
  check(!server.isAwaitingAutomaticConnection,"Server mode never shows pending tunnel")
  UIApplication.shared.applicationState = .background
  let backgroundLaunch=Driver();backgroundLaunch._restoreInstallationMode()
  check(backgroundLaunch.isAwaitingAutomaticConnection && backgroundLaunch.starts==0,"Cold scene construction reserves presentation without starting a VPN in background")
  backgroundLaunch.handleAppBackground()
  check(backgroundLaunch.awaitingIdleReconnect && backgroundLaunch.isAwaitingAutomaticConnection,
   "Backgrounded cold start remains pending until foreground recovery")
  UIApplication.shared.applicationState = .active
  let returning=Driver();returning.isConnected=false
  UIApplication.shared.applicationState = .inactive
  returning.prepareForForeground()
  check(returning.isAwaitingAutomaticConnection && returning.starts==0,"Foreground notification marks pending before activation without opening VPN")
  UIApplication.shared.applicationState = .active
  returning.isUpdating=true;returning.handleAppForeground()
  check(returning.isAwaitingAutomaticConnection,"An idle disconnect settling on return stays pending")
  returning.isUpdating=false
  try await settled(returning)
  check(returning.starts==1 && !returning.isAwaitingAutomaticConnection,"Recovery starts once and genuine settled failure remains eligible for Retry")
  let setup=Driver();setup.hasPairingFile=false;setup.prepareForForeground()
  check(!setup.isAwaitingAutomaticConnection,"Missing pairing does not hide setup")
  setup.hasPairingFile=true;setup.requiresInAppTunnelSetup=true;setup.prepareForForeground()
  check(!setup.isAwaitingAutomaticConnection,"VPN setup remains visible")
  let delayed=Driver();delayed.handleAppBackground()
  check(delayed.stops==0,"Delayed background event cannot stop an active app")
  UIApplication.shared.applicationState = .background;delayed.handleAppForeground()
  check(delayed.foregroundRecoveryTask == nil,"Delayed foreground event cannot start recovery in background")
  delayed.handleAppBackground();check(delayed.stops==1,"Real background event still disconnects an idle tunnel")
  check(delayed.awaitingIdleReconnect && delayed.isAwaitingAutomaticConnection,
   "Intentional idle stop never becomes a temporary unavailable placeholder")
  UIApplication.shared.applicationState = .active;delayed.isConnected=false;delayed.handleAppForeground()
  check(!delayed.awaitingIdleReconnect && delayed.starts==1,
   "Foreground transfers pending presentation to the normal connection attempt")
  delayed.finishStart();try await settled(delayed)
  UIApplication.shared.applicationState = .background

  let connecting=Driver();connecting.isConnected=false;connecting.isUpdating=true;connecting.handleAppBackground()
  check(connecting.stops==1 && connecting.forcedStop,"Background idle stop supersedes an in-app connection still in progress")
  check(connecting.awaitingIdleReconnect,"Interrupted automatic start remains pending across background")
  let manualStop=Driver();manualStop.isConnected=false;manualStop.isUpdating=true;manualStop.transitionExpectedState=false
  manualStop.handleAppBackground()
  check(!manualStop.awaitingIdleReconnect,"An explicit disconnect is not mistaken for idle recovery")
  let noAuto=Driver();noAuto.isConnectAutomaticallyEnabled=false;noAuto.handleAppBackground()
  check(!noAuto.awaitingIdleReconnect,"Automatic connection off never retains an idle pending state")
  let missingPair=Driver();missingPair.hasPairingFile=false;missingPair.handleAppBackground()
  check(!missingPair.awaitingIdleReconnect,"Missing pairing remains actionable after backgrounding")
  let helper=Driver();helper.isConnected=false;helper.isUpdating=true;helper.tunnelMethod = .localDevVPN;helper.handleAppBackground()
  check(helper.stops==0,"LocalDevVPN's required app handoff is not interrupted")
  let stoppingAgain=Driver();stoppingAgain.state = .disconnecting;stoppingAgain.handleAppBackground()
  check(stoppingAgain.stops==0,"Repeated background callbacks do not restart an existing stop")
  let dependent=Driver();dependent.hasActiveTunnelDependencies=true;dependent.handleAppBackground()
  check(dependent.stops==0,"Background installation/spoofing dependencies retain their tunnel")
  UIApplication.shared.applicationState = .active
  for method in [Driver.Method.inApp, .localDevVPN] {
   let disabled=Driver();disabled.isConnectAutomaticallyEnabled=false;disabled.isConnected=false;disabled.tunnelMethod=method
   disabled._restoreInstallationMode();disabled.handleAppForeground();await Task.yield()
   check(disabled.starts==0,"Disabled automatic connection never starts a provider on launch or foreground")
  }
  let cellularReturn=Driver();cellularReturn.tunnelMethod = .localDevVPN;cellularReturn.isConnected=false;cellularReturn.isUpdating=true;cellularReturn.physicalNetworkState = .cellularOnly
  let handoff=UUID();cellularReturn.localDevVPNHandoffGeneration=handoff;cellularReturn.transitionGeneration=handoff;cellularReturn.transitionExpectedState=true
  cellularReturn.handleAppForeground()
  check(cellularReturn.needsLocalDevVPNCellularRecovery && !cellularReturn.isUpdating && cellularReturn.checks==0,"Returned LocalDevVPN handoff requests network change before probing")
  cellularReturn.handleAppForeground();await Task.yield()
  check(cellularReturn.starts==0 && cellularReturn.checks==0,"Manual network guidance cannot repeatedly reopen LocalDevVPN")
  let bounded=Driver();bounded.isUpdating=true;let timeoutID=UUID();bounded.foregroundRecoveryID=timeoutID
  let timedOut=await bounded._waitForForegroundConnectionToSettleForTest(id:timeoutID,deadline:CACurrentMediaTime()+0.03)
  check(!timedOut && bounded.connectionWorkWaiters.isEmpty,"A timed-out wait releases its continuation")
  let wake=Driver();wake.isUpdating=true;wake.handleAppForeground()
  while wake.connectionWorkWaiters.isEmpty {await Task.yield()}
  wake.isUpdating=false;try await settled(wake)
  check(wake.starts==1 && wake.connectionWorkWaiters.isEmpty,"Completion wakes recovery and releases its waiter")
  let stale=Driver();stale.handleAppForeground();try await settled(stale)
  check(stale.starts==1 && stale.checks==1,"Stale Connected is verified then recovered once")
  let stopping=Driver();stopping.isConnected=false;stopping.isUpdating=true;stopping.handleAppForeground()
  try await Task.sleep(nanoseconds:150_000_000)
  check(stopping.starts==0 && stopping.checks==0,"Unlock waits for idle disconnect before verification or restart")
  stopping.isUpdating=false;try await settled(stopping)
  check(stopping.starts==1,"Completed idle disconnect is followed by automatic reconnect")
  let checking=Driver();checking.isConnected=false;checking.isUpdating=true;checking.reconciliationTask=Task {};checking.handleAppForeground()
  try await Task.sleep(nanoseconds:150_000_000)
  check(checking.starts==0 && checking.checks==0,"In-flight verification is allowed to settle")
  checking.reconciliationTask=nil;checking.isUpdating=false;try await settled(checking);check(checking.starts==1,"Failed prior verification does not consume recovery")
  let browsing=Driver();browsing.reconciliationTask=Task {};browsing.handleAppForeground();try await settled(browsing)
  check(browsing.starts==0 && browsing.checks==0,"A verified connection does not wait for optional app browsing or restart")
  let healthy=Driver();healthy.verified=true;healthy.handleAppForeground();try await settled(healthy)
  check(healthy.starts==0,"Healthy tunnel is not restarted")
  let off=Driver();off.isConnectAutomaticallyEnabled=false;off.handleAppForeground()
  check(off.foregroundRecoveryTask == nil && off.starts==0,"Automatic connect off is preserved")
  let cancelled=Driver();cancelled.isUpdating=true;cancelled.handleAppForeground();cancelled.cancel();cancelled.isUpdating=false
  try await Task.sleep(nanoseconds:150_000_000);check(cancelled.starts==0,"Manual disconnect cancels delayed automatic recovery")
  let background=Driver();background.isUpdating=true;background.handleAppForeground();UIApplication.shared.applicationState = .background;background.handleAppBackground()
  try await settled(background);check(background.starts==0,"Returning to background prevents VPN launch")
  UIApplication.shared.applicationState = .active
  let duplicate=Driver();duplicate.verified=true;duplicate.handleAppForeground();duplicate.handleAppForeground();try await settled(duplicate)
  check(duplicate.checks==1,"Repeated activation cancels the obsolete recovery")
  let starting=Driver();starting.isConnected=false;starting.awaitingInitialActivation=true;starting.handleAppForeground()
  check(starting.isAwaitingAutomaticConnection,"Activation hands pending state to foreground recovery")
  check(starting.starts==1,"Disconnected foreground starts immediately")
  starting.finishStart();try await settled(starting);check(starting.starts==1,"Successful initial start isn't repeated")
  check(!starting.isAwaitingAutomaticConnection,"Settled recovery releases the pending UI state")
  print("Foreground tunnel recovery checks passed")
 }
}
'''
# Passive reconciliation cannot prematurely finish an embedded disconnect.
assert 'if method == .inApp, state == .disconnecting, !force { return false }' in declaration('private func _reconcile(')
assert '_cancelForegroundRecovery()' in declaration('public func handleAppBackground()')
assert '_cancelForegroundRecovery()' in declaration('public func setConnection(')
with tempfile.TemporaryDirectory(prefix='aether-foreground-') as d:
 p=pathlib.Path(d)/'Checks.swift';p.write_text(s)
 subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(p),'-o',d+'/checks'],check=True)
 subprocess.run([d+'/checks'],check=True)
# Compile the full reconciliation method and pause each async boundary.
r=r'''
import Foundation
func CACurrentMediaTime()->Double {ProcessInfo.processInfo.systemUptime}
struct PairingRecordIdentity:Equatable,Sendable {}
struct AppInfo:Sendable {}
enum DeviceConnectionError:Error {case pairingMissing,invalidPairing,tunnelUnavailable(String),serviceUnavailable(String)}
struct DeviceConnectionCheck:Sendable {var isConnected=false;var error:String?="fixture failure";var apps:[AppInfo]?;var rejectsPairingRecord=false;var isTransientTransportFailure=true}
final class HeartbeatManager:@unchecked Sendable {
 static let shared=HeartbeatManager();var ipAddress="";let isRsd=true
 private let condition=NSCondition();private var mode=0;private var held=false;private var entered=false
 func configure(_ mode:Int) {condition.lock();self.mode=mode;held=mode != 0;entered=false;condition.unlock()}
 var isEntered:Bool {condition.lock();defer {condition.unlock()};return entered}
 func release(){condition.lock();held=false;condition.broadcast();condition.unlock()}
 func resetRSDTunnel() {}
 func checkSocketConnection(timeoutInSeconds:Double)->DeviceConnectionCheck {DeviceConnectionCheck()}
 func checkDeviceConnection(timeoutInSeconds:Double,includeApps:Bool=false,onVerified:@Sendable ()->Void = {})->DeviceConnectionCheck {
  condition.lock();let selected=mode;entered=true;condition.unlock()
  if selected == 0 {return DeviceConnectionCheck()}
  if selected == 1 {onVerified()}
  condition.lock();while held {condition.wait()};condition.unlock()
  if selected == 2 {onVerified()}
  return DeviceConnectionCheck(isConnected:true,apps:[])
 }
}
@MainActor final class Gate {
 var pending:CheckedContinuation<Void,Never>?
 func wait() async {await withCheckedContinuation {pending=$0}}
 func release(){pending?.resume();pending=nil}
}
@MainActor final class CellularAssistManager {
 static let shared=CellularAssistManager();var isAutomaticRecoveryInProgress=false
 enum State {case idle,failed(String)};var state=State.idle;var isWaitingForManualRecovery=false
 func connectionDidSucceed(){}
}
@MainActor final class EmbeddedTunnelManager {
 static let shared=EmbeddedTunnelManager();let peerIPOnly="10.7.0.1";var isConnected=true;var blockRefresh=false;let gate=Gate()
 func refresh() async {if blockRefresh {await gate.wait()}}
}
@MainActor final class InstalledAppsStore {
 static let shared=InstalledAppsStore()
 func stageInitialBrowse(_ task:Task<[AppInfo],Error>){}
 func stageVerifiedApps(_ apps:[AppInfo]){}
}
struct PairingVerification {var record:PairingRecordIdentity?;mutating func beginChecking(_ r:PairingRecordIdentity){};mutating func finishChecking(_ r:PairingRecordIdentity,succeeded:Bool){}}
@MainActor final class UIApplication {static let shared=UIApplication();enum State {case active,background};var applicationState=State.active}
@MainActor final class Reconciler {
 enum Method {case inApp,localDevVPN};enum State {case connected,disconnected,disconnecting}
 enum Diagnostic:Equatable {case ready,tunnelUnavailable,pairingMissing,invalidPairing,error(String);var localizedDescription:String {"fixture"}}
 enum Network {case wifi,cellularOnly};enum Level {case debug,warning,notice,error}
 enum Rejection {case notRejected,discarded,failed,replaced}
 var automaticAttemptEpoch:UInt64?
 var awaitingInitialActivation=false;var localDevVPNHandoffGeneration:UUID?
 var isUpdating:Bool {state == .disconnecting}
 var networkGeneration=UUID();var connectionPreparation:UUID?;var transitionGeneration:UUID?;var connectionEpoch:UInt64=0
 var tunnelMethod=Method.inApp;var state=State.connected;var diagnostic=Diagnostic.ready
 var isIDeviceInstallationMode=true;var hasPairingFile=true;var transitionExpectedState:Bool?;var transitionDeadline=0.0
 var needsLocalDevVPNCellularRecovery=false
 var rsdCleanupTask:Task<Void,Never>?;var automaticRetryBlocked=false;var reconciliationRequiresFreshProbe=false;var physicalNetworkState=Network.wifi;var lastVerifiedRecord:PairingRecordIdentity?;var lastVerifiedAt=0.0
 var pairingVerification=PairingVerification();var activeVerificationID:UUID?
 var isConnected:Bool {state == .connected}
 var profile=true;var blockProfile=false;var blockReset=false;var profiles=0;var finishes=0
 let profileGate=Gate(),resetGate=Gate()
 @discardableResult func _syncPairingRecord()->PairingRecordIdentity? {nil}
 func _hasRequiredTunnelProfile() async ->Bool {profiles+=1;if blockProfile {await profileGate.wait()};return profile}
 func _resetRSDTunnel() async {if blockReset {await resetGate.wait()}}
 func _finishTransition(to s:State,diagnostic d:Diagnostic){finishes+=1;state=s;diagnostic=d}
 func _providerIsAvailable()->Bool {true}
 func _beginCellularAssistIfEligible()->Bool {false}
 func _recordStillMatches(_ r:PairingRecordIdentity?)->Bool {true}
 func _discardRejectedRecord(_ result:DeviceConnectionCheck,record:PairingRecordIdentity?) async ->Rejection {.notRejected}
 func _routeCellularRecoveryIfNeeded()->Bool {false}
 func _waitForCellularRecovery() async ->Bool {false}
 func _log(_ s:String,category:String = "Device",level:Level = .debug){}
 func verify() async {_ = await _reconcile(force:false,cellularAssistTransaction:false)}
 func newAttempt(){connectionEpoch+=1;transitionGeneration=UUID();state = .connected;diagnostic = .ready}
'''
embedded=(repo/'Aether/Backend/Observable/EmbeddedTunnelManager.swift').read_text()
helper=embedded[embedded.index('private final class TunnelOperationReply'):embedded.index('#if os(iOS)')]
r=r.replace('import Foundation\n','import Foundation\n'+helper,1)
r+=declaration('public func ensureConnected()')+'\n'+declaration('private func _reconcile(')+'\n'+declaration('private func _reconciliationIsCurrent(')+'\n}\n'
r+=r'''
func check(_ value:@autoclosure()->Bool,_ label:String){precondition(value(),label)}
@main struct Races {
 @MainActor static func main() async throws {
  HeartbeatManager.shared.configure(1)
  let early=Reconciler();early.state = .disconnected
  await early.verify()
  check(early.state == .connected && early.finishes == 1,"Transport readiness completes while the same client's app browse is still blocked")
  HeartbeatManager.shared.release()
  HeartbeatManager.shared.configure(2)
  let changedRoute=Reconciler();changedRoute.state = .disconnected
  let obsoleteRoute=Task {await changedRoute.verify()}
  while !HeartbeatManager.shared.isEntered {await Task.yield()}
  changedRoute.activeVerificationID=nil
  HeartbeatManager.shared.release();await obsoleteRoute.value
  check(changedRoute.finishes==0 && changedRoute.state == .disconnected,"A late route-invalidated verification cannot resurrect a disconnected tunnel")
  HeartbeatManager.shared.configure(2)
  let routeAction=Reconciler()
  let oldAction=Task {try await routeAction.ensureConnected()}
  while !HeartbeatManager.shared.isEntered {await Task.yield()}
  routeAction.networkGeneration=UUID()
  HeartbeatManager.shared.release()
  do {_ = try await oldAction.value;preconditionFailure("Old-route explicit verification must cancel")}
  catch is CancellationError {} catch {preconditionFailure("Unexpected route error")}
  check(routeAction.finishes==0,"An explicit action cannot publish readiness from an old route")
  HeartbeatManager.shared.configure(0)
  let profile=Reconciler();profile.profile=false;profile.blockProfile=true
  let p=Task {await profile.verify()};while profile.profileGate.pending == nil {await Task.yield()}
  profile.newAttempt();profile.profileGate.release();await p.value
  check(profile.finishes==0 && profile.diagnostic == .ready,"Old missing-profile result cannot disconnect a newer attempt")
  let refresh=Reconciler();EmbeddedTunnelManager.shared.blockRefresh=true
  let v=Task {await refresh.verify()};while EmbeddedTunnelManager.shared.gate.pending == nil {await Task.yield()}
  refresh.newAttempt();EmbeddedTunnelManager.shared.isConnected=false;EmbeddedTunnelManager.shared.gate.release();await v.value
  check(refresh.finishes==0,"Old VPN refresh cannot publish failure into a new attempt")
  EmbeddedTunnelManager.shared.blockRefresh=false;EmbeddedTunnelManager.shared.isConnected=true
  let reset=Reconciler();reset.profile=false;reset.blockReset=true
  let t=Task {await reset.verify()};while reset.resetGate.pending == nil {await Task.yield()}
  reset.newAttempt();reset.resetGate.release();await t.value
  check(reset.finishes==0 && reset.diagnostic == .ready,"Old transport-reset completion cannot overwrite newer readiness")
  let stopping=Reconciler();stopping.state = .disconnecting;await stopping.verify()
  check(stopping.profiles==0 && stopping.finishes==0,"Passive reconciliation leaves embedded-stop completion to its owner")
  let cached=Reconciler();cached.lastVerifiedAt=CACurrentMediaTime();await cached.verify()
  check(cached.profiles==0 && cached.finishes==0,"A freshly verified stable transport skips VPN/profile work")
  cached.lastVerifiedAt=0;cached.profile=false;await cached.verify()
  check(cached.profiles==1 && cached.finishes==1,"Lifecycle invalidation still performs a fresh verification")
  let current=Reconciler();await current.verify()
  check(current.finishes==1 && current.state == .disconnected,"A current failed verification still reports failure")
  let action=Reconciler();action.profile=false;action.blockProfile=true
  let a=Task {try await action.ensureConnected()};while action.profileGate.pending == nil {await Task.yield()}
  action.newAttempt();action.profileGate.release()
  do {_=try await a.value;preconditionFailure("Obsolete explicit verification should cancel")} catch is CancellationError {} catch {preconditionFailure("Wrong cancellation error")}
  check(action.finishes==0,"Old action verification cannot disconnect a new tunnel")
  let actionReset=Reconciler();actionReset.blockReset=true
  let ar=Task {try await actionReset.ensureConnected()};while actionReset.resetGate.pending == nil {await Task.yield()}
  actionReset.newAttempt();actionReset.resetGate.release()
  do {_=try await ar.value;preconditionFailure("Obsolete action reset should cancel")} catch is CancellationError {} catch {preconditionFailure("Wrong reset cancellation")}
  check(actionReset.finishes==0,"Old action reset does not overwrite a newer connection")
  print("Async tunnel reconciliation and action race checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-reconcile-races-') as d:
 p=pathlib.Path(d)/'Checks.swift';p.write_text(r)
 subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(p),'-o',d+'/checks'],check=True)
 subprocess.run([d+'/checks'],check=True)
