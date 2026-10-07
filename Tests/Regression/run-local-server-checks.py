#!/usr/bin/env python3
"""Compile real native certificate generation and exercise the real credential store on macOS."""
import pathlib,subprocess,tempfile,json,shutil
repo=pathlib.Path(__file__).resolve().parents[2]
openssl=pathlib.Path('/opt/homebrew/opt/openssl@3')
if not (openssl/'include/openssl/x509.h').exists():
    result=subprocess.run(['brew','--prefix','openssl@3'],text=True,capture_output=True,check=True)
    openssl=pathlib.Path(result.stdout.strip())
with tempfile.TemporaryDirectory(prefix='aether-local-server-') as d:
    d=pathlib.Path(d)
    module=d/'module';module.mkdir()
    shutil.copy(repo/'LocalServerCrypto/Sources/AetherServerCrypto/include/LocalCertificate.h',module/'LocalCertificate.h')
    (module/'module.modulemap').write_text('module AetherServerCrypto { header "LocalCertificate.h" export * }')
    obj=d/'local.o'
    subprocess.run(['clang++','-std=c++17','-fobjc-arc','-Wno-nullability-completeness','-I'+str(openssl/'include'),'-c',str(repo/'LocalServerCrypto/Sources/AetherServerCrypto/local_certificate.mm'),'-o',str(obj)],check=True)
    source=(repo/'Aether/Backend/Server/LocalServerCertificates.swift').read_text()
    source+='''
extension String {static func localized(_ value:String)->String {value}}
extension Logger {static let misc=Logger(subsystem:"AetherLocalTests",category:"Certificates")}
@main struct Checks {
 static func check(_ value:@autoclosure ()->Bool,_ label:String) {precondition(value(),label)}
 static func main() throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let store=LocalServerCertificates(directory:dir)
  check(store.state() == .setupRequired,"Missing setup cannot report ready")
  do {_ = try store.prepareTLS();preconditionFailure("Missing setup cannot install")} catch {}
  let profile=try store.setupProfile()
  let identityURL=dir.appendingPathComponent("identity.plist")
  let identity=try PropertyListSerialization.propertyList(from:Data(contentsOf:identityURL),format:nil) as! [String:Data]
  let root=identity["rootDER"]!, rootKey=identity["rootKeyPEM"]!, leaf=identity["serverDER"]!, leafKey=identity["serverKeyPEM"]!
  check(aether_validate_local_certificate(root,rootKey,nil,true,30*86400),"Valid matching CA")
  check(aether_validate_local_certificate(leaf,leafKey,root,false,14*86400),"Valid matching TLS certificate with loopback SAN")
  check(!aether_validate_local_certificate(leaf,rootKey,root,false,0),"Mismatched private key rejected")
  check(!aether_validate_local_certificate(leaf,leafKey,root,false,100*86400),"Renewal validity threshold enforced")
  check(!aether_validate_local_certificate(root,rootKey,nil,true,20*365*86400),"Root renewal validity threshold enforced")
  check(store.state() == .trustRequired,"Generated files do not mean system trust")
  do {_ = try store.prepareTLS();preconditionFailure("Untrusted certificate cannot install")} catch {}
  let payload=try PropertyListSerialization.propertyList(from:profile,format:nil) as! [String:Any]
  let ca=(payload["PayloadContent"] as! [[String:Any]])[0]
  check(ca["PayloadType"] as? String == "com.apple.security.root","Native CA profile")
  check(ca["PayloadContent"] as? Data == root,"Only public certificate is exported")
  check(profile.range(of:rootKey) == nil && profile.range(of:leafKey) == nil,"Profile never exposes private keys")
  _ = try store.setupProfile()
  check(try Data(contentsOf:identityURL) == PropertyListSerialization.data(fromPropertyList:identity,format:.xml,options:0) || true,"Read persisted identity")
  let reused=try PropertyListSerialization.propertyList(from:Data(contentsOf:identityURL),format:nil) as! [String:Data]
  check(reused == identity,"Repeated setup reuses valid keys and certificates")
  var corrupt=identity;corrupt["serverKeyPEM"]=rootKey
  try PropertyListSerialization.data(fromPropertyList:corrupt,format:.binary,options:0).write(to:identityURL)
  check(store.state() == .trustRequired,"Corrupt leaf regenerated but never self-trusted")
  let renewed=try PropertyListSerialization.propertyList(from:Data(contentsOf:identityURL),format:nil) as! [String:Data]
  check(renewed["rootDER"] == root && renewed["rootKeyPEM"] == rootKey,"Leaf repair preserves trusted CA")
  check(renewed["serverDER"] != leaf,"Leaf repaired")
  corrupt=renewed;corrupt["rootKeyPEM"]=leafKey
  try PropertyListSerialization.data(fromPropertyList:corrupt,format:.binary,options:0).write(to:identityURL)
  let before=try Data(contentsOf:identityURL)
  check(store.state() == .setupRequired,"Broken CA needs explicit setup")
  check(try Data(contentsOf:identityURL) == before,"Readiness never silently rotates CA")
  _ = try store.setupProfile()
  let replacement=try PropertyListSerialization.propertyList(from:Data(contentsOf:identityURL),format:nil) as! [String:Data]
  check(replacement["rootDER"] != root,"Explicit setup repairs invalid CA")
  check((try FileManager.default.attributesOfItem(atPath:identityURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"Private credentials have restricted permissions")
  try root.write(to:dir.appendingPathComponent("root.der"));try leaf.write(to:dir.appendingPathComponent("leaf.der"))
  try store.reset()
  check(!FileManager.default.fileExists(atPath:identityURL.path),"Reset removes persisted keys and certificates")
  check(store.state() == .setupRequired,"Reset requires fresh setup")
  try store.reset()
  _ = try store.setupProfile()
  let fresh=try PropertyListSerialization.propertyList(from:Data(contentsOf:identityURL),format:nil) as! [String:Data]
  check(fresh["rootDER"] != replacement["rootDER"],"Setup after reset generates a new CA")
  try fresh["rootDER"]!.write(to:dir.appendingPathComponent("root.der"))
  try fresh["serverDER"]!.write(to:dir.appendingPathComponent("leaf.der"))
  print("Local CA generation, validation, renewal, profile, reset, and trust-boundary checks passed")
 }
}
'''
    # Evaluate throwing Foundation operations before the nonthrowing check autoclosure.
    source=source.replace('  check(try Data(contentsOf:identityURL) == PropertyListSerialization.data(fromPropertyList:identity,format:.xml,options:0) || true,"Read persisted identity")\n','')
    source=source.replace('check(try Data(contentsOf:identityURL) == before,','checkValue(try Data(contentsOf:identityURL) == before,')
    source=source.replace('check((try FileManager','checkValue((try FileManager')
    source=source.replace(' static func check(', ' static func checkValue(_ value:Bool,_ label:String) {precondition(value,label)}\n static func check(')
    swift=d/'Checks.swift';swift.write_text(source)
    executable=d/'checks'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-I',str(module),str(swift),str(obj),'-L'+str(openssl/'lib'),'-lcrypto','-lc++','-framework','Foundation','-o',str(executable)],check=True)
    subprocess.run([str(executable),str(d/'credentials')],check=True)
    subprocess.run([str(openssl/'bin/openssl'),'x509','-inform','DER','-in',str(d/'credentials/leaf.der'),'-out',str(d/'leaf.pem')],check=True)
    subprocess.run([str(openssl/'bin/openssl'),'x509','-inform','DER','-in',str(d/'credentials/root.der'),'-out',str(d/'root.pem')],check=True)
    subprocess.run([str(openssl/'bin/openssl'),'verify','-CAfile',str(d/'root.pem'),'-purpose','sslserver','-verify_ip','127.0.0.1',str(d/'leaf.pem')],check=True)
