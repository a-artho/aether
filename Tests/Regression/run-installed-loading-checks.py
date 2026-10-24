#!/usr/bin/env python3
"""Exercise confirmed-row publication, profile fallback and foreground refresh ownership."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
def declaration(path,start):
 s=(repo/path).read_text();begin=s.index(start);end=s.index('{',begin)+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[begin:end]
s='import Foundation\n'
s+=(repo/'IDeviceKitten/Sources/IDeviceSwift/Utilties/AnyCodable.swift').read_text()
s+=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/Models/AppInfo.swift').read_text()
s+=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/Models/AppInstallationProvenance.swift').read_text()
s+=r'''
public struct ProvisioningProfileInfo {
 func matches(bundleIdentifier:String,appTeamIdentifier:String?,appApplicationIdentifier:String?,now:Date) -> Bool {bundleIdentifier == "unknown"}
}
struct InstalledApp {
 let bundleIdentifier:String;let name:String;let version:String?;let build:String?;let appInfo:AppInfo?
 var id:String {bundleIdentifier}
 var iconCacheVersion:String {"\(version ?? "")|\(build ?? "")|\(InstallationAppProxy.iconCacheRevision(for:bundleIdentifier))"}
}
enum Level {case error, debug}
@MainActor final class DebugLogManager {static let shared=DebugLogManager();func log(_ s:String,category:String,level:Level?=nil) {}}
@MainActor final class DeviceConnectionManager {static let shared=DeviceConnectionManager();var isConnected=true}
@MainActor final class InstallationAppProxy {
 static var failProfiles=false;static var fetches=0;static var profileFetches=0;static var profileWaiter:CheckedContinuation<[ProvisioningProfileInfo],Never>?
 static var result:[AppInfo]=[]
 func fetchApps(applicationType:String?,lightweight:Bool) async throws -> [AppInfo] {Self.fetches+=1;return Self.result}
 func provisioningProfiles() async throws -> [ProvisioningProfileInfo] {Self.profileFetches+=1;if Self.failProfiles {throw NSError(domain:"Test",code:1)};let result = await withCheckedContinuation {Self.profileWaiter=$0};if Self.failProfiles {throw NSError(domain:"Late profile failure",code:2)};return result}
 static func getAppIconCached(for id:String,cacheVersion:String?) async throws -> String? {nil}
 nonisolated static func iconCacheRevision(for id:String)->String {""}
}
@MainActor final class Store {
 var apps:[InstalledApp]=[];var hasLoadedApps=false;var lastLoadedAt:Date?;var verifiedApps:[AppInfo]?
 var initialBrowse:Task<[AppInfo]?,Never>?
 var needsTrailingRefresh=false;var refreshGeneration=UUID();var iconPrefetchTask:Task<Void,Never>?
 var isLoading=false;var errorMessage:String?
'''
for start in ['func stageInitialBrowse(', 'func stageVerifiedApps(', 'func load()', 'func refreshOnForeground()', 'func clear()', 'func invalidateConnection()', 'func refresh(force:', 'private func prefetchFirstScreenIcons()', 'private func updateApplications(']:
 s+=declaration('Aether/Views/Installed/InstalledAppsStore.swift',start)+'\n'
s+='}\n'
s+='@MainActor struct LoadingPresentation { let store:Store;let connection=DeviceConnectionManager.shared\n'+declaration('Aether/Views/Library/LibraryView.swift','private var isLoadingInstalledApps:').replace('private var','var',1)+'\n}\n'
s+=r'''
func check(_ value:@autoclosure ()->Bool,_ label:String){precondition(value(),label)}
@main struct Checks {
 @MainActor static func main() async throws {
  let initial=Store()
  check(LoadingPresentation(store:initial).isLoadingInstalledApps,"A connected device waits for its first list load instead of showing empty")
  initial.hasLoadedApps=true
  check(!LoadingPresentation(store:initial).isLoadingInstalledApps,"A verified empty list can show its genuine empty state")
  initial.hasLoadedApps=false;initial.errorMessage="failure"
  check(!LoadingPresentation(store:initial).isLoadingInstalledApps,"A real load failure is not hidden behind loading")
  let known=AppInfo(SignerIdentity:"Developer",CFBundleIdentifier:"known")
  let unknown=AppInfo(Entitlements:["com.apple.developer.team-identifier":AnyCodable("TEAM")],CFBundleIdentifier:"unknown")
  let store=Store();InstallationAppProxy.result=[known,unknown]
  store.stageInitialBrowse(Task { [known,unknown] })
  let load=Task {await store.load()}
  while InstallationAppProxy.profileWaiter == nil {await Task.yield()}
  check(store.apps.map(\.id)==["known"],"Confirmed row published before profile fallback")
  check(InstallationAppProxy.fetches==0,"Verified initial browse avoids a second fetch")
  InstallationAppProxy.profileWaiter?.resume(returning:[ProvisioningProfileInfo()]);InstallationAppProxy.profileWaiter=nil
  await load.value
  check(Set(store.apps.map(\.id))==Set(["known","unknown"]),"Fallback adds only profile-confirmed app")
  InstallationAppProxy.failProfiles=true
  await store.refresh(force:true)
  check(Set(store.apps.map(\.id))==Set(["known","unknown"]) && store.errorMessage != nil,"Profile failure preserves existing confirmed apps and reports error")
  InstallationAppProxy.failProfiles=false;InstallationAppProxy.fetches=0
  await store.refreshOnForeground()
  check(InstallationAppProxy.fetches==0,"Recent foreground return doesn't reload apps")
  InstallationAppProxy.result=[known]
  await store.refresh(force:true)
  check(InstallationAppProxy.fetches==1 && store.apps.map(\.id)==["known"],"Explicit refresh remains authoritative")
  store.lastLoadedAt=Date(timeIntervalSinceNow:-61)
  await store.refreshOnForeground()
  check(InstallationAppProxy.fetches==2,"Stale foreground list refreshed")
  DeviceConnectionManager.shared.isConnected=false
  await store.refresh()
  check(store.apps.map(\.id)==["known"] && !store.hasLoadedApps && !store.isLoading,"Idle disconnect retains the last verified apps without pretending they are fresh")
  DeviceConnectionManager.shared.isConnected=true
  InstallationAppProxy.result=[known,unknown]
  let stale=Task {await store.refresh()}
  while InstallationAppProxy.profileWaiter == nil {await Task.yield()}
  store.invalidateConnection()
  check(store.apps.map(\.id)==["known"] && !store.hasLoadedApps && !store.isLoading,"Background invalidation hides freshness before the asynchronous VPN stop")
  InstallationAppProxy.failProfiles=true
  InstallationAppProxy.profileWaiter?.resume(returning:[ProvisioningProfileInfo()]);InstallationAppProxy.profileWaiter=nil
  await stale.value
  check(store.errorMessage == nil,"An invalidated profile failure cannot publish into the current session")
  InstallationAppProxy.failProfiles=false
  check(store.apps.map(\.id)==["known"] && !store.hasLoadedApps && !store.isLoading,"An old browse cannot publish after invalidation even if Connected has not changed yet")
  store.clear();DeviceConnectionManager.shared.isConnected=false
  check(store.apps.isEmpty,"Explicit reset still clears retained apps")
  DeviceConnectionManager.shared.isConnected=true
  InstallationAppProxy.result=[]
  await store.refresh(force:true)
  check(store.apps.isEmpty && store.hasLoadedApps,"A successful empty browse is authoritative")
  print("Installed loading/foreground checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-installed-loading-') as directory:
 root=pathlib.Path(directory);(root/'Checks.swift').write_text(s)
 subprocess.run(['swiftc','-parse-as-library',str(root/'Checks.swift'),'-o',str(root/'checks')],check=True)
 subprocess.run([str(root/'checks')],check=True)
