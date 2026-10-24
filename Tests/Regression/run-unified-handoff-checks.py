"""Exercise production row projection across delayed signed-record delivery."""
from pathlib import Path
import tempfile, subprocess, os
root=Path(__file__).resolve().parents[2]
def decl(path,marker):
 s=(root/path).read_text();a=s.index(marker);b=s.index('{',a)+1;n=1
 while n:n+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
lineage=decl('Aether/Backend/Observable/LibraryArtifactIndex.swift','struct LibraryArtifactLineage:')
projection=decl('Aether/Views/Library/UnifiedImportsSection.swift','private var projectedRows:').replace('private var','var',1)
source=r'''
import Foundation
protocol AppInfoPresentable {var uuid:String?{get};var isSigned:Bool{get};var date:Date?{get}}
class App:AppInfoPresentable {
 let uuid:String?;let isSigned:Bool;let date:Date?
 init(_ uuid:String,_ signed:Bool=false,_ date:Date=Date(timeIntervalSince1970:10)){self.uuid=uuid;isSigned=signed;self.date=date}
}
final class Imported:App {init(_ uuid:String){super.init(uuid)}}
final class AppSnapshot:App {init(_ uuid:String,_ signed:Bool=true){super.init(uuid,signed)}}
final class Signed:App {init(_ uuid:String){super.init(uuid,true)}}
enum AppInstallationManager {
 struct InstallationRequest {
  let id=UUID();let app:App
  var appKey:String{Self.appKey(for:app)}
  static func appKey(for app:AppInfoPresentable)->String{"\(app.isSigned)|\(app.uuid ?? "")"}
 }
}
struct Download {let importIdentifier:String}
struct Export {let snapshot:App;let id=UUID()}
struct UnifiedImportEntry {
 let id:String;var app:AppInfoPresentable?;var original:Imported?;var download:Download?
 var operation:AppInstallationManager.InstallationRequest?;var export:Export?;var date:Date?
}
struct Index {var lineage=LibraryArtifactLineage()}
struct Downloads {var downloads=[Download]();var committedImports=[String:AppSnapshot]()}
struct Installations {var installationCards=[AppInstallationManager.InstallationRequest]()}
struct Exports {var exports=[Export]()}
struct Controller {var rows=[UnifiedImportEntry]()}
@MainActor struct Projection {
 var imported=[Imported]();var signed=[Signed]();var index=Index();var downloads=Downloads();var installations=Installations();var exports=Exports();var controller=Controller()
 PROJECTION
}
@main struct Checks {
 @MainActor static func main() {
  var p=Projection();p.imported=[Imported("source")]
  p.installations.installationCards=[.init(app:p.imported[0])]
  let before=p.projectedRows;p.controller.rows=before
  precondition(before.map(\.id)==["app:source"])
  p.index.lineage.recordSigned(uuid:"signed",sourceUUID:"source",sourceIsSigned:false)
  p.installations.installationCards=[.init(app:AppSnapshot("signed"))]
  let pending=p.projectedRows
  precondition(pending.map(\.id)==before.map(\.id),"Signed snapshot must inherit the row while fetched results lag")
  precondition(pending[0].app?.isSigned==true && pending[0].original?.uuid=="source")
  precondition(pending[0].operation != nil)
  p.controller.rows=pending
  p.installations.installationCards=[]
  precondition(p.projectedRows.map(\.id)==before.map(\.id),"Completion before fetch must keep the signed snapshot")
  precondition(p.projectedRows[0].app?.isSigned==true)
  p.installations.installationCards=[.init(app:AppSnapshot("signed"))]
  p.signed=[Signed("signed")]
  let fetched=p.projectedRows
  precondition(fetched.map(\.id)==pending.map(\.id),"Fetched record must not replace the operation row")
  precondition(fetched[0].date==before[0].date)
  p.installations.installationCards=[]
  precondition(p.projectedRows.map(\.id)==before.map(\.id),"Finishing sign-only must retain the same row")
  p.index.lineage.reveal(originalUUID:"source")
  let split=p.projectedRows;p.controller.rows=split
  precondition(Set(split.map(\.id))==["app:source","app:signed"])
  p.index.lineage.recordSigned(uuid:"resigned",sourceUUID:"signed",sourceIsSigned:true)
  p.installations.installationCards=[.init(app:AppSnapshot("resigned"))]
  let resign=p.projectedRows
  precondition(Set(resign.map(\.id)).count==resign.count)
  precondition(resign.contains{$0.id=="app:signed" && $0.operation != nil},"Re-sign must inherit the active signed row before fetch")
  precondition(resign.contains{$0.id=="app:source" && $0.app?.isSigned==false},"Revealed unsigned copy stays separate")
  p.controller.rows=resign
  p.installations.installationCards=[]
  p.index.lineage.remove(uuid:"resigned",isSigned:true)
  precondition(!p.projectedRows.contains{$0.app?.uuid=="resigned"},"Removed lineage cannot resurrect a retired snapshot")

  // A transfer and its fetched import are two publications of the same row.
  var download=Projection()
  download.index.lineage.originalDates["download"] = Date(timeIntervalSince1970:1)
  download.downloads.downloads=[Download(importIdentifier:"download")]
  let transfer=download.projectedRows
  precondition(transfer.map(\.id)==["app:download"])
  download.controller.rows=transfer
  download.imported=[Imported("download")]
  let importedWhileTransferring=download.projectedRows
  precondition(importedWhileTransferring.map(\.id)==transfer.map(\.id),"Database arrival must not create an extra transfer row")
  precondition(importedWhileTransferring[0].app?.uuid=="download")
  download.controller.rows=importedWhileTransferring
  download.downloads.downloads=[]
  let imported=download.projectedRows
  precondition(imported.map(\.id)==transfer.map(\.id) && imported[0].date==transfer[0].date,"Finishing an import must preserve identity and order")

  // Check each publication boundary, including multiple existing signed variants.
  for revealed in [false,true] {
   for sourceIsSigned in [false,true] {
    for fetchedFirst in [false,true] {
     var q=Projection();q.imported=[Imported("original")]
     q.index.lineage.recordSigned(uuid:"old",sourceUUID:"original",sourceIsSigned:false)
     q.signed=[Signed("old")]
     if revealed {q.index.lineage.reveal(originalUUID:"original")}
     let source:App = sourceIsSigned ? q.signed[0] : q.imported[0]
     q.installations.installationCards=[.init(app:source)]
     let initial=q.projectedRows
     let activeID=initial.first{$0.operation != nil}!.id
     let initialCount=initial.count
     q.controller.rows=initial
     q.index.lineage.recordSigned(uuid:"new",sourceUUID:source.uuid,sourceIsSigned:sourceIsSigned)
     if fetchedFirst {q.signed.append(Signed("new"))}
     q.installations.installationCards=[.init(app:AppSnapshot("new"))]
     let committed=q.projectedRows
     precondition(Set(committed.map(\.id)).count==committed.count,"No duplicate row IDs at commit")
     // Re-signing retains the old signed artifact as a separate, intentional variant.
     precondition(committed.count==initialCount+1,"Only the new signed variant may add a row")
     if sourceIsSigned || !revealed {
      precondition(committed.contains{$0.id==activeID && $0.app?.uuid=="new"},"New artifact must inherit the signing row")
     }
     q.controller.rows=committed
     q.installations.installationCards=[]
     let retired=q.projectedRows
     precondition(retired.map(\.id)==committed.map(\.id),"Retiring the job must not add, remove or reorder rows")
     q.controller.rows=retired
     if !fetchedFirst {q.signed.append(Signed("new"))}
     let delivered=q.projectedRows
     precondition(delivered.map(\.id)==committed.map(\.id),"Fetched delivery must not add, remove or reorder rows")
    }
   }
  }

  var late=Projection()
  late.index.lineage.originalDates["late"] = Date(timeIntervalSince1970:1)
  late.downloads.downloads=[Download(importIdentifier:"late")]
  let transferring=late.projectedRows
  late.controller.rows=transferring
  late.downloads.committedImports["late"] = AppSnapshot("late",false)
  late.downloads.downloads=[]
  let awaitingFetch=late.projectedRows
  precondition(awaitingFetch.map(\.id)==transferring.map(\.id),"Completed transfer must not remove its row while fetched import is delayed")
  precondition(awaitingFetch[0].app?.isSigned==false && awaitingFetch[0].download==nil)
  precondition(awaitingFetch[0].date==transferring[0].date)
  late.controller.rows=awaitingFetch
  late.imported=[Imported("late")]
  precondition(late.projectedRows.map(\.id)==awaitingFetch.map(\.id),"Fetched import replaces its handoff without a duplicate row")
  late.downloads.committedImports=[:]
  precondition(late.projectedRows.map(\.id)==awaitingFetch.map(\.id))
  late.imported=[];late.downloads.committedImports["late"] = AppSnapshot("late",false)
  late.index.lineage.remove(uuid:"late",isSigned:false)
  precondition(late.projectedRows.isEmpty,"Deleted imports must not be resurrected by a delayed handoff")
  print("Unified import-to-signed handoff checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-row-handoff-') as folder:
 p=Path(folder);(p/'Checks.swift').write_text(source.replace('PROJECTION',projection)+'\n'+lineage)
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True,env=env)
 subprocess.run([str(p/'checks')],check=True)
