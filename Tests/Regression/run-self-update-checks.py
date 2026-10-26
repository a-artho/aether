"""Check relaunch evidence without performing an actual self-install."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'Aether/Utilities/SelfUpdateAttempt.swift').read_text()
checks = r'''
@main struct Checks {
 static func main() throws {
  func info(_ version: String, _ build: String, _ id: String = "com.anfear.aether") -> [String: Any] {
   ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": build]
  }
  let old = info("3.0.1", "10"), next = info("3.0.2", "11")
  let attempt = SelfUpdateAttempt(runningInfo: old, targetInfo: next)!
  precondition(attempt.confirmsReplacement(runningInfo: next))
  precondition(!attempt.confirmsReplacement(runningInfo: old), "An unchanged app is not proof of success")
  precondition(!attempt.confirmsReplacement(runningInfo: info("3.0.2", "12")), "Another build must not confirm this job")
  precondition(!attempt.confirmsReplacement(runningInfo: info("3.0.2", "11", "other.app")))
  var reinstall = SelfUpdateAttempt(runningInfo: old, targetInfo: old)!
  precondition(!reinstall.confirmsReplacement(runningInfo: old), "Same-build reinstalls remain inconclusive")
  precondition(!reinstall.isUnconfirmedSameBuildReinstall(runningInfo: old), "A prepared request without a service response keeps its interrupted state")
  reinstall.receivedInstallationResponse=true
  precondition(reinstall.isUnconfirmedSameBuildReinstall(runningInfo: old), "Accepted same-build reinstalls restore Reinstall")
  precondition(!reinstall.confirmsReplacement(runningInfo: old), "Restoring Reinstall must not assert verified success")
  precondition(!reinstall.isUnconfirmedSameBuildReinstall(runningInfo: next))
  precondition(!reinstall.isUnconfirmedSameBuildReinstall(runningInfo: info("3.0.1", "10", "other.app")))
  let persistedReinstall=try JSONDecoder().decode(SelfUpdateAttempt.self, from: JSONEncoder().encode(reinstall))
  precondition(persistedReinstall.isUnconfirmedSameBuildReinstall(runningInfo: old))
  let buildOnly = SelfUpdateAttempt(runningInfo: old, targetInfo: info("3.0.1", "11"))!
  precondition(buildOnly.confirmsReplacement(runningInfo: info("3.0.1", "11")))
  precondition(!buildOnly.isUnconfirmedSameBuildReinstall(runningInfo: old), "An unchanged old app cannot dismiss a different target build's interrupted job")
  precondition(!buildOnly.confirmsReplacement(runningInfo: old))
  let downgrade = SelfUpdateAttempt(runningInfo: next, targetInfo: old)!
  precondition(downgrade.confirmsReplacement(runningInfo: old), "An intentional downgrade is still a replacement")
  precondition(SelfUpdateAttempt(runningInfo: old, targetInfo: info("3.0.2", "11", "other.app")) == nil)
  precondition(SelfUpdateAttempt(runningInfo: old, targetInfo: [:]) == nil)
  precondition(SelfUpdateAttempt(runningInfo: old, targetInfo: info("3.0.2", "")) == nil)
  let restored = try JSONDecoder().decode(SelfUpdateAttempt.self, from: JSONEncoder().encode(attempt))
  precondition(restored.confirmsReplacement(runningInfo: next))
  print("Self-update checks passed: changed version/build, unchanged app, same-build reinstall, wrong identity/build, downgrade, missing metadata and persisted evidence")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-self-update-') as directory:
    folder = Path(directory)
    swift = folder / 'Checks.swift'
    swift.write_text(source + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks')], check=True)
