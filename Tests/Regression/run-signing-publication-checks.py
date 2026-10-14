#!/usr/bin/env python3
"""Exercise Library install state and signed-record completion with production methods."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
def method(file, start):
    s = (repo / file).read_text(); a = s.index(start); b = s.index('{', a) + 1; depth = 1
    while depth:
        depth += (s[b] == '{') - (s[b] == '}'); b += 1
    return s[a:b]
manager = 'Aether/Backend/Observable/AppInstallationManager.swift'
handler = 'Aether/Utilities/Handlers/SigningHandler.swift'
s = '''
import Foundation
protocol AppInfoPresentable {var uuid: String {get}}
struct App: AppInfoPresentable {let uuid: String}
@MainActor final class Manager {
 struct InstallationRequest {let appKey:String;let installRequested:Bool;static func appKey(for app:AppInfoPresentable)->String {app.uuid}}
 var currentRequest:InstallationRequest?;var queuedInstalls:[InstallationRequest]=[];var retiringAppKey:String?
 var hasCompletedSuccessfully=false
'''
s += method(manager, 'func containsInstallation(for') + '\n' + method(manager, 'func hasPendingInstallation(for') + '\n}\n'
s += '''
enum SigningFileHandlerError: Error {case appNotFound}
extension Bundle {var name:String? {nil};var version:String? {nil};var iconFileName:String? {nil}}
struct Source {var uuid:String?;var source:URL?;var isSigned=false}
struct Options {enum SigningOption {case `default`};var signingOption=SigningOption.default}
struct Certificate {var uuid:String?}
final class Files {var exists=true;func getPath(in:URL,for:String)->URL? {exists ? URL(fileURLWithPath:"/tmp/Fixture.app") : nil}}
struct Log {func info(_ s:String){}}
enum Logger {static let signing=Log()}
@MainActor final class LibraryArtifactIndex { static let shared=LibraryArtifactIndex(); var recorded=false; func recordSigned(uuid:String,sourceUUID:String?,sourceIsSigned:Bool) { precondition(Storage.shared.inserted);recorded=true } }
@MainActor final class Storage {
 static let shared=Storage();var inserted=false;var fails=false
 enum Kind {case signed}
 func addSigned(uuid:String,source:URL?,certificateUUID:String?,appName:String?,appIdentifier:String?,appVersion:String?,appIcon:String?) throws {
  if fails {throw SigningFileHandlerError.appNotFound};inserted=true
 }
 func copySourceMetadata(from:String?,to:String,kind:Kind){}
}
final class Handler {
 let _uuid="signed";let _fileManager=Files();let _app=Source();let _options=Options();var appCertificate:Certificate?
 func _directory() async throws ->URL {URL(fileURLWithPath:"/tmp")}
'''
s += method(handler, 'func addToDatabase(') + '\n}\n'
s += '''
@main struct Checks {
 @MainActor static func main() async throws {
  let app=App(uuid:"signed"), m=Manager()
  m.currentRequest = .init(appKey:app.uuid,installRequested:false)
  precondition(m.containsInstallation(for:app) && !m.hasPendingInstallation(for:app),"Sign-only job retains file ownership without Queued label")
  m.currentRequest = .init(appKey:app.uuid,installRequested:true)
  precondition(m.hasPendingInstallation(for:app),"Sign-and-install remains pending")
  m.hasCompletedSuccessfully=true
  precondition(!m.hasPendingInstallation(for:app) && m.containsInstallation(for:app),"Success is not pending during success-card retention")
  m.queuedInstalls = [.init(appKey:app.uuid,installRequested:true)]
  precondition(m.hasPendingInstallation(for:app),"Queued reinstall remains pending after prior success")
  m.queuedInstalls=[];m.currentRequest=nil;m.retiringAppKey=app.uuid
  precondition(m.containsInstallation(for:app) && !m.hasPendingInstallation(for:app),"Retiring job still protects files")
  var committed=false
  try await Handler().addToDatabase {precondition(Storage.shared.inserted);committed=true}
  precondition(committed && LibraryArtifactIndex.shared.recorded,"Publication records lineage within the commit")
  LibraryArtifactIndex.shared.recorded=false
  Storage.shared.inserted=false;Storage.shared.fails=true;committed=false
  do {try await Handler().addToDatabase {committed=true};preconditionFailure("Expected commit error")} catch {}
  precondition(!committed && !Storage.shared.inserted && !LibraryArtifactIndex.shared.recorded,"Failed commit cannot report success or record lineage")
  Storage.shared.fails=false
  let missing=Handler();missing._fileManager.exists=false
  do {try await missing.addToDatabase {committed=true};preconditionFailure("Expected missing output error")} catch {}
  precondition(!committed,"Missing output cannot report success")
  let cancelled=Task {withUnsafeCurrentTask {$0?.cancel()};try await Handler().addToDatabase {committed=true}}
  _ = await cancelled.result
  precondition(!committed && !Storage.shared.inserted,"Cancelled job cannot publish")
  print("Signing publication and Library queue state checks passed")
 }
}
'''
fr = (repo / 'Aether/Utilities/FR.swift').read_text()
signing = fr[fr.index('static func signPackageFile('):fr.index('static func handleCertificateFiles(')]
assert signing.index('try? await handler.clean()') < signing.index('try await handler.addToDatabase {') < signing.index('completion(.success(')
assert 'addToDatabase' not in method(handler, 'func modify(progress:')
with tempfile.TemporaryDirectory(prefix='aether-signing-publication-') as d:
    p=pathlib.Path(d)/'Checks.swift';p.write_text(s)
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p),'-o',str(pathlib.Path(d)/'checks')],check=True)
    subprocess.run([str(pathlib.Path(d)/'checks')],check=True)
