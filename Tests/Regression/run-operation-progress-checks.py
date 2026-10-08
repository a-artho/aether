#!/usr/bin/env python3
"""Verify real worker progress is coalesced, monotonic and closed at termination."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
s=(repo/'Aether/Utilities/OperationProgressPublisher.swift').read_text()
proxy=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift').read_text()
a=proxy.index('private final class UploadProgressPublisher:');b=proxy.index('public class InstallationProxy:',a)
s+='\n'+proxy[a:b]+'\n'
s+='''
@main struct Checks {
 @MainActor static func main() async throws {
  var signing:[Double]=[]
  let signer=OperationProgressPublisher {signing.append($0)}
  signer.submit(0.4);signer.submit(0.3);signer.submit(0.8)
  try await Task.sleep(nanoseconds:10_000_000)
  precondition(signing == [0.8],"Many worker callbacks produce one monotonic UI delivery")
  signer.submit(0.95);signer.cancel()
  try await Task.sleep(nanoseconds:10_000_000)
  signer.submit(1)
  precondition(signing == [0.8],"Cancelled / completed signing drops delayed updates")
  var upload:[Double]=[]
  let publisher=UploadProgressPublisher {upload.append($0)}
  let context=UploadProgressContext(publisher:publisher,acknowledgedBytes:400,totalBytes:1000)
  context.report(100);context.report(50);context.report(200)
  try await Task.sleep(nanoseconds:10_000_000)
  precondition(upload == [0.6],"Within-packet bytes combine with previously acknowledged bytes")
  context.report(250);publisher.finish()
  precondition(upload == [0.6,0.65],"Final delivery flushes before terminal status")
  context.report(600)
  try await Task.sleep(nanoseconds:10_000_000)
  precondition(upload == [0.6,0.65],"Late native callbacks cannot overwrite terminal state")
  print("Signing / payload / installation progress delivery checks passed")
 }
}
'''
assert 'let chunkSize = 4 * 1024 * 1024' in proxy
assert 'afc_file_write_with_progress(' in proxy
assert 'installationProgressPublisher.finish()' in proxy
assert '_updateInstallProgress' not in proxy
with tempfile.TemporaryDirectory(prefix='aether-operation-progress-') as d:
 p=pathlib.Path(d)/'Checks.swift';p.write_text(s)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p),'-o',str(pathlib.Path(d)/'checks')],check=True)
 subprocess.run([str(pathlib.Path(d)/'checks')],check=True)
