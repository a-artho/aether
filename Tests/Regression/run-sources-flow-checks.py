#!/usr/bin/env python3
"""Production Sources cache, cancellation, persistence and loading regressions."""
from pathlib import Path
import subprocess, tempfile

repo = Path(__file__).resolve().parents[2]
def read(path):
    return (repo / path).read_text()
def declaration(source, marker):
    a = source.index(marker)
    body = source.index(') -> Task<Void, Never>? {', a) if marker == 'static func handleSource(' else a
    b = source.index('{', body) + 1; depth = 1
    while depth:
        depth += (source[b] == '{') - (source[b] == '}'); b += 1
    return source[a:b].replace('private ', '')

stubs = r'''
import Foundation
import CoreData
import Combine
import SwiftUI
import os
enum UIApplication { static let didReceiveMemoryWarningNotification = Notification.Name("memoryPressure") }
struct NSDiffableDataSourceSnapshot<S: Hashable & Sendable, I: Hashable & Sendable>: Sendable {
 mutating func appendSections(_ values:[S]) {}
 mutating func appendItems(_ values:[I],toSection:S?=nil) {}
 mutating func reconfigureItems(_ values:[I]) {}
}
extension String {static func localized(_ s:String)->String{s}}
enum Logger {static let misc=os.Logger(subsystem:"AetherTests",category:"Sources")}
@MainActor final class HapticManager {static let shared=HapticManager();func impact() {}}
@MainActor enum UIAlertController {
 static var alerts=0
 static func showAlertWithOk(title:String,message:String){alerts+=1}
}
actor InstalledAppUpdateCatalog {
 static let shared=InstalledAppUpdateCatalog()
 func clearCache() {}
 func removeSource(_ key:String) {}
}
@objc(SourcesFlowAltSource) final class AltSource:NSManagedObject {
 @NSManaged var name:String?; @NSManaged var date:Date?; @NSManaged var identifier:String?
 @NSManaged var sourceURL:URL?; @NSManaged var iconURL:URL?
 @nonobjc class func fetchRequest()->NSFetchRequest<AltSource>{NSFetchRequest(entityName:"AltSource")}
}
final class FailingContext:NSManagedObjectContext, @unchecked Sendable {
 var shouldFail=false
 override func save() throws {if shouldFail {throw NSError(domain:"InjectedSaveFailure",code:1)};try super.save()}
}
@MainActor final class Storage {
 static let shared=Storage()
 let context:FailingContext
 init() {
  let model=NSManagedObjectModel(),entity=NSEntityDescription()
  entity.name="AltSource";entity.managedObjectClassName=NSStringFromClass(AltSource.self)
  entity.properties=[("name",NSAttributeType.stringAttributeType),("date",.dateAttributeType),
   ("identifier",.stringAttributeType),("sourceURL",.URIAttributeType),("iconURL",.URIAttributeType)].map {name,type in
   let a=NSAttributeDescription();a.name=name;a.attributeType=type;a.isOptional=true;return a
  }
  model.entities=[entity]
  let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
  try! coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
  context=FailingContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
 }
 func saveContext()->Error? {do {try context.save();return nil}catch{return error}}
}
final class RequestProbe: @unchecked Sendable {
 static let shared=RequestProbe()
 let lock=NSLock();var active=0;var peak=0;var count=0
 func reset(){lock.lock();active=0;peak=0;count=0;lock.unlock()}
 func start(){lock.lock();active+=1;count+=1;peak=max(peak,active);lock.unlock()}
 func finish(){lock.lock();active-=1;lock.unlock()}
 func snapshot()->(Int,Int,Int){lock.lock();defer{lock.unlock()};return(active,peak,count)}
}
final class CatalogProtocol:URLProtocol, @unchecked Sendable {
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func stopLoading() {}
 override func startLoading() {
  RequestProbe.shared.start()
  DispatchQueue.global().asyncAfter(deadline:.now()+0.04) { [self] in
   RequestProbe.shared.finish()
   let status=request.url!.lastPathComponent == "failure" ? 500:200
   let data=Data(#"{"name":"Source","apps":[{"bundleIdentifier":"test.app","name":"Fixture","version":"1.0","downloadURL":"https://test.invalid/app.ipa","description":"Search needle"}]}"#.utf8)
   client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
   client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
  }
 }
}
enum SessionFixture {
 static func make()->URLSession {let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[CatalogProtocol.self];return URLSession(configuration:c)}
}
'''
model = read('AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift').replace('import SwiftUI', 'public struct Color: Codable, Hashable, Sendable {}')
source = stubs + model
for path in ['Extensions/Array/Array+safe.swift', 'Utilities/ASDecrypt.swift', 'Utilities/Key/EsignSourceKey.swift']:
    source += read('AltSourceKit/Sources/AltSourceKit/' + path)
