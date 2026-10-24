#!/usr/bin/env python3
"""Exercise production status transitions and update presentation without SwiftUI."""
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[2]
def declaration(path, marker):
    source = (repo / path).read_text()
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)
library = 'Aether/Views/Library/LibraryView.swift'
source = '''import Foundation
struct Animation {
 static func easeIn(duration: Double) -> Self { Self() }
 static func easeOut(duration: Double) -> Self { Self() }
}
@MainActor func withAnimation(_ animation: Animation?, _ action: () -> Void) { action() }
struct SourceAppCatalogContext: Equatable { let id: String }
@MainActor final class Updates {
 var updateContexts: [String: [SourceAppCatalogContext]] = [:]
 var showsUpdateCheck = false
 var updateIndicatorStarted: ContinuousClock.Instant?
 var isCheckingForUpdates = false
 var higherPriority = false
 var updateIndicatorRequest: [Bool] { [isCheckingForUpdates, higherPriority] }
'''
source += declaration(library, 'private func updateCheckIndicator()') + '\n'
source += declaration(library, 'private func publishUpdateMatches(') + '\n}\n'
source += '''@MainActor final class Status {
 var text = "Preparing", phase = "preparing", reduceMotion = false
 var displayed = "Preparing", latest = "Preparing", displayedPhase = "preparing"
 var opacity: Double = 1
'''
source += declaration('Aether/Views/Common/SoftStatusText.swift', 'private func transitionText()') + '\n}\n'
source += '''@main struct Checks {
 @MainActor static func main() async throws {
  let updates = Updates()
  let old = SourceAppCatalogContext(id: "old"), fresh = SourceAppCatalogContext(id: "fresh")
  updates.updateContexts = ["app": [old]]
  updates.isCheckingForUpdates = true
  await updates.updateCheckIndicator()
  precondition(updates.showsUpdateCheck && updates.updateContexts["app"] == [old], "Checking must not clear known rows")
  updates.publishUpdateMatches(["app": [], "new": [fresh]], complete: false)
  precondition(updates.updateContexts["app"] == [old] && updates.updateContexts["new"] == [fresh], "Partial checks retain old updates and publish new ones immediately")
  updates.isCheckingForUpdates = false
  let started = updates.updateIndicatorStarted!
  await updates.updateCheckIndicator()
  precondition(started.duration(to: .now) >= .seconds(0.5), "Fast checks must display the indicator for at least half a second")
  precondition(!updates.showsUpdateCheck && updates.updateContexts["new"] == [fresh])
  updates.publishUpdateMatches([:], complete: true)
  precondition(updates.updateContexts.isEmpty, "A successful empty result removes old updates")
  updates.isCheckingForUpdates = true
  await updates.updateCheckIndicator()
  updates.isCheckingForUpdates = false
  let retiring = Task { await updates.updateCheckIndicator() }
  await Task.yield()
  retiring.cancel()
  updates.isCheckingForUpdates = true
  await updates.updateCheckIndicator()
  await retiring.value
  precondition(updates.showsUpdateCheck, "An old canceled dismissal cannot hide a newer check")
  updates.higherPriority = true
  await updates.updateCheckIndicator()
  precondition(!updates.showsUpdateCheck && updates.updateIndicatorStarted == nil, "Connection/loading status overrides the minimum")
  updates.higherPriority = false
  await updates.updateCheckIndicator()
  updates.updateIndicatorStarted = ContinuousClock.now.advanced(by: .seconds(-1))
  updates.isCheckingForUpdates = false
  await updates.updateCheckIndicator()
  precondition(!updates.showsUpdateCheck, "A slow check adds no extra hold")
  let status = Status()
  status.phase = "signing"; status.text = "Signing"
  let swapping = Task { await status.transitionText() }
  while status.opacity == 1 { await Task.yield() }
  precondition(status.displayed == "Preparing" && status.opacity == 0.1, "Outgoing text fades before replacement")
  status.latest = "Signing latest"
  await swapping.value
  precondition(status.displayed == "Signing latest" && status.opacity == 1, "Only the latest text is revealed")
  status.text = "40 MB / 100 MB"; status.phase = "signing"
  await status.transitionText()
  precondition(status.displayed == status.text && status.opacity == 1, "Same-phase numeric updates do not fade")
  status.phase = "packaging"; status.text = "Packaging"
  let canceled = Task { await status.transitionText() }
  while status.opacity == 1 { await Task.yield() }
  canceled.cancel()
  status.phase = "installing"; status.text = "Installing"
  await status.transitionText(); await canceled.value
  precondition(status.displayed == "Installing" && status.opacity == 1, "Rapid phase changes cannot reveal stale text")
  status.phase = "done"; status.text = "Ready"; status.reduceMotion = true
  await status.transitionText()
  precondition(status.displayed == "Ready" && status.opacity == 1, "Reduce Motion swaps without fading out")
  print("Library update retention, indicator minimum, cancellation and text transition checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-library-presentation-') as folder:
    root = Path(folder)
    swift = root / 'Checks.swift'
    swift.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(root / 'checks')], check=True)
    subprocess.run([str(root / 'checks')], check=True, timeout=15)
