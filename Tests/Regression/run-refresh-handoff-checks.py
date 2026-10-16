"""Exercise the production refresh owner independently of SwiftUI pull controls."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
text = (repo/'Aether/Views/Sources/SourcesViewModel.swift').read_text()
a = text.index('func startRefresh('); b = text.index('{', a)+1; depth = 1
while depth:
    depth += (text[b] == '{') - (text[b] == '}'); b += 1
method = text[a:b]
source = r'''
import Foundation
import Combine
struct AltSource {}
@MainActor final class Driver {
 @Published var isFinished = true
 var isRefreshRequested = false
 var requestedRefreshTask: Task<Void,Never>?
 var _lastGlobalAttempt: Date?
 var fetches = 0
 var pending: CheckedContinuation<Void,Never>?
 func fetchSources(_ sources:[AltSource], refresh:Bool) async {
  fetches += 1; isFinished = false
  await withCheckedContinuation { pending = $0 }
  _lastGlobalAttempt = Date(); isFinished = true
 }
 func finish() { pending?.resume(); pending = nil }
 METHOD
}
@main struct Checks {
 @MainActor static func main() async {
  let driver = Driver()
  let first = driver.startRefresh([AltSource()])
  let second = driver.startRefresh([AltSource()])
  precondition(driver.isRefreshRequested)
  while driver.pending == nil { await Task.yield() }
  precondition(driver.fetches == 1, "Pulls from both tabs must share one refresh")
  driver.finish(); await first.value; await second.value
  precondition(!driver.isRefreshRequested && driver.requestedRefreshTask == nil)
  let again = driver.startRefresh([AltSource()])
  while driver.pending == nil { await Task.yield() }
  precondition(driver.fetches == 2, "A later pull starts a fresh check")
  driver.finish(); await again.value
  let joined = Driver(); joined.isFinished = false
  let request = joined.startRefresh([AltSource()])
  for _ in 0..<20 { await Task.yield() }
  joined._lastGlobalAttempt = Date(); joined.isFinished = true
  await request.value
  precondition(joined.fetches == 0, "An existing global refresh is joined, not repeated")
  print("Refresh handoff checks passed: immediate ownership, cross-tab deduplication, later refresh and joining active global work")
 }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='aether-refresh-handoff-') as d:
    p = pathlib.Path(d); (p/'Checks.swift').write_text(source)
    subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)
