#!/usr/bin/env python3
"""Focused runtime regressions using production cache/search/icon methods on macOS."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
def declaration(path, start):
    source = (repo/path).read_text(); begin = source.index(start)
    brace = source.index(') throws -> [Entry] {', begin) + len(') throws -> [Entry] ') if start == 'static func entries(' else source.index('{', begin)
    end = brace+1; depth = 1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end += 1
    return source[begin:end]
source = 'import Foundation\nimport Darwin\nimport CryptoKit\nimport Combine\n'
source += declaration('Aether/Views/Sources/Apps/Detail/ExpandableText.swift', 'enum SourceAppBodyText') + '\n'
source += (repo/'AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift').read_text().replace('import SwiftUI','public struct Color: Codable, Hashable, Sendable {}')
source += (repo/'AltSourceKit/Sources/AltSourceKit/Extensions/Array/Array+safe.swift').read_text()
source += (repo/'AltSourceKit/Sources/AltSourceKit/Utilities/ASDecrypt.swift').read_text()
source += (repo/'AltSourceKit/Sources/AltSourceKit/Utilities/Key/EsignSourceKey.swift').read_text()
for path in ['Aether/Backend/Observable/SourceRepositoryService.swift','Aether/Backend/Observable/SourceAppListStore.swift']:
    source += (repo/path).read_text().replace('import AltSourceKit','')
source += (repo/'Aether/Backend/Observable/InstalledAppUpdateCatalog.swift').read_text().replace('import AltSourceKit','')
source += r'''
enum FRIconAppearance: Int { case light, dark }
final class UIImage: @unchecked Sendable { let id: String; init(_ id: String) {self.id=id} }
final class FRIconCache { static let shared = FRIconCache(); var images: [String:UIImage]=[:]
 func image(for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1) -> UIImage? {images[url.path]}
 func insert(_ image: UIImage, for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1) {images[url.path]=image}
}
func iconTest(_ url: URL, _ scale: CGFloat, _ style: Int) -> UIImage? { Thread.sleep(forTimeInterval: 0.08); return url.path == "/missing" ? nil : UIImage(url.path) }
'''
source += declaration('Aether/Views/Common/FRAppIconView.swift','private actor FRIconRenderGate')+'\n'
source += declaration('Aether/Views/Common/FRAppIconView.swift','private actor FRIconRequests')+'\n'
source += '@MainActor\n'+declaration('Aether/Views/Common/FRAppIconView.swift','final class FRAppIconLoader')+'\n'
source += r'''
final class ImportFiles {
 var mutateAfterCopy=false
 func removeFileIfNeeded(at url:URL) throws {if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}}
 func createDirectoryIfNeeded(at url:URL) throws {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
 func copyItemPreferClone(at source:URL,to destination:URL) throws {
  try FileManager.default.copyItem(at:source,to:destination)
  if mutateAfterCopy {try Data("changed input".utf8).write(to:source)}
 }
}
final class ImportProbe {
 let _fileManager=ImportFiles();var _ipa:URL;let _uniqueWorkDir:URL;var _archiveInspection:Int?;var inspections=0
 init(_ input:URL,_ work:URL) {_ipa=input;_uniqueWorkDir=work}
 func _inspectArchiveIfNeeded() throws {if _archiveInspection == nil {inspections+=1;_archiveInspection=try Data(contentsOf:_ipa).count}}
 func _checkAvailableDiskSpace() throws {}
'''
source += declaration('Aether/Utilities/Handlers/AppFileHandler.swift','func prepare(copySource:')+'\n}\n'
source += r'''
final class CatalogProtocol: URLProtocol, @unchecked Sendable {
 private let lock = NSLock(); private var stopped = false
 override class func canInit(with request: URLRequest) -> Bool {true}
 override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
 override func stopLoading() {lock.lock(); stopped = true; lock.unlock()}
 override func startLoading() {
  DispatchQueue.global().asyncAfter(deadline:.now()+0.05) { [self] in
   lock.lock(); defer {lock.unlock()}; guard !stopped else {return}
   let json = Data(#"{"name":"Source","apps":[{"name":"Café App","bundleIdentifier":"fixture.app","version":"1.0","downloadURL":"https://fixture.test/app.ipa","description":"Unique needle"}]}"#.utf8)
   let response = HTTPURLResponse(url: request.url!,statusCode:200,httpVersion:nil,headerFields:["ETag":"\"fixture\""])!
   client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
   client?.urlProtocol(self,didLoad:json); client?.urlProtocolDidFinishLoading(self)
  }
 }
}
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
@main struct Checks {
 @MainActor static func main() async throws {
  let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? fm.removeItem(at:root)}
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let input=root.appendingPathComponent("Input.ipa")
  try Data("input".utf8).write(to:input)
  let importProbe=ImportProbe(input,root.appendingPathComponent("import"))
  try await importProbe.prepare(copySource:true)
  check(importProbe.inspections==1,"Unchanged staged IPA inspected only once")
  let changingProbe=ImportProbe(input,root.appendingPathComponent("changing-import"))
  changingProbe._fileManager.mutateAfterCopy=true
  try await changingProbe.prepare(copySource:true)
  check(changingProbe.inspections==2 && changingProbe._archiveInspection==5,"Input mutation triggers staged archive reinspection")
  let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[CatalogProtocol.self]
  let service=SourceRepositoryService(session:URLSession(configuration:config),cacheDirectory:root.appendingPathComponent("catalogs"))
  let url=URL(string:"https://fixture.test/source")!
  let snapshot=try await service.fetch(from:url)
  check(snapshot.repository.apps.count == 1,"Valid catalog loads")
  await service.remove(url)
  let removed=await service.cached(for:url)
  check(removed == nil,"Deletion evicts disk and memory")
  let flight=Task {try await service.fetch(from:url,refresh:true)}
  try await Task.sleep(nanoseconds:10_000_000)
  await service.remove(url)
  _=try? await flight.value
  let afterFlight=await service.cached(for:url)
  check(afterFlight == nil,"Deleted source cannot be restored by in-flight fetch")
  _ = try await service.fetch(from:url,refresh:true)
  await service.clearCache()
  let resetCached = await service.cached(for:url)
  check(resetCached == nil,"Network reset clears repository memory and disk")
  let resetFlight=Task {try await service.fetch(from:url,refresh:true)}
  try await Task.sleep(nanoseconds:10_000_000)
  await service.clearCache()
  _=try? await resetFlight.value
  let resetFlightCached = await service.cached(for:url)
  check(resetFlightCached == nil,"Old fetch cannot restore a reset repository cache")
  let listStore=SourceAppListStore(cacheDirectory:nil)
  let context=SourceAppCatalogContext(sourceObjectURI:"source-key",sourceURL:url,repository:snapshot.repository,revision:snapshot.revision)
  let list=try await listStore.list(contexts:[context],sort:"name",ascending:true,query:"NEEDLE",unknownDate:"Unknown")
  check(list.rows.count == 1,"Description search retained")
  let sameCatalog=try await listStore.list(contexts:[context],sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  check(sameCatalog.changedRows(comparedTo:list).isEmpty,"Search and sorting preserve unchanged row content")
  var edited=snapshot.repository
  edited.apps[0].description="Updated description"
  let editedContext=SourceAppCatalogContext(sourceObjectURI:"source-key",sourceURL:url,repository:edited,revision:"edited-1")
  let editedList=try await listStore.list(contexts:[editedContext],sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  check(editedList.changedRows(comparedTo:sameCatalog).count==1,"Catalog refresh still detects changed descriptions")
  var renamed=edited
  renamed.name="Renamed source"
  let renamedContext=SourceAppCatalogContext(sourceObjectURI:"source-key",sourceURL:url,repository:renamed,revision:"renamed-1")
  let renamedList=try await listStore.list(contexts:[renamedContext],sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  check(renamedList.changedRows(comparedTo:editedList).count==1,"Shared source fingerprint still invalidates affected rows")
  let indexDirectory=root.appendingPathComponent("indexes")
  let diskListStore=SourceAppListStore(cacheDirectory:indexDirectory)
  _=try await diskListStore.list(contexts:[context],sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  await diskListStore.clearCache()
  try await Task.sleep(nanoseconds:30_000_000)
  check(!fm.fileExists(atPath:indexDirectory.path),"Queued index writes cannot restore a reset disk cache")

  check(list.rows.values.allSatisfy { $0.source.apps.isEmpty && $0.source.news == nil },"Rows retain repository metadata without app catalogs")
  check(SourceAppBodyText.subtitle(in:"Hello 😀 😃 · World",followingVersion:false)=="Hello · World","Emoji/separator runs remain collapsed after caching")
  check(SourceAppBodyText.body(in:"😀 😃") == nil,"Emoji-only bodies remain hidden")
  let updates=InstalledAppUpdateCatalog()
  let before=try await updates.updates(installedVersions:["fixture.app":"0.9"],contexts:[context])
  check(before.count==1 && before["fixture.app"]?.count==1,"One installed-app key regardless of candidate count")
  let equal=try await updates.updates(installedVersions:["fixture.app":"1.0.0"],contexts:[context])
  check(equal.isEmpty,"Equal normalized versions do not show an update row")
  let variantsJSON = Data(#"{"name":"Variants","apps":[{"bundleIdentifier":"fixture.app","version":"1.2","versionDate":"2026-10-14","downloadURL":"https://fixture.test/variant-a.ipa"},{"bundleIdentifier":"fixture.app","version":"1.3","versionDate":"2026-10-14","downloadURL":"https://fixture.test/variant-b.ipa"},{"bundleIdentifier":"other.app","version":"90.0","downloadURL":"https://fixture.test/wrong.ipa"}]}"#.utf8)
  let variants=try JSONDecoder().decode(ASRepository.self,from:variantsJSON)
  let variantContext=SourceAppCatalogContext(sourceObjectURI:"variants-key",sourceURL:url,repository:variants,revision:"variants-1")
  let all=try await updates.updates(installedVersions:["fixture.app":"0.9"],contexts:[context,variantContext])
  check(all.count==1 && all["fixture.app"]?.flatMap { $0.repository.apps }.count==3,"All variants across sources share one installed-app row")
  let urls=Set(all["fixture.app"]!.flatMap { $0.repository.apps }.compactMap { $0.currentDownloadUrl?.lastPathComponent })
  check(urls.contains("variant-a.ipa") && urls.contains("variant-b.ipa") && !urls.contains("wrong.ipa"),"Unnamed variants preserve exact bundle matching and download URLs")
  let scoped=SourceAppListStore(cacheDirectory:nil)
  let grouped=try await scoped.list(contexts:all["fixture.app"]!,sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  check(grouped.rows.count==3 && grouped.sections.contains { $0.date != nil && $0.rows.count==2 },"Update candidates use repository date grouping")
  let installed=try await updates.updates(installedVersions:["fixture.app":"1.3"],contexts:[context,variantContext])
  check(installed.isEmpty,"Completed upgrade removes the installed app from Updates")
  check(!InstalledAppUpdateCatalog.isNewer("1.2",than:nil) && !InstalledAppUpdateCatalog.isNewer("v1.2",than:"1.0"),"Unknown and unstructured versions are skipped")
  let suffixJSON = Data(#"{"name":"Suffix variants","apps":[{"bundleIdentifier":"com.google.ios.youtube","version":"21.42.4","downloadURL":"https://fixture.test/base.ipa"},{"bundleIdentifier":"com.google.ios.youtube.youmod","version":"21.42.4","downloadURL":"https://fixture.test/youmod.ipa"},{"bundleIdentifier":"com.google.ios.youtube.ytplus.21-42-4","version":"21.42.4","downloadURL":"https://fixture.test/ytplus.ipa"},{"bundleIdentifier":"com.google.ios.youtubemusic","version":"99.0","downloadURL":"https://fixture.test/music.ipa"},{"bundleIdentifier":"com.google.ios.youtube.old","version":"21.40.0","downloadURL":"https://fixture.test/old.ipa"}]}"#.utf8)
  let suffixRepo=try JSONDecoder().decode(ASRepository.self,from:suffixJSON)
  let suffixContext=SourceAppCatalogContext(sourceObjectURI:"suffix-key",sourceURL:url,repository:suffixRepo,revision:"suffix-1")
  let suffixMatches=try await updates.updates(installedVersions:["com.google.ios.youtube":"21.40.0"],contexts:[suffixContext])
  let suffixApps=suffixMatches["com.google.ios.youtube"]!.flatMap { $0.repository.apps }
  check(Set(suffixApps.compactMap { $0.currentDownloadUrl?.lastPathComponent }) == Set(["base.ipa","youmod.ipa","ytplus.ipa"]),"Dot-suffixed newer variants match; neighboring IDs and equal versions do not")
  let suffixList=try await scoped.list(contexts:suffixMatches["com.google.ios.youtube"]!,sort:"latest",ascending:false,query:"",unknownDate:"Unknown")
  check(suffixList.rows.count==3,"Each variant retains its own repository row")
  let separateInstalled=try await updates.updates(installedVersions:["com.google.ios.youtube":"21.40.0","com.google.ios.youtube.youmod":"21.42.4"],contexts:[suffixContext])
  check(separateInstalled["com.google.ios.youtube"] != nil && separateInstalled["com.google.ios.youtube.youmod"] == nil,"Each installed app uses its own version comparison")
  await updates.removeSource("source-key")
  let after=try await updates.updates(installedVersions:["fixture.app":"0.9"],contexts:[context])
  check(after.isEmpty,"Deleted-source stale context cannot restore update candidates")
  let original=try await listStore.list(contexts:[context],sort:"default",ascending:false,query:"",unknownDate:"Unknown")
  check(original.sections.count == 1 && original.sections[0].title.isEmpty,"Default order has no date/alphabet headers")
  check(original.sections[0].rows.compactMap { original.rows[$0]?.app.id } == context.repository.apps.compactMap(\.id),"Default order preserves the source array")
  let accent=try await listStore.list(contexts:[context],sort:"name",ascending:true,query:"café",unknownDate:"Unknown")
  check(accent.rows.count == 1,"Localized name search retained")
  await listStore.removeSource("source-key")
  let stale=try await listStore.list(contexts:[context],sort:"name",ascending:true,query:"",unknownDate:"Unknown")
  check(stale.rows.isEmpty,"Stale UI context cannot repopulate deleted projections")
  let loader=FRAppIconLoader(), old=URL(fileURLWithPath:"/old"), fresh=URL(fileURLWithPath:"/fresh")
  FRIconCache.shared.images[fresh.path]=UIImage("fresh")
  loader.load(bundleURL:old,appearance:.light,tint:"",isTinted:false,dynamic:false)
  try await Task.sleep(nanoseconds:10_000_000)
  loader.load(bundleURL:fresh,appearance:.dark,tint:"",isTinted:false,dynamic:false)
  try await Task.sleep(nanoseconds:150_000_000)
  check(loader.image?.id == "fresh","Old renderer cannot overwrite newer cached icon")
  check(!loader.isLoading,"Cached icon must not keep loading skeleton active")
  let missing=FRAppIconLoader()
  missing.load(bundleURL:URL(fileURLWithPath:"/missing"),appearance:.light,tint:"",isTinted:false,dynamic:false)
  check(missing.isLoading,"Uncached icon should expose loading state")
  try await Task.sleep(nanoseconds:150_000_000)
  check(!missing.isLoading && missing.image == nil,"Failed render must stop loading animation")
  missing.load(bundleURL:old,appearance:.light,tint:"new-key",isTinted:false,dynamic:false)
  missing.cancel()
  check(!missing.isLoading,"Offscreen cancellation must stop loading animation")
  let sharedURL=URL(fileURLWithPath:"/shared-render")
  let one=FRAppIconLoader(), two=FRAppIconLoader()
  one.load(bundleURL:sharedURL,appearance:.light,tint:"shared",isTinted:false,dynamic:false)
  two.load(bundleURL:sharedURL,appearance:.light,tint:"shared",isTinted:false,dynamic:false)
  try await Task.sleep(nanoseconds:20_000_000)
  one.cancel()
  try await Task.sleep(nanoseconds:250_000_000)
  check(two.image?.id==sharedURL.path,"Cancelling one icon consumer preserves another consumer")
  check(FRIconCache.shared.images[sharedURL.path] != nil,"Shared render caches its result")
  print("Efficiency cache/search/icon checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-efficiency-checks-') as directory:
    root=pathlib.Path(directory); (root/'Checks.swift').write_text(source)
    subprocess.run(['swiftc','-parse-as-library',str(root/'Checks.swift'),'-o',str(root/'checks')],check=True)
    subprocess.run([str(root/'checks')],check=True)