service = read('Aether/Backend/Observable/SourceRepositoryService.swift').replace('import AltSourceKit', '')
service = service.replace('static let shared = SourceRepositoryService()', 'static let shared = SourceRepositoryService(session: SessionFixture.make(), cacheDirectory: nil)')
source += service
source += read('Aether/Backend/Observable/SourceAppListStore.swift').replace('import AltSourceKit', '').replace('import UIKit', '').replace('private ', '')
source += read('Aether/Views/Sources/SourcesViewModel.swift').replace('import AltSourceKit', '')
source += read('Aether/Backend/Storage/Storage+Sources.swift').replace('import AltSourceKit', '')
source += '@MainActor enum FR {\n' + declaration(read('Aether/Utilities/FR.swift'), 'static func handleSource(') + '\n}\n'
source += declaration(read('Aether/Views/Sources/Apps/Detail/VersionHistoryView.swift'), 'struct SourceAppVersionEntry:')
view = read('Aether/Views/Sources/Apps/SourceAppsView.swift')
source += r'''
@MainActor final class LoadProbe {
 typealias SourceRepositoryContext=SourceAppCatalogContext
 let object:[AltSource];let viewModel:SourcesViewModel
 var _completedLoadKey:String?;var _loadAttempt=0
 var _sourceContexts:[SourceRepositoryContext]?;var _loadedCatalogRevision:Int?;var _loadedSourceKeys:[String]=[]
 init(_ object:[AltSource],_ model:SourcesViewModel){self.object=object;viewModel=model}
 func _consumePendingAppRequestIfPossible() {}
'''
for marker in ['private var _sourceKeys:', 'private var _loadKey:', 'private var isLoading:', 'private var _loadFailure:', 'private func _load()']:
    source += declaration(view, marker) + '\n'
