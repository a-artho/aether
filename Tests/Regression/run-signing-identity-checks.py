#!/usr/bin/env python3
"""Execute production Aether identity planning and plugin rewriting with file-backed fixtures."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
reader = (repo/'Aether/Utilities/CertificateReader/CertificateReader.swift').read_text()
handler = (repo/'Aether/Utilities/Handlers/SigningHandler.swift').read_text()
view = (repo/'Aether/Views/Signing/SigningView.swift').read_text()

def declaration(source, start):
    a = source.index(start)
    b = source.index('{', a) + 1
    depth = 1
    while depth:
        depth += (source[b] == '{') - (source[b] == '}')
        b += 1
    return source[a:b]

# The optional field permits older saved options/queued jobs to decode without migration.
assert 'var matchAetherIdentityToProfile: Bool?' in (repo/'Aether/Backend/Observable/OptionsManager.swift').read_text()
assert 'if _options.matchAetherIdentityToProfile == true {\n\t\t\ttry _prepareAetherIdentity(in: infoDictionary)' in handler
assert 'options.appIdentifier = try _resolveProfileIdentity()' in view
assert 'options: options,' in declaration(view, 'private func _start()')
assert '.onChange(of: _selectedCertificateUUID)' in view
assert '.onChange(of: _temporaryCertificate)' in view
assert '.disabled(_temporaryOptions.matchAetherIdentityToProfile == true)' in view
assert 'if _isAether {' in declaration(view, 'private func _cert()')
# Existing extension entitlement signing remains unchanged.
assert 'entitlementsPath: _options.appEntitlementsFile?.path ?? ""' in (repo/'Aether/Utilities/Handlers/ZsignHandler.swift').read_text()

swift = r'''
import Foundation
import OSLog
extension String {static func localized(_ value: String) -> String {value}}
enum FixtureLogger {static let signing = Logger(subsystem: "AetherIdentityTests", category: "Signing")}
struct AnyCodable {let value: Any}
struct Profile {var ExpirationDate = Date.distantFuture;var Entitlements: [String:AnyCodable]?}
struct CertificateSnapshot {let provisionURL: URL}
struct Options {
 enum Kind {case `default`, onlyModify}
 var signingOption = Kind.default
 var appIdentifier: String? = "manual.identifier"
 var matchAetherIdentityToProfile: Bool? = true
 var appEntitlementsFile: URL?
 var mergeEntitlements = false
 var removeURLScheme = false
 var removeProvisioning = false
}
struct CertificateReader {
 let decoded: Profile?
 init(_ url: URL?) {
  guard let url, let data = try? Data(contentsOf: url),
   let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String:Any] else {decoded = nil; return}
  decoded = Profile(ExpirationDate: p["ExpirationDate"] as? Date ?? .distantFuture,
    Entitlements: (p["Entitlements"] as? [String:Any])?.mapValues {AnyCodable(value: $0)})
 }
}
'''
swift += declaration(reader, 'enum AetherSigningIdentity')
swift += r'''
final class Worker {
 var _options = Options()
 let _uuid = "fixture"
 var appCertificate: CertificateSnapshot?
'''
swift += declaration(handler, 'private func _prepareAetherIdentity').replace('private func', 'func', 1).replace('Logger.signing', 'FixtureLogger.signing') + '\n'
swift += declaration(handler, 'private func _modifyPluginIdentifiers').replace('private func', 'func', 1)
swift += r'''
}
func check(_ value: @autoclosure () -> Bool, _ label: String) {precondition(value(), label)}
func rejects(_ label: String, _ operation: () throws -> Void) {
 do {try operation();preconditionFailure(label)} catch {}
}
@main struct Checks {
 static func main() async throws {
  let old = "com.anfear.aether", new = "app.tourmaline5269.brown6028"
  check(try AetherSigningIdentity.bundleIdentifier(applicationIdentifier: "8CAEUC6576." + new) == new, "Explicit profile ID, without team prefix")
  check(try AetherSigningIdentity.bundleIdentifier(applicationIdentifier: "OLDPREFIX.example.app") == "example.app", "App ID prefix is not assumed to be the team ID")
  for invalid in [nil, "", "TEAM", ".example.app", "TEAM.", "TEAM.example..app", "TEAM.example/app", "TEAM.example app", "TEAM.example.*", "TEAM.*", "TÉAM.example.app"] as [String?] {
   rejects("Malformed/wildcard profile must not guess") {_ = try AetherSigningIdentity.bundleIdentifier(applicationIdentifier: invalid)}
  }
  let info: NSMutableDictionary = ["CFBundleExecutable":"Aether", "CFBundleIdentifier":old,
   "CFBundleURLTypes":[["CFBundleURLName":old,"CFBundleURLSchemes":["aether"]]],
   "UTExportedTypeDeclarations":[["UTTypeIdentifier":old + ".ipa"]]]
  check(AetherSigningIdentity.isAether(info), "Recognize imported Aether")
  let renamed = info.mutableCopy() as! NSMutableDictionary;renamed["CFBundleIdentifier"] = new;renamed["CFBundleDisplayName"] = "Custom name"
  check(AetherSigningIdentity.isAether(renamed), "Recognize renamed Aether without relying on its display name")
  check(!AetherSigningIdentity.isAether(["CFBundleExecutable":"Other","CFBundleDisplayName":"Aether"]), "Do not opt other apps in by name")
  info["BGTaskSchedulerPermittedIdentifiers"] = [old + ".userTask.*", "other.app.task", old + "2.task"]
  AetherSigningIdentity.updateMainDeclarations(in: info, old: old, new: new)
  let callbacks = info["CFBundleURLTypes"] as! [[String:Any]]
  check(callbacks[0]["CFBundleURLSchemes"] as? [String] == ["aether"], "Preserve LocalDevVPN and shortcut callback scheme")
  check(callbacks[0]["CFBundleURLName"] as? String == new, "URL declaration name follows identity")
  check((info["UTExportedTypeDeclarations"] as? [[String:Any]])?[0]["UTTypeIdentifier"] as? String == old + ".ipa", "Preserve file handoff type declarations")
  check(info["BGTaskSchedulerPermittedIdentifiers"] as? [String] == [new + ".userTask.*", "other.app.task", old + "2.task"], "Bounded namespace rewrite preserves wildcard and unrelated tasks")
  info["BGTaskSchedulerPermittedIdentifiers"] = [old + ".userTask.*", new + ".userTask.*"]
  AetherSigningIdentity.updateTaskIdentifiers(in: info, old: new, new: new)
  check(info["BGTaskSchedulerPermittedIdentifiers"] as? [String] == [new + ".userTask.*", new + ".userTask.*"], "Repair stale original declarations even when main ID already matches")
  check(AetherSigningIdentity.rewriteAetherNamespace(old + ".userTask.*", old:old, new:old + ".copy") == old + ".copy.userTask.*", "Never rewrite the output twice")
  for conflict in 0..<5 {
   rejects("Conflicting option must stop before signing") {
    try AetherSigningIdentity.validateOptions(signingWithCertificate: conflict != 0,
      customEntitlements: conflict == 1, mergeEntitlements: conflict == 2,
      removeURLScheme: conflict == 3, removeProvisioning: conflict == 4)
   }
  }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer {try? FileManager.default.removeItem(at: dir)}
  let profile = dir.appendingPathComponent("profile.plist")
  func writeProfile(_ id: String, expiry: Date = .distantFuture) throws {
   try PropertyListSerialization.data(fromPropertyList:["Entitlements":["application-identifier":id], "ExpirationDate":expiry],format:.xml,options:0).write(to:profile)
  }
  try writeProfile("8CAEUC6576." + new)
  let worker = Worker();worker.appCertificate = CertificateSnapshot(provisionURL:profile)
  try worker._prepareAetherIdentity(in:info)
  check(worker._options.appIdentifier == new, "Profile takes precedence over manual/PPQ ID")
  try writeProfile("DIFFERENT.second.app")
  try worker._prepareAetherIdentity(in:info)
  check(worker._options.appIdentifier == "second.app", "Revalidate actual queued certificate profile")
  try writeProfile("8CAEUC6576." + new, expiry:.distantPast)
  rejects("Expired profile") {try worker._prepareAetherIdentity(in:info)}
  try writeProfile("8CAEUC6576." + new)
  rejects("Other app") {try worker._prepareAetherIdentity(in:["CFBundleExecutable":"Other"])}
  let plugin = dir.appendingPathComponent("AetherTunnel.appex")
  try FileManager.default.createDirectory(at:plugin,withIntermediateDirectories:true)
  let pluginInfo: [String:Any] = ["CFBundleIdentifier":old + ".AetherTunnel", "NSExtension":["NSExtensionPrincipalClass":"AetherTunnel.PacketTunnelProvider", "NSExtensionPointIdentifier":"com.apple.networkextension.packet-tunnel"]]
  let pluginPlist = plugin.appendingPathComponent("Info.plist")
  func writePlugin() throws {try PropertyListSerialization.data(fromPropertyList:pluginInfo,format:.xml,options:0).write(to:pluginPlist)}
  try writePlugin()
  try await worker._modifyPluginIdentifiers(old:new,new:new,pluginBundles:[plugin])
  let updated = NSDictionary(contentsOf:pluginPlist)!
  check(updated["CFBundleIdentifier"] as? String == new + ".AetherTunnel", "Repair original extension ID on an externally renamed main app")
  check((updated["NSExtension"] as? [String:Any])?["NSExtensionPrincipalClass"] as? String == "AetherTunnel.PacketTunnelProvider", "Module/class is not a bundle identifier")
  worker._options.matchAetherIdentityToProfile = nil
  try writePlugin()
  try await worker._modifyPluginIdentifiers(old:new,new:"unrelated",pluginBundles:[plugin])
  check(NSDictionary(contentsOf:pluginPlist)?["CFBundleIdentifier"] as? String == old + ".AetherTunnel", "Toggle off preserves existing plugin behavior")
  print("Aether signing identity checks passed")
 }
}
'''
# The test check autoclosure is nonthrowing; evaluate resolver calls before checking.
swift = swift.replace('check(try AetherSigningIdentity.bundleIdentifier', 'checkResolved(try AetherSigningIdentity.bundleIdentifier')
swift = swift.replace('func check(_ value:', 'func checkResolved(_ value: Bool, _ label: String) {precondition(value, label)}\nfunc check(_ value:')
with tempfile.TemporaryDirectory(prefix='aether-signing-identity-') as d:
    p = pathlib.Path(d)/'Checks.swift';p.write_text(swift)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(p),'-o',d+'/checks'],check=True)
    subprocess.run([d+'/checks'],check=True)
