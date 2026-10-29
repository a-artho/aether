#!/usr/bin/env python3
"""Run the production Library download index against a real in-memory Core Data store."""
from pathlib import Path
import subprocess, tempfile
repo = Path(__file__).resolve().parents[2]
production = (repo/'Aether/Backend/Observable/SourceLibraryDownloads.swift').read_text().replace('import UIKit','').replace('private ', '')
metadata = (repo/'Aether/Backend/Storage/Storage+SourceMetadata.swift').read_text()
provenance = metadata[metadata.index('struct SourceAppProvenance:'):metadata.index('extension SourceAppProvenance {')]
stubs = r'''
import Foundation
import CoreData
import Combine
import SwiftUI
@MainActor enum UIApplication {static let willEnterForegroundNotification=Notification.Name("testForeground")}
enum DebugLogItem {enum Level {case error}}
@MainActor final class DebugLogManager {static let shared=DebugLogManager();func log(_ s:String,category:String,level:DebugLogItem.Level){}}
protocol AppInfoPresentable {var uuid:String? {get};var isSigned:Bool {get}}
@objc(Imported) final class Imported:NSManagedObject,AppInfoPresentable {
 var isSigned:Bool {false}
 @NSManaged var uuid:String?
 @nonobjc class func fetchRequest()->NSFetchRequest<Imported>{NSFetchRequest(entityName:"Imported")}
}
@objc(Signed) final class Signed:NSManagedObject,AppInfoPresentable {
 var isSigned:Bool {true}
 @NSManaged var uuid:String?
 @nonobjc class func fetchRequest()->NSFetchRequest<Signed>{NSFetchRequest(entityName:"Signed")}
}
@objc(AppSourceMetadata) final class AppSourceMetadata:NSManagedObject {
 @NSManaged var appUUID:String?;@NSManaged var appKind:String?
 @NSManaged var sourceRepositoryURL:URL?;@NSManaged var sourceAppIdentifier:String?
 @NSManaged var sourceAppVersion:String?;@NSManaged var sourceAppDownloadURL:URL?
 @nonobjc class func fetchRequest()->NSFetchRequest<AppSourceMetadata>{NSFetchRequest(entityName:"AppSourceMetadata")}
}
extension FileManager {
 func unsigned(_ uuid:String)->URL {URL(fileURLWithPath:"/test/Imported:"+uuid)}
 func signed(_ uuid:String)->URL {URL(fileURLWithPath:"/test/Signed:"+uuid)}
}
final class FileProbe:@unchecked Sendable {
 private let condition=NSCondition()
 private var files:Set<String>=[]
 private var checks=0
 private var hold=false;private var entered=false;private var released=false
 var count:Int {condition.lock();defer{condition.unlock()};return checks}
 var isBlocked:Bool {condition.lock();defer{condition.unlock()};return entered}
 func all()->Set<String> {condition.lock();defer{condition.unlock()};return files}
 func set(_ values:Set<String>){condition.lock();files=values;condition.unlock()}
 func holdNext(){condition.lock();hold=true;entered=false;released=false;condition.unlock()}
 func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
 func validate(_ directory:URL)->Bool {
  precondition(!Thread.isMainThread,"Filesystem validation must not run on the UI thread")
  condition.lock();defer{condition.unlock()};checks+=1
  let present=files.contains(directory.lastPathComponent)
  if hold {hold=false;entered=true;while !released {condition.wait()}}
  return present
 }
}
@MainActor final class Storage {
 static let shared=Storage()
 let context:NSManagedObjectContext
 let fileProbe=FileProbe()
 var files:Set<String> {get{fileProbe.all()} set{fileProbe.set(newValue)}}
 init(){
  let model=NSManagedObjectModel()
  func entity(_ name:String,_ properties:[String:NSAttributeType])->NSEntityDescription {
   let e=NSEntityDescription();e.name=name;e.managedObjectClassName=name
   e.properties=properties.map {key,type in let a=NSAttributeDescription();a.name=key;a.attributeType=type;a.isOptional=true;return a}
   return e
  }
  model.entities=[entity("Imported",["uuid":.stringAttributeType]),entity("Signed",["uuid":.stringAttributeType]),
   entity("AppSourceMetadata",["appUUID":.stringAttributeType,"appKind":.stringAttributeType,
    "sourceRepositoryURL":.URIAttributeType,"sourceAppIdentifier":.stringAttributeType,
    "sourceAppVersion":.stringAttributeType,"sourceAppDownloadURL":.URIAttributeType])]
  let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
  try! coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil,options:nil)
  context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
 }
 func getUuidDirectory(for app:AppInfoPresentable)->URL? {
  guard let uuid=app.uuid else{return nil}
  return app.isSigned ? FileManager.default.signed(uuid) : FileManager.default.unsigned(uuid)
 }
 func sourceMetadata(for uuid:String)->AppSourceMetadata? {
  let request=AppSourceMetadata.fetchRequest();request.predicate=NSPredicate(format:"appUUID == %@",uuid)
  return try? context.fetch(request).first
 }
 func add(_ uuid:String,kind:String,provenance:SourceAppProvenance,hasFile:Bool=true)->any AppInfoPresentable {
  let name=kind == "imported" ? "Imported":"Signed"
  let app=NSEntityDescription.insertNewObject(forEntityName:name,into:context);app.setValue(uuid,forKey:"uuid")
  if hasFile {files.insert(name+":"+uuid)}
  let record=AppSourceMetadata(context:context);record.appUUID=uuid;record.appKind=kind
  record.sourceRepositoryURL=provenance.sourceRepositoryURL;record.sourceAppIdentifier=provenance.sourceAppIdentifier
  record.sourceAppVersion=provenance.sourceAppVersion;record.sourceAppDownloadURL=provenance.sourceAppDownloadURL
  try! context.save();return app as! any AppInfoPresentable
 }
}
'''
checks=r'''
func origin(repo:String="https://example.test/repo",id:String="com.example.app",version:String="1.0",url:String="https://example.test/one.ipa")->SourceAppProvenance {
 SourceAppProvenance(sourceRepositoryURL:URL(string:repo)!,sourceRepositoryIdentifier:"shared.repo.id",sourceRepositoryName:"Repo",
  sourceAppIdentifier:id,sourceAppName:"Display Name",sourceAppVersion:version,sourceAppVersionDate:nil,
  sourceAppDownloadURL:URL(string:url)!,sourceAppIconURL:nil)
}
@main struct Checks {
 @MainActor static func drain() async {for _ in 0..<100 {await Task.yield()}}
 @MainActor static func settle(_ index:SourceLibraryDownloads) async {
  for _ in 0..<100 {
   await index.refreshTask?.value
   await index.validationTask?.value
   await Task.yield()
   if index.refreshTask == nil && index.validationTask == nil {return}
  }
  preconditionFailure("Index did not settle")
 }
 @MainActor static func blocked(_ probe:FileProbe) async {
  for _ in 0..<1000 {if probe.isBlocked{return};try? await Task.sleep(for:.milliseconds(1))}
  preconditionFailure("Background worker did not reach the file check")
 }
 @MainActor static func main() async {
  let storage=Storage();let probe=storage.fileProbe
  let index=SourceLibraryDownloads(storage:storage,validateDirectory:{probe.validate($0)})
  await settle(index)
  precondition(index.identities.isEmpty)
  let live=index,a=origin()
  precondition(!live.contains(a) && !live.contains(nil))
  let first=storage.add("one",kind:"imported",provenance:a)
  await settle(live);precondition(live.contains(a),"A committed import updates all controls")
  precondition(!live.contains(origin(url:"https://example.test/tweak.ipa")),"Same bundle ID and version cannot match another tweak")
  precondition(!live.contains(origin(version:"2.0")),"A newer version is downloadable even with the same URL")
  precondition(!live.contains(origin(repo:"https://other.test/repo")),"Repos with reused identifiers cannot collide")
  precondition(!live.contains(origin(id:"com.other.app")),"Different catalog app cannot collide")
  let duplicate=storage.add("two",kind:"imported",provenance:a)
  let signed=storage.add("signed",kind:"signed",provenance:a)
  storage.context.delete(first as! NSManagedObject);try! storage.context.save();await settle(live)
  precondition(live.contains(a),"Deleting one duplicate preserves the checkmark")
  storage.context.delete(duplicate as! NSManagedObject);try! storage.context.save();await settle(live)
  precondition(live.contains(a),"A signed copy retains the original source identity")
  storage.context.delete(signed as! NSManagedObject);try! storage.context.save();await settle(live)
  precondition(!live.contains(a),"Orphan provenance must not survive the final Library copy")
  let missing=origin(url:"https://example.test/missing.ipa")
  _=storage.add("missing",kind:"imported",provenance:missing,hasFile:false)
  await settle(live);precondition(!live.contains(missing),"Metadata without files cannot claim completion")
  let second=origin(url:"https://example.test/second.ipa")
  let committed=storage.add("second",kind:"imported",provenance:second)
  let beforeCommit=probe.count
  live.recordCommittedApp(committed)
  precondition(live.contains(second) && probe.count==beforeCommit,"Committed imports publish synchronously without directory I/O")
  await settle(live)
  let beforeUnchanged=probe.count
  NotificationCenter.default.post(name:.NSManagedObjectContextObjectsDidChange,object:storage.context,
   userInfo:[NSUpdatedObjectsKey:Set([committed as! NSManagedObject])])
  await settle(live)
  precondition(probe.count==beforeUnchanged,"Unchanged artifacts never get rescanned for ordinary database updates")
  let restarted=SourceLibraryDownloads(storage:storage,validateDirectory:{probe.validate($0)})
  await settle(restarted)
  precondition(restarted.contains(second) && !restarted.contains(a),"A new index rebuilds from surviving Library records")
  storage.files.remove("Imported:second")
  NotificationCenter.default.post(name:UIApplication.willEnterForegroundNotification,object:nil)
  await settle(live);await settle(restarted);precondition(!live.contains(second),"Foreground rechecks externally removed files")
  storage.files.insert("Imported:second");live.refresh()
  for app in try! storage.context.fetch(Imported.fetchRequest()){storage.context.delete(app)}
  try! storage.context.save();await settle(live);await settle(restarted)
  precondition(live.identities.isEmpty,"Library reset clears all matching checkmarks")
  let racing=origin(url:"https://example.test/racing.ipa")
  let racingApp=storage.add("racing",kind:"imported",provenance:racing)
  live.recordCommittedApp(racingApp);await settle(live);await settle(restarted)
  probe.holdNext();live.refresh();await blocked(probe)
  let oldValidation=live.validationTask
  storage.context.delete(racingApp as! NSManagedObject);try! storage.context.save()
  // Reconcile the deletion while the old file result is still blocked.
  live.refresh(recheckFiles:false)
  precondition(!live.contains(racing),"Deletion removes membership before any file callback")
  probe.release();await oldValidation?.value;await settle(live);await settle(restarted)
  precondition(!live.contains(racing),"Late file validation cannot resurrect a deleted Library artifact")
  print("Source Library checks passed: exact variants, version/repo isolation, duplicate and signed copies, deletion, files, startup and completion publication")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-source-library-') as directory:
    directory=Path(directory);swift=directory/'Checks.swift'
    swift.write_text(stubs+provenance+production+checks)
    subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(swift),'-o',str(directory/'checks')],check=True)
    subprocess.run([str(directory/'checks')],check=True)

# Type-check the actual shared SwiftUI control and real catalog/provenance models
# using macOS SwiftUI; only the transfer service and platform host are substitutes.
ui_stubs = r'''
import SwiftUI
import Combine
extension String {static func localized(_ text:String)->String{text}}
extension LocalizedStringKey {static func localized(_ text:String)->LocalizedStringKey{LocalizedStringKey(text)}}
// Catalog colors use a UIKit-specific conversion; color rendering is outside this host type-check.
extension Color: @retroactive Codable {
 public init(hex:String){self = .clear}
 public init(from decoder:Decoder)throws{self = .clear}
 public func encode(to encoder:Encoder)throws{}
}
@MainActor final class Download:ObservableObject {}
@MainActor final class DownloadManager:ObservableObject {
 static let shared=DownloadManager()
 func getDownload(from url:URL,sourceProvenance:SourceAppProvenance?)->Download? {nil}
 func startDownload(from url:URL,id:String,sourceProvenance:SourceAppProvenance?) async->Bool {true}
}
struct DownloadProgressButton:View {let download:Download;var body:some View {Circle()}}
enum NBRowMetrics {static let contentSpacing:CGFloat=12;static let lineSpacing:CGFloat=3}
extension View {func nbRowSubtitle()->some View {self}}
enum SourceAppBodyText {
 static func body(in text:String?)->String? {text}
 static func subtitle(in text:String?,followingVersion:Bool)->String? {text}
}
struct FRIconCellView<Content:View>:View {
 let content:Content
 init(title:String,iconUrl:URL?,badgeURL:URL?,@ViewBuilder content:()->Content){self.content=content()}
 var body:some View {content}
}
@MainActor final class SourceLibraryDownloads:ObservableObject {
 static let shared=SourceLibraryDownloads()
 func contains(_ provenance:SourceAppProvenance?)->Bool {false}
}
'''
with tempfile.TemporaryDirectory(prefix='aether-source-library-ui-') as directory:
    directory=Path(directory)
    source_init=metadata[metadata.index('extension SourceAppProvenance {'):metadata.index('extension Storage {')]
    button=(repo/'Aether/Views/Sources/Apps/DownloadButtonView.swift').read_text().replace('import AltSourceKit','').replace('import NimbleViews','')
    cell=(repo/'Aether/Views/Sources/Apps/SourceAppsCellView.swift').read_text()
    for module in ['AltSourceKit','NimbleViews','NukeUI','Nuke']:
        cell=cell.replace('import '+module+'\n','')
    ui=directory/'UI.swift';ui.write_text(ui_stubs+provenance+source_init+button+cell)
    catalogs=sorted(str(path) for path in (repo/'AltSourceKit/Sources/AltSourceKit').rglob('*.swift') if path.name != 'Color+Codable.swift')
    subprocess.run(['swiftc','-swift-version','5','-strict-concurrency=complete','-typecheck',*catalogs,str(ui)],check=True)
print('Shared download control type-check passed with real catalog/provenance models')

# Verify each UI entry point uses the shared identity, and the redraw occurs before transfer retirement.
button=(repo/'Aether/Views/Sources/Apps/DownloadButtonView.swift').read_text()
assert button.index('if let currentDownload') < button.index('else if isInLibrary')
assert 'Image(systemName: "checkmark")' in button and 'SourceDownloadAgainAction' in button
cell=(repo/'Aether/Views/Sources/Apps/SourceAppsCellView.swift').read_text()
assert 'SourceDownloadAgainAction(sourceURL: sourceURL, source: source, app: app)' in cell
table=(repo/'Aether/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift').read_text()
assert 'SourceLibraryDownloads.shared.contains(provenance)' in table and 'Download Again' in table
manager=(repo/'Aether/Backend/Observable/DownloadManager.swift').read_text().split('private func _finishDownload')[1]
assert manager.index('SourceLibraryDownloads.shared.recordCommittedApp(imported)') < manager.index('downloads.remove(at: index)')
assert 'DownloadButtonView(' in (repo/'Aether/Views/Sources/Apps/Detail/SourceAppsDetailView.swift').read_text()
assert 'SourceAppsCellView(' in (repo/'Aether/Views/Installed/InstalledAppUpdatesView.swift').read_text()
assert 'SourceAppsDetailView(' in (repo/'Aether/Views/Installed/InstalledAppUpdatesView.swift').read_text()
print('Source Library UI coverage checks passed: repo rows, details, Newer Versions and update details')
