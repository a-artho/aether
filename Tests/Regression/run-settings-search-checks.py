#!/usr/bin/env python3
"""Compile the production Settings index with lightweight platform declarations."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
manager = (root / 'Aether/Backend/Observable/AppTabManager.swift').read_text()
start = manager.index('enum SettingsPage: String {')
end = manager.index('\n\t}', start) + 3
page = manager[start:end]
index = (root / 'Aether/Views/Settings/SettingsSearchIndex.swift').read_text()
checks = r'''
@main struct SearchChecks {
 @MainActor static func main() {
  func results(_ query: String) -> [SettingsSearchEntry] { SettingsSearchIndex.results(for: query) }
  func has(_ query: String, _ key: String, _ page: AppTabManager.SettingsPage) -> Bool {
   results(query).contains { $0.key == key && $0.destination == .page(page) }
  }
  precondition(results("  \n ").isEmpty)
  precondition(results("nonexistentoptionxyz").isEmpty)
  precondition(has("HÁPTICS", "Haptics", .appearance))
  precondition(has("compression level", "Compression Level", .archive))
  precondition(has("120hz", "Pro Motion", .signing))
  precondition(has("certificate password", "Enter Password", .certificates))
  precondition(has("automatic connect", "Connect Automatically", .tunnel))
  precondition(has("reset pairing", "Reset Pairing", .reset))
  precondition(results("Reset Pairing").first?.key == "Reset Pairing")
  precondition(results("reset haptics").isEmpty)
  precondition(results("appearance").filter { $0.key == "Appearance" }.count == 2)
  precondition(Set(SettingsSearchIndex.entries.map(\.id)).count == SettingsSearchIndex.entries.count)
  precondition(results("github").first?.destination == .sourceCode)
  precondition(!SettingsSearchIndex.entries.contains { $0.key == "Controls in Header" || $0.key == "Liquid Glass Tiles" || $0.key == "Settings Placement" })
  print("Settings search: 14 matching, ranking, identity, and routing checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-search-tests-') as folder:
    source = Path(folder) / 'SearchChecks.swift'
    source.write_text('import Foundation\nstruct AppTabManager {\n' + page + '\n}\nextension String { static func localized(_ key: String) -> String { key } }\n' + index + checks)
    binary = Path(folder) / 'SearchChecks'
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True, env=env)
    subprocess.run([str(binary)], check=True)
