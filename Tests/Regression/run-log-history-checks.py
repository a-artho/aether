from pathlib import Path
import subprocess,tempfile
p=Path(__file__).resolve().parents[2]/'Aether/Backend/Observable/DebugLogManager.swift'
s=p.read_text();start=s.index('\tpublic func fetchLogs(');end=s.index('\n\t// MARK: - Filtered Views',start);fn=s[start:end]
a=fn.index('\t\tlet fetched = await Task.detached');b=fn.index('\n\t\t// Combine fetched',a)
fn=fn[:a]+'\t\tlet fetched: [DebugLogItem] = await historyProvider()\n\t\tguard generation == _historyGeneration, !Task.isCancelled else { return }\n\t\tlet memoryItems = _lock.withLock { _inMemoryEntries }\n'+fn[b:]
code='''import Foundation
struct DebugLogItem {enum Source:String {case diagnostics,appActivity};let id=UUID();let date=Date();let source:Source;let category="Test";let message:String}
@MainActor final class Logs {
 var isLoading=false;var _inMemoryEntries:[DebugLogItem]=[];var entries:[DebugLogItem]=[];let _lock=NSLock();let _maxPublishedCount=5000;var _historyGeneration=UUID();let _maxInMemoryCount=1000;var _publishedEntryIDs=Set<UUID>();var lastFetchDate:Date?
 func historyProvider() async -> [DebugLogItem] {try? await Task.sleep(for:.milliseconds(50));return []}
'''+fn+'''
}
@main struct Checks {@MainActor static func main() async {
 let logs=Logs();let before=DebugLogItem(source:.diagnostics,message:"before");logs._inMemoryEntries=[before];logs.entries=[before]
 let task=Task {await logs.fetchLogs()};while !logs.isLoading {await Task.yield()}
 let during=DebugLogItem(source:.diagnostics,message:"during");logs._inMemoryEntries.append(during);logs.entries.insert(during,at:0)
 await task.value
 precondition(logs._inMemoryEntries.count==2 && logs.entries.count==2)
 let clearing=Task {await logs.fetchLogs()};while !logs.isLoading {await Task.yield()}
 logs._historyGeneration=UUID();logs._inMemoryEntries=[];logs.entries=[]
 await clearing.value;precondition(logs.entries.isEmpty)
 print("Log-history checks passed: live arrivals retained and cleared history cannot reappear")
}}
'''
with tempfile.TemporaryDirectory(prefix='aether-log-audit-') as d:
 f=Path(d)/'Checks.swift';f.write_text(code);bin=Path(d)/'checks'
 subprocess.run(['swiftc','-parse-as-library',str(f),'-o',str(bin)],check=True);subprocess.run([str(bin)],check=True)
