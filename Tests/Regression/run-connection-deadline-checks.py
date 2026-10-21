#!/usr/bin/env python3
"""Run production deadline/lock/discovery logic with deterministic network doubles."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
attempt=(repo/'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/RSDConnectionAttempt.swift').read_text().replace('import IDevice','')
discovery=(repo/'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/RSDPortDiscovery.swift').read_text().replace('import Network','')
heartbeat=(repo/'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat.swift').read_text()
generation=heartbeat[heartbeat.index('\tprivate let attemptGenerationLock'):heartbeat.index('\tlet rsdConnectionLock')]
source=r'''
import Foundation
func check(_ ok: @autoclosure () -> Bool, _ message: String) {if !ok(){fatalError(message)}}
struct IDeviceSwiftError: Error {let code:Int32;init(_ code:Int32,message:String){self.code=code}}
func idevice_connection_attempt_begin(_ a:UInt64,_ b:UInt64,_ c:@convention(c)(UnsafeMutableRawPointer?)->Bool,_ d:UnsafeMutableRawPointer?) {}
func idevice_connection_attempt_end() {}
final class Flag: @unchecked Sendable {
 let lock=NSLock();var value=false
 func set(){lock.lock();value=true;lock.unlock()}
 func get()->Bool{lock.lock();defer{lock.unlock()};return value}
}
enum NWEndpoint: Hashable {case hostPort(String,Port)
 struct Port:Hashable {let rawValue:UInt16}
}
struct Parameters {static let tcp=Parameters()}
final class NWBrowser: @unchecked Sendable {
 struct Descriptor {static func bonjour(type:String,domain:String?)->Descriptor{Descriptor()}}
 struct Result:Hashable{let endpoint:NWEndpoint}
 enum State{case failed}
 static var starts=0;static var cancels=0;static var delay:Double?=nil
 var browseResultsChangedHandler:((Set<Result>,Set<Result>)->Void)?
 var stateUpdateHandler:((State)->Void)?
 var cancelled=false
 init(for:Descriptor,using:Parameters){}
 func start(queue:DispatchQueue){Self.starts+=1;if let delay=Self.delay{queue.asyncAfter(deadline:.now()+delay){[self] in
  if !cancelled {browseResultsChangedHandler?([Result(endpoint:.hostPort("fixture",.init(rawValue:55000)))],[])}
 }}}
 func cancel(){cancelled=true;Self.cancels+=1}
}
final class NWConnection: @unchecked Sendable {
 enum State{case setup,ready,failed,cancelled}
 struct Path{let remoteEndpoint:NWEndpoint?}
 let endpoint:NWEndpoint;var currentPath:Path?;var stateUpdateHandler:((State)->Void)?
 init(to:NWEndpoint,using:Parameters){endpoint=to;currentPath=Path(remoteEndpoint:to)}
 func start(queue:DispatchQueue){queue.async{[self] in stateUpdateHandler?(.ready)}}
 func cancel(){stateUpdateHandler?(.cancelled)}
}
'''+attempt+discovery+'\nfinal class HeartbeatManager: @unchecked Sendable {\n'+generation+'\n}\n'+r'''
let manager=HeartbeatManager()
let queuedCancellation=manager.rsdConnectionCancellationCheck()
let active=manager.makeConnectionAttempt(timeout:5)
manager.cancelPendingRSDConnections()
check(queuedCancellation(),"Reset must cancel work captured before dispatch")
check(active.isCancelled,"Reset must cancel running establishment")
check(!manager.makeConnectionAttempt(timeout:5).isCancelled,"Fresh attempt inherits stale cancellation")
let held=NSLock();held.lock()
let flag=Flag();let attempt=RSDConnectionAttempt(timeout:5,cancelled:{flag.get()})
let done=DispatchSemaphore(value:0)
DispatchQueue.global().async {
 let start=ProcessInfo.processInfo.systemUptime
 do {try attempt.lock(held);fatalError("Acquired a held lock")} catch is CancellationError {} catch {fatalError("Wrong cancellation: \(error)")}
 check(ProcessInfo.processInfo.systemUptime-start < 0.5,"Cancellation must not await transport lock")
 done.signal()
}
Thread.sleep(forTimeInterval:0.04);flag.set()
check(done.wait(timeout:.now()+1) == .success,"Cancelled lock waiter stuck")
held.unlock()
held.lock()
let bounded=RSDConnectionAttempt(timeout:0.04,cancelled:{false})
let timeoutDone=DispatchSemaphore(value:0)
DispatchQueue.global().async {
 do {try bounded.lock(held);fatalError("Lock should time out")} catch let e as IDeviceSwiftError {check(e.code==109,"Wrong deadline error")} catch {fatalError("Wrong error")}
 timeoutDone.signal()
}
check(timeoutDone.wait(timeout:.now()+1) == .success,"Lock acquisition has no deadline")
held.unlock()
let exhausted=RSDConnectionAttempt(timeout:0.04,cancelled:{false})
do {try exhausted.backoff(0.5);fatalError("Backoff exceeded deadline")}catch let e as IDeviceSwiftError{check(e.code==109,"Wrong backoff error")}
NWBrowser.delay=1.3
let ports=RSDPortDiscovery.resolvePorts(timeout:1.7,stopWhen:{$0.contains(55000)})
check(ports==[55000],"Late endpoint lost")
check(NWBrowser.starts==1 && NWBrowser.cancels==1,"Browser restarted during discovery")
NWBrowser.delay=nil
let cancelAt=ProcessInfo.processInfo.systemUptime+0.04
let start=ProcessInfo.processInfo.systemUptime
_ = RSDPortDiscovery.resolvePorts(timeout:6,isCancelled:{ProcessInfo.processInfo.systemUptime>=cancelAt})
check(ProcessInfo.processInfo.systemUptime-start < 0.5,"Discovery ignored cancellation")
check(NWBrowser.starts==2 && NWBrowser.cancels==2,"Cancelled browser leaked")
print("Connection deadline, lock cancellation, continuous discovery checks passed")
'''
with tempfile.TemporaryDirectory(prefix='aether-connection-') as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
