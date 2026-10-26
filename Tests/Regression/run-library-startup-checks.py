"""Check initial Library hydration separately from subsequent live row changes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
production = (root / 'Aether/Views/Library/UnifiedImportsSection.swift').read_text()
start = production.index('\tfunc updateRows(')
end = production.index('{', start) + 1
depth = 1
while depth:
    depth += (production[end] == '{') - (production[end] == '}')
    end += 1
method = production[start:end]
source = r'''
import Foundation
struct Transaction {
 var disablesAnimations = false
 init(animation: Bool?) {}
}
@MainActor var suppressesAnimation = false
@MainActor func withTransaction(_ transaction: Transaction, _ action: () -> Void) {
 let previous = suppressesAnimation
 suppressesAnimation = transaction.disablesAnimations
 defer { suppressesAnimation = previous }
 action()
}
struct UnifiedImportEntry { let signature: String }
@MainActor final class Controller {
 func _schedulePendingAutoDeletes() {} // Auto-delete scheduling is outside this hydration fixture.
 var hasLoadedInitialRows = false
 var rowSignatures: [String] = []
 var revision: UInt64 = 0
 var publications: [Bool] = []
 var rows: [UnifiedImportEntry] = [] {
  didSet { publications.append(suppressesAnimation) }
 }
METHOD
}
@main struct Checks {
 @MainActor static func main() {
  let restored = Controller()
  restored.updateRows([.init(signature: "saved")])
  precondition(restored.hasLoadedInitialRows && restored.revision == 1)
  precondition(restored.publications == [true], "Restoration must not animate as a live insertion")
  restored.updateRows([.init(signature: "saved")])
  precondition(restored.revision == 1, "An identical snapshot must not republish")
  restored.updateRows([.init(signature: "saved"), .init(signature: "new")])
  restored.updateRows([])
  precondition(restored.publications == [true, false, false], "Live insertions and deletions retain their animation transaction")
  precondition(!suppressesAnimation, "Initial hydration must not leak its transaction")
  let empty = Controller()
  empty.updateRows([])
  precondition(empty.hasLoadedInitialRows, "An empty library is still a completed initial snapshot")
  empty.updateRows([.init(signature: "first-import")])
  precondition(empty.publications == [true, false], "The first actual import into an initially empty library is a live insertion")
  print("Library startup checks passed: restored and empty hydration, duplicate snapshots, live insertion/deletion, transaction isolation")
 }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='aether-library-startup-') as temporary:
    folder = Path(temporary)
    swift = folder / 'Checks.swift'
    swift.write_text(source)
    executable = folder / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