# Integration wiring: mode does not select installation mode; pending jobs cannot mutate config.
view=(repo/'Aether/Views/Settings/Installation/Server & SSL/ServerView.swift').read_text()
assert 'setInstallationMode' not in view
assert '.disabled(installations.hasPendingInstalls || setup.isSettingUp)' in view
setup=(repo/'Aether/Backend/Server/LocalServerSetup.swift').read_text()
assert '.hostname("127.0.0.1", port: 0)' in setup
assert '45_000_000_000' in setup and 'endBackgroundTask(token)' in setup
assert 'try Task.checkCancellation()' in setup
installer=(repo/'Aether/Backend/Observable/AppInstallationManager.swift').read_text()
assert installer.index('localTLS = try LocalServerCertificates.shared.prepareTLS()') < installer.index('let handler = ArchiveHandler(app: appSnapshot, viewModel: statusVM, purpose: .install)')
assert 'localTLS: localTLS)' in installer
assert 'case .serverConfig: ServerView()' in (repo/'Aether/Views/Settings/SettingsView.swift').read_text()
assert 'return localServer.state == .ready' in (repo/'Aether/Views/Installed/InstalledAppsView.swift').read_text()
assert 'backloop.dev' not in view
print('Local server settings, placeholder, and installation wiring checks passed')
