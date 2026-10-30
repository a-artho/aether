#!/usr/bin/env python3
"""Exercise maintenance ownership, uninstall exclusion and shared-file preparation."""
from pathlib import Path
import subprocess, tempfile, os
root = Path(__file__).resolve().parents[2]
def decl(path, marker):
    s = (root/path).read_text(); a = s.index(marker); b = s.index('{', a)+1; depth = 1
    while depth:
        depth += (s[b]=='{')-(s[b]=='}'); b += 1
    return s[a:b]
manager = 'Aether/Backend/Observable/AppInstallationManager.swift'
download = 'Aether/Backend/Observable/DownloadManager.swift'
source = r'''
import Foundation
extension FileManager {
 func removeFileIfNeeded(at url:URL) throws {if fileExists(atPath:url.path){try removeItem(at:url)}}
 func copyItemPreferClone(at source:URL,to dest:URL) throws {try copyItem(at:source,to:dest)}
}
@MainActor final class BackgroundTaskManager {
 static let shared=BackgroundTaskManager()
 func setCancellationHandler(for token:String,handler:@escaping @Sendable ()->Void){}
 func isCancellationRequested(for token:String)->Bool{false}
}
extension String { static func localized(_ value:String)->String { value } }
enum Level { case notice, info }
@MainActor final class DebugLogManager { static let shared=DebugLogManager(); func log(_ text:String,category:String,level:Level = .info){} }
@MainActor final class OnDevicePairingManager { static let shared=OnDevicePairingManager(); var isActive=false }
@MainActor final class ExportManager { static let shared=ExportManager(); var hasActiveWork=false }
final class LibraryArtifactAccess { static let shared=LibraryArtifactAccess(); var hasReaders=false }
@MainActor final class AppInstallationManager {
 static let shared=AppInstallationManager()
 struct App { let identifier:String? }
 struct Options { let appIdentifier:String? }
 struct Signing { let options:Options }
 struct Request { let app:App; let signing:Signing?; let installRequested:Bool }
 var installationCards=[Request](); var uninstallingBundleIdentifiers=Set<String>()
 var retiringBundleIdentifier:String?; var hasPendingInstalls=false; var hasRetiringWork=false
'''
for marker in ['func blocksUninstall(', 'func beginUninstall(', 'func endUninstall(']:
    source += decl(manager, marker)+'\n'
source += '}\n' + (root/'Aether/Utilities/AppMaintenanceGuard.swift').read_text()
file_helpers = 'NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift'
source += decl(file_helpers,'public struct MaterializedExternalFile:')+'\n'
source += decl(file_helpers,'public enum ExternalFileMaterializationError:')+'\n'
source += 'extension FileManager {\n'+decl(file_helpers,'public func materializePackageForImport(')+'\n}\n'
source += r'''
@MainActor final class Download {
 enum State { case processing; case failed(String,Int) }
 let id=UUID().uuidString; let url:URL; let fileName="fixture.ipa"; var stagedFileName:String?; var interruptionForegroundGeneration:UInt64=0; var state=State.processing
 let onlyArchiving=true; let sourceIsStable=false
 var isPreparingSource=false; var waitingForForeground=false
 init(url:URL){self.url=url}
}
@MainActor final class DownloadManager {
 static let shared=DownloadManager()
 var downloads=[Download](); var hasActiveWork=false
 var _foregroundGeneration:UInt64=0
 var _archiveSourceCleanup=[String:@Sendable ()->Void]()
 var _processingTasks=[String:Task<Void,Never>]()
 var processedURLs=[URL](); var failures=0; var executionAllowed=true; var executionRequests=0
 func startArchive(from url:URL,id:String,sourceIsStable:Bool)->Download {let d=Download(url:url); downloads.append(d); return d}
 func _isCurrent(_ d:Download)->Bool {downloads.contains {$0 === d}}
 func _ensureProcessingExecution(_ d:Download,subtitle:String)->Bool {executionRequests+=1;return executionAllowed}
 func _startProcessing(_ d:Download,sourceURL:URL,sourceIsStable:Bool){processedURLs.append(sourceURL)}
 func _failProcessing(_ d:Download,error:Error){failures+=1}
 func _markRestartRequired(_ d:Download,message:String){}
 func _resumeInterruptedProcessing(){}
 var _store=Store()
 @MainActor struct Store {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  func makeStagingURL(for download:Download,suggestedFilename:String?) throws -> URL {
   try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
   return root.appendingPathComponent(download.id+".ipa")
  }
  func stagingURL(for download:Download)->URL? {download.stagedFileName.map{root.appendingPathComponent($0)}}
 }
 func _persistDownloads(){}
 func _stopContinuedTask(for download:Download,success:Bool){}

'''
for marker in ['func startExternalArchive(', 'private func _prepareExternalArchive(', 'private func _externalArchivePrepared(', 'func retryProcessing(']:
    source += decl(download,marker).replace('private func','func',1)+'\n'