source += '}\n@MainActor final class Owner {var active=true;var _operationID=UUID();var _pendingTask:Task<Void,Never>?;var _isSaving=false;var _isImporting=false\n'
source += declaration(read('Aether/Views/Sources/SourcesAddView.swift'), 'private func _cancelPendingOperation()')+'\n}\n'
source += r'''

func check(_ condition: @autoclosure ()->Bool,_ label:String){precondition(condition(),label)}
@main struct Checks {
 @MainActor static func main() async throws {
  let storage=Storage.shared,ctx=storage.context,url=URL(string:"https://test.invalid/source")!
  let pending=AltSource(context:ctx);pending.identifier="unrelated"
  ctx.shouldFail=true
  var failed=false
  storage.addSource(url,identifier:"failed"){failed = $0 != nil}
  check(failed && !storage.sourceExists("failed"),"Failed insertion cannot remain visible")
  check(pending.isInserted && storage.sourceExists("unrelated"),"Failed insertion preserves unrelated pending edits")
  ctx.shouldFail=false;try ctx.save()
  let snapshot=try await SourceRepositoryService.shared.fetch(from:url)
  storage.addSource(url,repository:snapshot.repository,id:"valid"){precondition($0 == nil)}
  let valid=storage.getSources().first{$0.identifier == "valid"}!
  valid.name="Pending rename";ctx.shouldFail=true
  storage.deleteSource(for:valid)
  check(!valid.isDeleted && valid.name == "Pending rename","Failed deletion restores the source and its preceding edits")
  storage.addSources(repos:[URL(string:"https://test.invalid/bulk")!:snapshot.repository]){failed = $0 != nil}
  check(failed && !storage.sourceExists("https://test.invalid/bulk"),"Failed bulk import discards only its inserts")
  ctx.shouldFail=false;try ctx.save()

  let vm=SourcesViewModel(repositoryService:SourceRepositoryService.shared)
  let loading=LoadProbe([valid],vm);loading._load()
  check(loading.isLoading,"A missing catalog remains loading even when global refresh is idle")
  vm.cache(snapshot,for:valid)
  check(vm.revision(for:valid) == snapshot.revision,"Add/import preserves the content digest")
  let revision=vm.catalogRevision;vm.cache(snapshot,for:valid)
  check(vm.catalogRevision == revision,"Identical seeding does not invalidate the catalog")
  loading._load();loading._completedLoadKey=loading._loadKey
  check(!loading.isLoading && loading._loadFailure == nil,"A ready catalog ends loading")
  await vm.clearNetworkCache();loading._load()
  check(loading.isLoading,"Cache reset starts a new loading generation")
  await vm.ensureSourcesLoaded([valid]);loading._load();loading._completedLoadKey=loading._loadKey
  check(loading._sourceContexts?.count == 1 && !loading.isLoading,"Evicted catalog restores")
  check(await SourceAppListStore.shared.projections.isEmpty,"Update-only loading never prepares browsing projections")
  storage.addSource(URL(string:"https://test.invalid/failure")!,identifier:"failure"){precondition($0 == nil)}
  let bad=storage.getSources().first{$0.identifier == "failure"}!,errorProbe=LoadProbe([storage.getSources().first{$0.identifier == "failure"}!],vm)
  await vm.ensureSourcesLoaded([bad]);errorProbe._load();errorProbe._completedLoadKey=errorProbe._loadKey
  check(!errorProbe.isLoading && errorProbe._loadFailure != nil,"A failed first fetch is an error, not an empty repo")

  let owner=Owner(),alerts=UIAlertController.alerts
  RequestProbe.shared.reset()
  let operation=owner._operationID
  let cancelled=FR.handleSource("https://test.invalid/cancelled",shouldCommit:{owner._operationID == operation})!
  owner._pendingTask=cancelled
  while RequestProbe.shared.snapshot().2 == 0 {await Task.yield()}
  let shared=Task {try await SourceRepositoryService.shared.fetch(from:URL(string:"https://test.invalid/cancelled")!)}
  owner._cancelPendingOperation();await cancelled.value
  let survivor=try await shared.value
  check(survivor.repository.apps.count == 1,"Cancelling the sheet preserves another consumer of the shared request")
  check(!storage.sourceExists("https://test.invalid/cancelled") && UIAlertController.alerts == alerts,"Cancelled presentation cannot commit or alert later")
  let failureOwner=Owner()
  let lateError=FR.handleSource("https://test.invalid/failure",shouldCommit:{failureOwner.active})!
  failureOwner.active=false;await lateError.value
  check(UIAlertController.alerts == alerts,"Dismissed source errors cannot interrupt the next screen")

  let service=SourceRepositoryService(session:SessionFixture.make(),cacheDirectory:nil)
  RequestProbe.shared.reset()
  let urls=(0..<15).map{URL(string:"https://test.invalid/batch/\($0)")!}
  let imported=await service.snapshots(from:urls+urls,limit:3)
  let network=RequestProbe.shared.snapshot()
  check(imported.count == 15 && network.1 <= 3 && network.2 == 15,"Import bounds concurrent requests and deduplicates URLs")

  let store=SourceAppListStore(cacheDirectory:nil)
  let context=SourceAppCatalogContext(sourceObjectURI:"one",sourceURL:url,repository:snapshot.repository,revision:snapshot.revision)
  let base=try await store.list(contexts:[context],sort:"default",ascending:false,query:"",unknownDate:"Unknown")
  let sorted=try await store.list(contexts:[context],sort:"name",ascending:true,query:"",unknownDate:"Unknown")
  let filtered=try await store.list(contexts:[context],sort:"name",ascending:true,query:"needle",unknownDate:"Unknown")
  let id=base.sections[0].rows[0]
  check(base.rows.pools["one"] === sorted.rows.pools["one"] && base.rows.pools["one"] === filtered.rows.pools["one"],"Sorting and searching share the same immutable row pool")
  let noMatches=try await store.list(contexts:[context],sort:"name",ascending:true,query:"missing",unknownDate:"Unknown")
  check(noMatches.rows.isEmpty && noMatches.rows[id] == nil,"Filtered membership excludes nonmatching anchors")
  await store.discardInactiveCaches()
  check(base.rows[id]?.app.currentName == "Fixture","Pressure eviction cannot invalidate an active presentation")
  let tiny=SourceAppListStore(cacheDirectory:nil,memoryBudget:0)
  let active=try await tiny.list(contexts:[context],sort:"name",ascending:true,query:"",unknownDate:"Unknown")
  check(await tiny.projections.isEmpty && tiny.prepared.isEmpty,"Cost budget bounds optional retained lists")
  check(active.rows.count == 1,"Budget eviction preserves returned rows")
  for text in ["ASCII I name", "a.b-c_9", "Café", "Straße", "İstanbul", "Greek Σσς", "日本語"] {
   let row=SourceAppRow(id:id,sourceObjectURI:"one",sourceURL:url,source:snapshot.repository,app:snapshot.repository.apps[0],contentRevision:0,name:text,bundleID:"com.test",date:nil,letter:"A",searchFields:["com.test",text])
   for query in ["a", "I", "ss", "é", "cafe", "Σ", "日本", ".", "not here"] {
    let expected="com.test".range(of:query,options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US")) != nil || text.localizedCaseInsensitiveContains(query)
    check(row.matches(query,asciiQuery:SourceAppASCIIQuery(query),englishText:true) == expected,"ASCII fast path preserves Foundation search semantics")
    check(row.matches(query,asciiQuery:SourceAppASCIIQuery(query),englishText:false) == expected,"Other locales retain Foundation text matching")
   }
  }
  var seed:UInt64=42
  func next()->UInt64 {seed=seed &* 6364136223846793005 &+ 1;return seed}
  let alphabet=Array("abAB ._-09\n\0".utf8)
  for _ in 0..<500 {
   let text=String(decoding:(0..<Int(next()%80)).map{_ in alphabet[Int(next()%UInt64(alphabet.count))]},as:UTF8.self)
   let query=String(decoding:(0..<Int(next()%12+1)).map{_ in alphabet[Int(next()%UInt64(alphabet.count))]},as:UTF8.self)
   let normalized=SourceAppRow.lowercaseASCII(text)!
   let expected=normalized.range(of:SourceAppRow.lowercaseASCII(query)!,options:.literal) != nil
   check(SourceAppASCIIQuery(query)!.contains(in:normalized) == expected,"ASCII index handles repeated prefixes, empty fields and embedded nulls")
  }
  let history=try JSONDecoder().decode(ASRepository.self,from:Data(#"{"apps":[{"versions":[{"version":"1.0","downloadURL":"https://test.invalid/a"},{"version":"1.0","downloadURL":"https://test.invalid/b"},{"version":"1.0","downloadURL":"https://test.invalid/a"}]}]}"#.utf8)).apps[0].versions!
  let entries=SourceAppVersionEntry.entries(for:history)
  check(Set(entries.map(\.id)).count == 3 && entries.map(\.version) == history,"History variants and exact duplicates preserve distinct stable view identity")
  print("Sources flow checks passed: cancel ownership, save failures, loading/reset/errors, revisions, bounded imports, shared rows, cache budgets, localized matching and history identity")
 }
}
'''
# Await actor observations before passing them through synchronous assertion closures.
source = source.replace('check(await SourceAppListStore.shared.projections.isEmpty,', 'let noProjections=await SourceAppListStore.shared.projections.isEmpty;check(noProjections,')
source = source.replace('check(await tiny.projections.isEmpty && tiny.prepared.isEmpty,', 'let emptyProjections=await tiny.projections.isEmpty;let emptyPrepared=await tiny.prepared.isEmpty;check(emptyProjections && emptyPrepared,')
with tempfile.TemporaryDirectory(prefix='aether-sources-flow-') as directory:
    p=Path(directory);(p/'Checks.swift').write_text(source)
    subprocess.run(['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)

assert ".onDisappear { _cancelPendingOperation() }" in read("Aether/Views/Sources/SourcesAddView.swift"), "Interactive dismissal must retire the pending operation"
