"""Check the production ring calculation across signing/installation handoffs."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
model = (repo / "IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallerStatusViewModel.swift").read_text()
source = (repo / "Aether/Backend/Observable/InstallerStatusViewModel.swift").read_text()
progress = source[source.index("\tvar operationProgress:"):source.index("\n\tvar statusImage:")]
checks = r'''
@main struct Checks {
 @MainActor static func main() {
  for local in [true, false] {
   let model = InstallerStatusViewModel(status: .signing, isIdevice: local, signsBeforeInstalling: true)
   model.signingProgress = 0.5
   precondition(abs(model.operationProgress - 0.15) < 0.000001)
   model.signingProgress = 1
   let signed = model.operationProgress
   precondition(signed < 1, "Signing must not finish a combined job's ring")
   model.status = .none
   precondition(model.operationProgress == signed, "Packaging must continue where signing ended")
   var previous = signed
   for stage in 0..<3 {
    for step in 0...10 {
     let value = Double(step) / 10
     switch stage {
     case 0: model.packageProgress = value
     case 1: model.status = .sendingPayload; model.uploadProgress = value
     default: model.status = .installing; model.installProgress = value
     }
     precondition(model.operationProgress >= previous, "Stage handoffs must not rewind the ring")
     previous = model.operationProgress
    }
   }
   precondition(previous < 1, "Only completion may fill the combined ring")
   model.status = .completed(.success(()))
   precondition(model.operationProgress == 1)
  }
  let signOnly = InstallerStatusViewModel(status: .signing)
  signOnly.signingProgress = 1
  precondition(signOnly.operationProgress == 1)
  let installOnly = InstallerStatusViewModel()
  precondition(installOnly.operationProgress == 0)
  installOnly.packageProgress = .nan
  installOnly.uploadProgress = .infinity
  installOnly.installProgress = -1
  precondition(installOnly.operationProgress == 0)
  print("Unified installation progress checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="aether-installation-progress-") as temp:
    directory = pathlib.Path(temp)
    swift = directory / "Checks.swift"
    swift.write_text(model + "\nextension InstallerStatusViewModel {\n" + progress + "\n}\n" + checks)
    executable = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