source += r'''
}
@main struct Checks {
 @MainActor static func main() async throws {
  UserDefaults.standard.removeObject(forKey:"Aether.spoofing.simulationMayBeActive")
  let manager=AppInstallationManager.shared
  precondition(manager.beginUninstall(bundleIdentifier:"app"))
  precondition(!manager.beginUninstall(bundleIdentifier:"app"),"Duplicate uninstall must be excluded")
  precondition(AppMaintenanceGuard.resetBlockReason != nil && AppMaintenanceGuard.pairingBlockReason != nil)
  manager.endUninstall(bundleIdentifier:"app")
  manager.installationCards=[.init(app:.init(identifier:"app"),signing:nil,installRequested:true)]
  precondition(!manager.beginUninstall(bundleIdentifier:"app"))
  precondition(manager.beginUninstall(bundleIdentifier:"other"))
  manager.endUninstall(bundleIdentifier:"other")
  manager.installationCards=[.init(app:.init(identifier:"original"),signing:.init(options:.init(appIdentifier:"renamed")),installRequested:true)]
  precondition(!manager.beginUninstall(bundleIdentifier:"renamed"),"Renamed installation target must be protected")
  manager.installationCards=[]; manager.hasPendingInstalls=true
  precondition(!AppMaintenanceGuard.beginReset())
  precondition(!AppMaintenanceGuard.allowPairingChange())
  manager.hasPendingInstalls=false; manager.hasRetiringWork=true
  precondition(!AppMaintenanceGuard.beginReset(),"Retiring workers retain reset protection")
  manager.hasRetiringWork=false
  DownloadManager.shared.hasActiveWork=true
  precondition(!AppMaintenanceGuard.beginReset())
  DownloadManager.shared.hasActiveWork=false; ExportManager.shared.hasActiveWork=true
  precondition(!AppMaintenanceGuard.beginReset())
  ExportManager.shared.hasActiveWork=false; OnDevicePairingManager.shared.isActive=true
  precondition(!AppMaintenanceGuard.beginReset() && !manager.beginUninstall(bundleIdentifier:"app"))
  OnDevicePairingManager.shared.isActive=false


  let input=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".ipa")
  try Data("fixture".utf8).write(to:input)
  defer {try? FileManager.default.removeItem(at:input)}
  let driver=DownloadManager()
  driver.startExternalArchive(from:input,id:"external")
  precondition(driver.downloads.count==1 && driver.downloads[0].isPreparingSource,"Preparation row appears synchronously")
  precondition(driver.executionRequests==1,"Execution is acquired before file-provider work")
  let row=driver.downloads[0]
  await driver._processingTasks[row.id]?.value
  precondition(driver.processedURLs.count==1 && !row.isPreparingSource)
  let prepared=driver.processedURLs[0]
  precondition(prepared != input && FileManager.default.fileExists(atPath:prepared.path))
  driver.retryProcessing(row)
  precondition(driver.processedURLs == [prepared,prepared],"Retry reuses the private source without recopying")
  precondition(row.stagedFileName != nil,"Manual source is retained in journal-owned staging")
  try FileManager.default.removeItem(at:driver._store.root)

  let interrupted=DownloadManager()
  interrupted.startExternalArchive(from:input,id:"interrupted")
  let waiting=interrupted.downloads[0]; waiting.waitingForForeground=true
  await interrupted._processingTasks[waiting.id]?.value
  precondition(interrupted.processedURLs.isEmpty && waiting.stagedFileName != nil,"Interrupted staging retains its private copy")
  waiting.waitingForForeground=false; interrupted.retryProcessing(waiting)
  precondition(interrupted.processedURLs.count==1)
  try FileManager.default.removeItem(at:interrupted._store.root)

  let cancelled=DownloadManager()
  cancelled.startExternalArchive(from:input,id:"cancelled")
  let cancelledRow=cancelled.downloads[0]; let worker=cancelled._processingTasks[cancelledRow.id]
  cancelled.downloads=[]; worker?.cancel(); await worker?.value
  precondition(cancelled.processedURLs.isEmpty && cancelledRow.stagedFileName == nil,"Cancelled preparation cannot resurrect an import")
  try? FileManager.default.removeItem(at:cancelled._store.root)
  precondition(AppMaintenanceGuard.beginReset())
  precondition(!AppMaintenanceGuard.beginReset() && !AppMaintenanceGuard.allowPairingChange())
  precondition(!manager.beginUninstall(bundleIdentifier:"app"))

  print("Maintenance, uninstall exclusion, and external-import lifecycle checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-followup-audit-') as folder:
    path=Path(folder); (path/'Checks.swift').write_text(source)
    env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(path/'Checks.swift'),'-o',str(path/'checks')],check=True,env=env)
    subprocess.run([str(path/'checks')],check=True)
