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
final class AppSnapshot:App {init(_ uuid:String){super.init(uuid,true)}}
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
struct Downloads {var downloads=[Download]()}
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
  print("Unified import-to-signed handoff checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-row-handoff-') as folder:
 p=Path(folder);(p/'Checks.swift').write_text(source.replace('PROJECTION',projection)+'\n'+lineage)
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True,env=env)
 subprocess.run([str(p/'checks')],check=True)
