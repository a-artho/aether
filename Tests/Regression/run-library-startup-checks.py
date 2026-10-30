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
  print("Library startup checks passed: restored and empty hydration, duplicate snapshots, live insertion/deletion, transaction isolation")
 }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='aether-library-startup-') as temporary:
    folder = Path(temporary)
    swift = folder / 'Checks.swift'
    swift.write_text(source)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

# Type-check the actual native List animation boundary with SwiftUI.
# Native UIKit presentation still requires device/simulator verification.
view=(root/'Aether/Views/Library/LibraryView.swift').read_text()
list_start=view.index('\t\tList {',view.index('private func libraryList('))
list_end=view.index('\n\t\t.navigationBarTitleDisplayMode',list_start)
list_body=view[list_start:list_end]
background_start=view.index('\t\t.animation(',list_end)
background_end=view.index('\n\t\t.overlay {',background_start)
background=view[background_start:background_end]
host=r'''
import SwiftUI
@MainActor final class Controller:ObservableObject { @Published var hasLoadedInitialRows=false }
struct AetherAmbientBackground:View {var body:some View{Color.clear}}
struct Host:View {
 @StateObject private var imports=Controller()
 @State private var isRootListVisible=true
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
}
'''
host=host.replace('SECTION',declaration(view,'private enum LibrarySection:'))
host=host.replace('LAYOUT',declaration(view,'private struct LibraryLayout:'))
host=host.replace('LIST',list_body).replace('BACKGROUND',background)
import platform
with tempfile.TemporaryDirectory(prefix='aether-library-layout-ui-') as temporary:
    folder=Path(temporary);swift=folder/'Host.swift';swift.write_text(host)
    subprocess.run(['swiftc','-parse-as-library','-typecheck','-target',platform.machine()+'-apple-macosx15.0',str(swift)],check=True)
print('Library native List animation SwiftUI type-check passed')

# Mount the production data-source body in real SwiftUI/Core Data. Record what
# its content receives before onChange hydrates the controller, and afterward.
data_source=production[production.index('struct UnifiedImportsDataSource<'):]
body=declaration(data_source,'var body: some View')
initializer=declaration(data_source,'init(controller:')
runtime=r'''
import AppKit
import SwiftUI
import CoreData
import Combine
@objc(StartupRecord) final class Record:NSManagedObject {
 @NSManaged var name:String?
}
typealias UnifiedImportEntry=String
@MainActor final class UnifiedImportsController:ObservableObject {
 @Published var rows:[String]=[]
 @Published var hasLoadedInitialRows=false
 var visibleRows:[String]{rows}
 func requestAutoDelete(uuid:String) {}
 func updateRows(_ names:[String]) {
  if !hasLoadedInitialRows {
   var t=Transaction(animation:nil);t.disablesAnimations=true
   withTransaction(t){rows=names;hasLoadedInitialRows=true}
  } else {rows=names}
 }
}
enum AppInstallationManager {static let importAutoDeleteNotification=Notification.Name("unused")}
@MainActor final class Recorder {
 var snapshots:[[String]]=[]
 func record(_ rows:[String]) {snapshots.append(rows)}
}
@MainActor struct DataSource<Content:View>:View {
 let content:([UnifiedImportEntry])->Content
 @ObservedObject var controller:UnifiedImportsController
 @FetchRequest(sortDescriptors:[NSSortDescriptor(key:"name",ascending:true)]) var fetched:FetchedResults<Record>
 INIT
 private var inputs:[NSManagedObjectID]{fetched.map(\.objectID)}
 private var projectedRows:[String]{fetched.map{$0.name!}}
 private func publishRows(){controller.updateRows(projectedRows)}
 BODY
}
@main struct RuntimeChecks {
 @MainActor static func main() throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let schema=NSManagedObjectModel(),entity=NSEntityDescription()
  entity.name="Record";entity.managedObjectClassName=NSStringFromClass(Record.self)
  let name=NSAttributeDescription();name.name="name";name.attributeType = .stringAttributeType
  entity.properties=[name];schema.entities=[entity]
  let coordinator=NSPersistentStoreCoordinator(managedObjectModel:schema)
  try coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
  let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType)
  context.persistentStoreCoordinator=coordinator
  for value in ["Aether","Instagram"] {let r=Record(context:context);r.name=value}
  try context.save()
  let controller=UnifiedImportsController(),recorder=Recorder()
  let host=NSHostingView(rootView:DataSource(controller:controller){rows in
   let _=recorder.record(rows)
   List {ForEach(rows,id:\.self){Text($0)}}
  }.environment(\.managedObjectContext,context))
  host.frame=NSRect(x:0,y:0,width:393,height:852)
  func settle(){for _ in 0..<12 {host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.02))}}
  settle()
  precondition(recorder.snapshots.first == ["Aether","Instagram"],"First layout must contain restored rows")
  precondition(recorder.snapshots.allSatisfy{$0 == ["Aether","Instagram"]},"Hydration must not change section membership")
  precondition(controller.hasLoadedInitialRows)
  for record in try context.fetch(NSFetchRequest<Record>(entityName:"Record")){context.delete(record)}
  try context.save();settle()
  precondition(recorder.snapshots.last == [],"Deleting the last import must remove the section's rows")
  let added=Record(context:context);added.name="New import";try context.save();settle()
  precondition(recorder.snapshots.last == ["New import"],"Live imports must still reach Library")
  print("Library first-render SwiftUI/Core Data runtime checks passed")
 }
}
'''.replace('INIT',initializer).replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='aether-library-first-render-') as temporary:
    folder=Path(temporary);swift=folder/'Runtime.swift';swift.write_text(runtime)
    executable=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-target',platform.machine()+'-apple-macosx15.0',str(swift),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
