"""Check initial Library hydration separately from subsequent live row changes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
production = (root / 'Aether/Views/Library/UnifiedImportsSection.swift').read_text()
start = production.index('\tfunc updateRows(')
end = production.index('{', start) + 1
depth = 1
while depth:
    depth += (production[end] == '{') - (production[end] == '}')
    end += 1
method = production[start:end]
def declaration(text, marker):
    a=text.index(marker);b=text.index('{',a)+1;depth=1
    while depth:
        depth+=(text[b]=='{')-(text[b]=='}');b+=1
    return text[a:b].replace('private ', '')
layout_method=declaration((root/'Aether/Views/Library/LibraryView.swift').read_text(),'private func finishInitialLibraryLayout(')
readiness=declaration(production,'private var initialFetchIsReady:')
initial_publisher=declaration(production,'private var initialContextChanges:')
source = r'''
import Foundation
import CoreData
import Combine
struct Transaction {
 var disablesAnimations = false
 init(animation: Bool?) {}
}
@MainActor var suppressesAnimation = false
@MainActor func withTransaction(_ transaction: Transaction, _ action: () -> Void) {
 let previous = suppressesAnimation
 suppressesAnimation = transaction.disablesAnimations
 defer { suppressesAnimation = previous }
 action()
}
struct UnifiedImportEntry { let signature: String }
@MainActor final class Controller {
 func _schedulePendingAutoDeletes() {} // Auto-delete scheduling is outside this hydration fixture.
 var hasLoadedInitialRows = false
 var rowSignatures: [String] = []
 var revision: UInt64 = 0
 var publications: [Bool] = []
 var rows: [UnifiedImportEntry] = [] {
  didSet { publications.append(suppressesAnimation) }
 }
METHOD
}
@MainActor final class LayoutProbe {
 let imports=Controller()
 var isRootListVisible=false
 var updates:[Bool]=[]
 var hasLaidOutInitialLibrary=false {didSet{updates.append(suppressesAnimation)}}
 LAYOUT_METHOD
}
@objc(LibraryStartupImported) final class Imported:NSManagedObject {
 @nonobjc class func fetchRequest()->NSFetchRequest<Imported>{NSFetchRequest(entityName:"Imported")}
}
@objc(LibraryStartupSigned) final class Signed:NSManagedObject {
 @nonobjc class func fetchRequest()->NSFetchRequest<Signed>{NSFetchRequest(entityName:"Signed")}
}
@MainActor final class FetchProbe {
 let controller=Controller()
 let context:NSManagedObjectContext
 var imported:[Imported]=[];var signed:[Signed]=[]
 init() {
  let model=NSManagedObjectModel()
  model.entities=[("Imported",Imported.self),("Signed",Signed.self)].map { name,type in
   let entity=NSEntityDescription();entity.name=name;entity.managedObjectClassName=NSStringFromClass(type);return entity
  }
  let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
  try! coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
  context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
 }
 READINESS
 INITIAL_PUBLISHER
}
@main struct Checks {
 @MainActor static func main() {
  let restored = Controller()
  restored.updateRows([.init(signature: "saved")])
  precondition(restored.hasLoadedInitialRows && restored.revision == 1)
  precondition(restored.publications == [true], "Restoration must not animate as a live insertion")
  restored.updateRows([.init(signature: "saved")])
  precondition(restored.revision == 1, "An identical snapshot must not republish")
  restored.updateRows([.init(signature: "saved"), .init(signature: "new")])
  restored.updateRows([])
  precondition(restored.publications == [true, false, false], "Live insertions and deletions retain their animation transaction")
  precondition(!suppressesAnimation, "Initial hydration must not leak its transaction")
  let empty = Controller()
  empty.updateRows([])
  precondition(empty.hasLoadedInitialRows, "An empty library is still a completed initial snapshot")
  empty.updateRows([.init(signature: "first-import")])
  precondition(empty.publications == [true, false], "The first actual import into an initially empty library is a live insertion")
  let fetch=FetchProbe()
  var finished=false
  let initialObserver=fetch.initialContextChanges.sink(receiveCompletion:{_ in finished=true},receiveValue:{_ in})
  precondition(!finished,"Initial hydration listens for context changes")
  initialObserver.cancel()
  fetch.controller.updateRows([])
  let completedObserver=fetch.initialContextChanges.sink(receiveCompletion:{_ in finished=true},receiveValue:{_ in preconditionFailure("Hydrated library retained an initial-only observer")})
  precondition(finished,"Hydrated libraries release the initial context subscription")
  withExtendedLifetime(completedObserver) {}
  precondition(fetch.initialFetchIsReady,"A genuinely empty database is immediately ready")
  let first=Imported(context:fetch.context), second=Signed(context:fetch.context)
  try! fetch.context.save()
  precondition(!fetch.initialFetchIsReady,"Empty fetched arrays cannot complete hydration of a populated database")
  fetch.imported=[first]
  precondition(!fetch.initialFetchIsReady,"One fetched entity cannot complete a partially restored library")
  fetch.signed=[second]
  precondition(fetch.initialFetchIsReady,"Both fetched arrays must match the stored snapshot")
  fetch.imported=[];fetch.signed=[]
  fetch.context.delete(first);fetch.context.delete(second);try! fetch.context.save()
  precondition(fetch.initialFetchIsReady,"A reset during initial hydration must not wait for records that no longer exist")
  let layout=LayoutProbe()
  layout.finishInitialLibraryLayout(hasSize:true)
  precondition(!layout.hasLaidOutInitialLibrary,"Hidden and unhydrated layouts cannot arm animations")
  layout.isRootListVisible=true
  layout.finishInitialLibraryLayout(hasSize:true)
  precondition(!layout.hasLaidOutInitialLibrary,"A sized list is insufficient until records are hydrated")
  layout.imports.updateRows([])
  layout.finishInitialLibraryLayout(hasSize:false)
  precondition(!layout.hasLaidOutInitialLibrary,"Zero-size layout probes cannot enable animation")
  layout.finishInitialLibraryLayout(hasSize:true)
  precondition(layout.hasLaidOutInitialLibrary && layout.updates == [true],"First presented layout arms live animation without animating that state change")
  layout.finishInitialLibraryLayout(hasSize:true)
  precondition(layout.updates.count==1,"Later layouts do not repeatedly reset the animation baseline")
  print("Library startup checks passed: restored and empty hydration, duplicate snapshots, live insertion/deletion, transaction isolation")
 }
}
'''.replace('LAYOUT_METHOD', layout_method).replace('READINESS', readiness).replace('INITIAL_PUBLISHER', initial_publisher).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='aether-library-startup-') as temporary:
    folder = Path(temporary)
    swift = folder / 'Checks.swift'
    swift.write_text(source)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

# Type-check the actual scoped List animation and first-layout probe with SwiftUI.
# Native UIKit presentation still requires device/simulator verification.
view=(root/'Aether/Views/Library/LibraryView.swift').read_text()
list_start=view.index('\t\tList {',view.index('private func libraryList('))
list_end=view.index('\n\t\t.navigationBarTitleDisplayMode',list_start)
list_body=view[list_start:list_end]
background_start=view.index('\t\t.background {',list_end)
background_end=view.index('\n\t\t.overlay {',background_start)
background=view[background_start:background_end]
host=r'''
import SwiftUI
@MainActor final class Controller:ObservableObject { @Published var hasLoadedInitialRows=false }
struct AetherAmbientBackground:View {var body:some View{Color.clear}}
struct Host:View {
 @StateObject private var imports=Controller()
 @State private var isRootListVisible=true
 @State private var hasLaidOutInitialLibrary=false
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 SECTION
 LAYOUT
 private struct Projection {let sections:[LibrarySection];let layout:LibraryLayout}
 private var projection:Projection {
  let sections:[LibrarySection]=[.allApps,.imports]
  return Projection(sections:sections,layout:LibraryLayout(sections:sections,imports:["stored"],splitGroups:[],updates:[]))
 }
 private func librarySectionContent(_ section:LibrarySection,projection:Projection)->some View {Section {Text("Row")} header:{Text("Header")}}
 var body:some View {
 LIST
 BACKGROUND
 }
 FINISH
}
'''
host=host.replace('SECTION',declaration(view,'private enum LibrarySection:'))
host=host.replace('LAYOUT',declaration(view,'private struct LibraryLayout:'))
host=host.replace('LIST',list_body).replace('BACKGROUND',background).replace('FINISH',layout_method)
import platform
with tempfile.TemporaryDirectory(prefix='aether-library-layout-ui-') as temporary:
    folder=Path(temporary);swift=folder/'Host.swift';swift.write_text(host)
    subprocess.run(['swiftc','-parse-as-library','-typecheck','-target',platform.machine()+'-apple-macosx15.0',str(swift)],check=True)
print('Library scoped animation and geometry-readiness SwiftUI type-check passed')
