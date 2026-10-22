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
source="""import Foundation
struct App {var isSigned:Bool}
struct Operation {var installRequested:Bool;var signing:Bool?;var app:App}
enum Status {case signing,completed(Result<Void,Error>)}
struct InstallerStatusViewModel {var status:Status}
struct Entry {var operation:Operation?;var app:App?
"""+method+"""
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
print("Sign-only handoff checks passed: committed snapshot, model retirement, sign-and-install and re-signing")
"""
with tempfile.TemporaryDirectory(prefix='aether-sign-handoff-') as folder:
 p=Path(folder);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
