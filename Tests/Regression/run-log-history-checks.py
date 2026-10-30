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

# Exercise the production settings bridge and active-upload shutoff without
# UIKit or the native binary. Native tracing field/filter behavior is tested
# separately by build.sh's aether_logging_tests.
repo = p.parents[3]
def declaration(path, marker):
    source = (repo / path).read_text()
    start = source.index(marker)
    brace = source.index('{', start)
    end = brace + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

heartbeat = 'IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat.swift'
bridge = declaration(heartbeat, 'private final class LoggingState:')
bridge += '\nprivate static let loggingState = LoggingState()\n'
bridge += declaration(heartbeat, 'public static var isLoggingEnabled:')
bridge += '\n' + declaration(heartbeat, 'public static func setLoggingEnabled(')
setting = declaration('Aether/Backend/Observable/DebugLogManager.swift', '@Published public var isLoggingEnabled:').replace('@Published ', '')
disable = declaration('IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift', 'func stopDisabledDiagnostics()')
code = '''import Foundation
enum NativeProbe { static var changes: [Bool] = [] }
func idevice_set_logging_enabled(_ enabled: Bool) { NativeProbe.changes.append(enabled) }
final class HeartbeatManager {
''' + bridge + '''
}
final class Preferences {
 static let loggingEnabledKey = "aether-test-logging-" + UUID().uuidString
 var _inMemoryEntries: [String] = []
 var recorded: [String] = []
 enum Level { case info }
 func log(_ text: String, category: String, level: Level) { if isLoggingEnabled { recorded.append(text) } }
''' + setting + '''
 init() { isLoggingEnabled = false }
}
final class DiagnosticsProbe { var stopped = false; func stop() { stopped = true } }
@main struct Checks {
 static func main() {
  let preferences = Preferences()
  defer { UserDefaults.standard.removeObject(forKey: Preferences.loggingEnabledKey) }
  HeartbeatManager.setLoggingEnabled(false)
  precondition(!HeartbeatManager.isLoggingEnabled)
  preferences.isLoggingEnabled = true
  precondition(HeartbeatManager.isLoggingEnabled && NativeProbe.changes.last == true)
  precondition(UserDefaults.standard.bool(forKey: Preferences.loggingEnabledKey))
  let probe = DiagnosticsProbe()
  var activeDiagnostics: DiagnosticsProbe? = probe
''' + disable + '''
  stopDisabledDiagnostics()
  precondition(activeDiagnostics != nil && !probe.stopped)
  preferences.isLoggingEnabled = false
  precondition(!HeartbeatManager.isLoggingEnabled && NativeProbe.changes.last == false)
  precondition(!UserDefaults.standard.bool(forKey: Preferences.loggingEnabledKey))
  stopDisabledDiagnostics()
  precondition(activeDiagnostics == nil && probe.stopped)
  preferences.isLoggingEnabled = true
  stopDisabledDiagnostics()
  precondition(activeDiagnostics == nil, "Do not restart an incomplete diagnostic capture")
  preferences.isLoggingEnabled = false
  print("Logging-toggle checks passed: native gate follows settings; active upload profiling stops")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-logging-toggle-') as directory:
    swift = Path(directory) / 'Checks.swift'
    swift.write_text(code)
    executable = Path(directory) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
