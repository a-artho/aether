"""Exercise production automatic refresh ownership and timestamp commits."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
src=(repo/'Aether/Views/Sources/SourcesViewModel.swift').read_text()
def method(start):
 a=src.index(start);b=src.index('{',a)+1;depth=1
 while depth:
  depth+=(src[b]=='{')-(src[b]=='}');b+=1
 return src[a:b]
s=r'''
import Foundation
import Combine
struct ObjectID {let id:String;func uriRepresentation()->URL {URL(string:"source://"+id)!}}
struct AltSource {let objectID=ObjectID(id:"one");let sourceURL=URL(string:"https://test.invalid/repo.json")}
final class Defaults {var date:Date?;func set(_ date:Date?,forKey:String){self.date=date}}
@MainActor final class Driver {
 @Published var isFinished=true
 var isRefreshRequested=false;var requestedRefreshTask:Task<Void,Never>?
 var _lastGlobalAttempt:Date?;var lastUpdated:Date?
 static let _lastUpdatedKey="test"
 let _defaults=Defaults();var cacheResetGeneration=UUID()
 var sources:[String:Int]=[:];var _revisions:[String:String]=[:];var refreshErrors:[String:String]=[:];var catalogRevision=0
 struct SourceRequest:Sendable {let key:String;let sourceURL:URL?}
 var fetches=0;var shouldFail=false;var pending:CheckedContinuation<Void,Never>?
 func _fetchRequests(_ requests:[SourceRequest],refresh:Bool,batchSize:Int) async {
  fetches+=1
  await withCheckedContinuation {pending=$0}
  guard !Task.isCancelled else {return}
  for request in requests {
   if shouldFail {refreshErrors[request.key]="failure"}
   else {sources[request.key]=1;refreshErrors[request.key]=nil}
  }
 }
 func ensureSourcesLoaded(_ sources:[AltSource]) async {}
 func finish(){pending?.resume();pending=nil}
'''
for start in ['func startRefresh(', 'func refreshIfNeeded(', 'func fetchSources(_ sources: [AltSource],']:
 s+=method(start)+'\n'
s+=r'''
}
@main struct Checks {
 @MainActor static func main() async {
  let driver=Driver(),old=Date(timeIntervalSinceNow:-1200)
  driver.lastUpdated=old
  let page=Task {await driver.refreshIfNeeded([AltSource()])}
  while driver.pending == nil {await Task.yield()}
  let owner=driver.requestedRefreshTask!
  page.cancel() // Tab switch / scene phase changes cancel the page, not the shared refresh.
  driver.finish();await page.value;await owner.value
  precondition(driver.fetches==1 && !driver.sources.isEmpty)
  precondition(driver.lastUpdated! > old && driver._defaults.date==driver.lastUpdated)
  precondition(!driver.isRefreshRequested && driver.isFinished)
  let checked=driver.lastUpdated
  await driver.refreshIfNeeded([AltSource()])
  precondition(driver.fetches==1 && driver.lastUpdated==checked,"Fresh cache reads do not claim a new refresh")
  await driver.refreshIfNeeded([AltSource()],now:driver._lastGlobalAttempt!.addingTimeInterval(119))
  precondition(driver.fetches==1,"Automatic refresh must wait two full minutes")
  let failing=Task {await driver.refreshIfNeeded([AltSource()],now:driver._lastGlobalAttempt!.addingTimeInterval(120))}
  while driver.pending == nil {await Task.yield()}
  driver.shouldFail=true;driver.finish();await failing.value
  precondition(driver.lastUpdated==checked && !driver.refreshErrors.isEmpty,"Incomplete refresh retains last successful timestamp")
  let restored=Driver();restored.lastUpdated=Date()
  await restored.refreshIfNeeded([AltSource()])
  precondition(restored.fetches==0,"A recent persisted refresh survives cold launch")
  let forced=Task {await restored.startRefresh([AltSource()]).value}
  while restored.pending == nil {await Task.yield()}
  precondition(restored.fetches==1,"Manual refresh ignores the two-minute gate")
  restored.finish();await forced.value
  let joined=Driver()
  let automatic=Task {await joined.refreshIfNeeded([AltSource()])}
  while joined.pending == nil {await Task.yield()}
  let manual=joined.startRefresh([AltSource()])
  precondition(joined.fetches==1,"Manual refresh joins the automatic refresh")
  joined.finish();await manual.value;await automatic.value
  precondition(joined.lastUpdated != nil && joined.fetches==1)
  print("Automatic refresh checks passed: page cancellation, persisted timestamp, cache age, failures and manual deduplication")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-auto-refresh-') as d:
 p=Path(d);(p/'Checks.swift').write_text(s)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
