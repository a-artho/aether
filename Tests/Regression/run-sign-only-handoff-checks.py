#!/usr/bin/env python3
"""Exercise the production sign-only presentation gate during model retirement."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
text=(root/'Aether/Views/Library/UnifiedImportsSection.swift').read_text()
a=text.index('func signOnlyCompleted(');b=text.index('{',a)+1;n=1;end=b
while n:
 n+=(text[end]=='{')-(text[end]=='}');end+=1
method=text[a:end]
def extract(text,marker):
 a=text.index(marker);end=text.index('{',a)+1;n=1
 while n:
  n+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[a:end]
reconcile=extract(text,'func reconciled(')
cancel=extract((root/'Aether/Backend/Observable/AppInstallationManager.swift').read_text(),'func cancelRequest(')
source="""import Foundation
struct App {var isSigned:Bool}
struct Operation {let id=UUID();var installRequested:Bool;var signing:Bool?;var app:App}
enum AppInstallationManager {typealias InstallationRequest=Operation}
enum Status {case signing,completed(Result<Void,Error>)}
struct InstallerStatusViewModel {var status:Status}
struct Entry {var operation:Operation?;var app:App?
"""+method+"\n"+reconcile+"""
}
class Manager {
 var currentRequest:Operation?;var queuedInstalls:[Operation]=[];var activeCancels=0
 func cancel(){activeCancels+=1;currentRequest=nil}
 func cancelQueuedInstall(id:UUID){queuedInstalls.removeAll{$0.id==id}}
 CANCEL
}
let done=InstallerStatusViewModel(status:.completed(.success(())))
let signing=InstallerStatusViewModel(status:.signing)
let unsigned=App(isSigned:false),signed=App(isSigned:true)
var row=Entry(operation:.init(installRequested:false,signing:true,app:unsigned),app:unsigned)
precondition(!row.signOnlyCompleted(model:signing))
precondition(!row.signOnlyCompleted(model:done),"Do not expose Sign while waiting for the signed artifact")
row.operation = .init(installRequested:false,signing:nil,app:signed);row.app=signed
precondition(row.signOnlyCompleted(model:signing),"Committed artifact must finish sign-only presentation")
precondition(row.signOnlyCompleted(model:done))
precondition(row.signOnlyCompleted(model:nil),"Model retirement must not reintroduce a queued ring")
row.operation = .init(installRequested:true,signing:nil,app:signed)
precondition(!row.signOnlyCompleted(model:done),"Sign-and-install must keep continuous progress")
row.operation = .init(installRequested:false,signing:true,app:signed)
precondition(!row.signOnlyCompleted(model:signing),"Re-signing a signed app must still show progress")
let committed=Operation(installRequested:false,signing:nil,app:signed)
let retired=Entry(operation:committed,app:unsigned).reconciled(with:[])
precondition(retired.operation==nil && retired.app?.isSigned==true,"Retired sign-only request must not leave phantom Queued UI or lose its committed app")
let pending=Operation(installRequested:false,signing:true,app:unsigned)
let live=Entry(operation:pending,app:unsigned).reconciled(with:[pending])
precondition(live.operation?.id==pending.id,"A live queued job must remain visible")
let manager=Manager();manager.queuedInstalls=[pending]
// Simulate promotion after the menu opens but before Cancel is tapped.
manager.queuedInstalls=[];manager.currentRequest=pending
manager.cancelRequest(id:pending.id)
precondition(manager.activeCancels==1 && manager.currentRequest==nil,"Cancel must follow a queued job into active state")
manager.queuedInstalls=[pending];manager.cancelRequest(id:pending.id)
precondition(manager.queuedInstalls.isEmpty,"Cancel must still remove a queued job")
print("Sign-only handoff, retired-row reconciliation and live cancellation checks passed")
"""
with tempfile.TemporaryDirectory(prefix='aether-sign-handoff-') as folder:
 p=Path(folder);(p/'main.swift').write_text(source.replace('CANCEL',cancel))
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
