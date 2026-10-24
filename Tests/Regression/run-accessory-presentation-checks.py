#!/usr/bin/env python3
"""Exercise the production visual hold without delaying operation execution."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = (repo / 'Aether/Views/Library/UnifiedImportsSection.swift').read_text()
start = source.index('@MainActor\nprivate final class ImportAccessoryPresentation:')
end = source.index('/// Only metadata and controls', start)
production = source[start:end].replace('private final class', 'final class', 1)
harness = '''import Foundation
import Combine
''' + production + '''
@main struct Checks {
 @MainActor static func main() async throws {
  let state = ImportAccessoryPresentation()
  await state.finish()
  precondition(!state.holdingCompletion, "Ready rows must not invent a progress phase")

  let start = ContinuousClock.now
  state.begin()
  try await Task.sleep(for: .milliseconds(30))
  let first = Task { await state.finish() }
  try await Task.sleep(for: .milliseconds(60))
  precondition(state.holdingCompletion, "Fast completion must retain its ring and status")
  // New work interrupts completion. Keep a continuous ring, not a button flash.
  first.cancel()
  state.begin()
  await first.value
  precondition(state.holdingCompletion, "Canceled completion must not reveal a stale button")
  await state.finish()
  precondition(!state.holdingCompletion)
  precondition(start.duration(to: .now) >= .milliseconds(600))

  // A canceled SwiftUI task must be resumable when the row returns onscreen.
  state.begin()
  let leaving = Task { await state.finish() }
  leaving.cancel()
  await leaving.value
  precondition(state.holdingCompletion)
  await state.finish()
  precondition(!state.holdingCompletion)

  state.begin()
  try await Task.sleep(for: .milliseconds(650))
  let finished = ContinuousClock.now
  await state.finish()
  precondition(finished.duration(to: .now) < .milliseconds(100), "Long work must not incur another minimum")
  print("Accessory presentation: fast work, continuous handoff, cancellation and long work passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-accessory-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
