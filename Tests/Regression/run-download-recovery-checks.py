#!/usr/bin/env python3
"""Run production download-store recovery against real temporary files."""
import ast,pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
gen=ast.parse((repo/'Tests/Regression/generate-correction-tests.py').read_text())
fixture=next(ast.literal_eval(n.value) for n in gen.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='fixture' for t in n.targets))
fixture=fixture[:fixture.index('final class CorrectionTests')]
store=(repo/'Aether/Backend/Observable/DownloadStore.swift').read_text()
store=store[store.index('struct StoredDownload:'):]
old='private var rootURL: URL {\n\t\tfileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]\n\t\t\t.appendingPathComponent("AetherDownloads", isDirectory: true)\n\t}'
assert old in store
store=store.replace(old,'let rootURL: URL\n init(rootURL: URL) { self.rootURL = rootURL }')
source='import Foundation\nimport CryptoKit\nextension String {static func localized(_ s:String)->String{s}}\n'+fixture+store+r'''
@main struct Checks {
 @MainActor static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let store=DownloadStore(rootURL:root),d=Download()
  check(store.loadDownloads().isEmpty && !store.hasUnrestoredArtifacts,"New store incorrectly enters recovery")
  try store.save(records:[StoredDownload(download:d)])
  let ipa=try store.makeStagingURL(for:d,suggestedFilename:"app.ipa")
  try Data("recoverable IPA".utf8).write(to:ipa)
  try store.saveResumeData(Data("resume token".utf8),for:d.id)
  let queue=root.appendingPathComponent("queue.json")
  try Data("invalid JSON".utf8).write(to:queue)
  check(store.loadDownloads().isEmpty && store.hasUnrestoredArtifacts,"Unreadable metadata must be distinguished from an empty queue")
  store.pruneArtifacts(keeping:[])
  check(FileManager.default.fileExists(atPath:ipa.path) && store.loadResumeData(for:d.id) != nil,"Recovery pruned valid artifacts")
  let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("queue-unreadable-")}
  check(backups.count==1 && (try? String(contentsOf:backups[0],encoding:.utf8)) == "invalid JSON","Unreadable queue not preserved before replacement")
  try store.save(records:[])
  check(FileManager.default.fileExists(atPath:ipa.path),"Saving empty queue erased recovery files")
  let relaunched=DownloadStore(rootURL:root)
  _=relaunched.loadDownloads();relaunched.pruneArtifacts(keeping:[])
  check(relaunched.hasUnrestoredArtifacts && FileManager.default.fileExists(atPath:ipa.path),"Recovery protection lost on relaunch")
  let healthyRoot=root.appendingPathComponent("healthy"),healthy=DownloadStore(rootURL:healthyRoot)
  try healthy.save(records:[StoredDownload(download:d)])
  let healthyIPA=try healthy.makeStagingURL(for:d,suggestedFilename:"app.ipa")
  try Data().write(to:healthyIPA)
  healthy.pruneArtifacts(keeping:[])
  check(!FileManager.default.fileExists(atPath:healthyIPA.path),"Healthy orphan cleanup was globally disabled")
  print("Download recovery checks passed: unreadable queue, backup, preserved IPA/resume data, relaunch, healthy cleanup")
 }
 static func check(_ condition:@autoclosure ()->Bool,_ message:String){precondition(condition(),message)}
}
'''
with tempfile.TemporaryDirectory(prefix='aether-recovery-') as d:
 p=pathlib.Path(d);(p/'Checks.swift').write_text(source)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
