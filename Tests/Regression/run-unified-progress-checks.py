"""Verify progress subscriptions, completion presentation, and cancellation cleanup."""
import os
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / 'Aether/Views/Library/UnifiedImportsSection.swift').read_text()
activity = source[source.index('@MainActor\nprivate final class UnifiedImportActivity:'):source.index('\nprivate struct UnifiedImportMetadata:')]
cancellation = source[source.index('\tfunc cancelDownload('):source.index('\n\tfunc delete(_ targets:')]
visibility = source[source.index('\tvar visibleRows:'):source.index('\n\tfunc updateRows(')]
update_rows = source[source.index('\tfunc updateRows('):source.index('\n\tfunc isProtected(')]
fixture = r'''
import Foundation
import Combine
@MainActor final class Download: ObservableObject { @Published var progress = 0.0 }
@MainActor final class DownloadManager {
 static let shared = DownloadManager()
 var requests = 0
 var completions: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]
 func deleteDownload(_ download: Download, completion: @escaping @MainActor @Sendable () -> Void) {
  requests += 1
  completions[ObjectIdentifier(download)] = completion
 }
}
@MainActor final class CancellationFixture {
 var cancellingRows: Set<String> = []
 var deletingRows: Set<String> = []
 var rows: [UnifiedImportEntry] = []
 var rowSignatures: [String] = []
 var revision: UInt64 = 0
 VISIBILITY
 UPDATE_ROWS
 CANCELLATION
}
@MainActor final class AppExport: ObservableObject { @Published var progress = 0.0 }
@MainActor final class InstallerStatusViewModel: ObservableObject {
 enum Status { case signing, completed(Result<Void, Error>) }
 @Published var status = Status.signing
}
@MainActor struct UnifiedImportEntry {
 var id = UUID().uuidString
 var signature: String { id }
 struct Operation { var installRequested: Bool }
 var download: Download?
 var export: AppExport?
 var operation: Operation?
}
enum Failure: Error { case fixture }
@MainActor private final class WeakReference {
 weak var value: UnifiedImportActivity?
 init(_ value: UnifiedImportActivity?) { self.value = value }
}
@main struct Checks {
 @MainActor static func main() async {
  let first = Download(), second = Download(), export = AppExport(), model = InstallerStatusViewModel()
  let firstEntry = UnifiedImportEntry(download: first, operation: .init(installRequested: false))
  var observer: UnifiedImportActivity? = UnifiedImportActivity(entry: firstEntry, model: model)
  let weakObserver = WeakReference(observer)
  var events = 0
  var subscription: AnyCancellable? = observer!.objectWillChange.sink { events += 1 }
  first.progress = 0.2
  precondition(events == 1, "Download progress must reach the fields")
  observer!.bind(entry: UnifiedImportEntry(download: second, export: export), model: nil)
  let baseline = events
  first.progress = 0.3
  model.status = .completed(.success(()))
  precondition(events == baseline, "Old lifecycle sources must detach")
  second.progress = 0.4
  export.progress = 0.5
  precondition(events == baseline + 2, "New lifecycle sources must remain observed")
  precondition(firstEntry.signOnlyCompleted(model: model), "Sign-only success returns to the signed row")
  let install = UnifiedImportEntry(operation: .init(installRequested: true))
  precondition(!install.signOnlyCompleted(model: model), "Installation success keeps its existing presentation")
  model.status = .completed(.failure(Failure.fixture))
  precondition(!firstEntry.signOnlyCompleted(model: model), "Failures must never appear signed")
  precondition(!firstEntry.signOnlyCompleted(model: nil), "Queued signing is not completed")
  observer = nil
  subscription?.cancel()
  subscription = nil
  precondition(weakObserver.value == nil, "Progress subscriptions must not retain the row")
  let state = CancellationFixture()
  state.updateRows([.init(id: "first"), .init(id: "second")])
  precondition(state.hasRows)
  state.deletingRows.insert("first")
  precondition(state.visibleRows.map(\.id) == ["second"] && state.hasRows)
  state.deletingRows.insert("second")
  precondition(state.visibleRows.isEmpty && !state.hasRows, "The last-row removal and placeholder must share the same state immediately")
  state.updateRows([.init(id: "second")])
  state.deletingRows.remove("first")
  precondition(!state.hasRows, "One deletion's cleanup must not reveal another pending row")
  state.updateRows([])
  state.deletingRows.remove("second")
  precondition(!state.hasRows, "Committed deletion must not resurrect a stale fetched row")
  state.updateRows([.init(id: "new")])
  precondition(state.hasRows && state.visibleRows.map(\.id) == ["new"], "A new import must restore the section after it empties")
  let cancellation = CancellationFixture()
  cancellation.cancelDownload(first, rowID: "first")
  cancellation.cancelDownload(first, rowID: "first")
  cancellation.cancelDownload(second, rowID: "second")
  let deadline = Date().addingTimeInterval(2)
  while DownloadManager.shared.completions.count < 2 && Date() < deadline { await Task.yield() }
  precondition(DownloadManager.shared.requests == 2, "Cancel is idempotent per row and permits independent downloads")
  precondition(cancellation.cancellingRows == ["first", "second"], "Rows must remain suppressed until their processing cleanup completes")
  DownloadManager.shared.completions.removeValue(forKey: ObjectIdentifier(first))!()
  while cancellation.cancellingRows.contains("first") && Date() < deadline { await Task.yield() }
  precondition(cancellation.cancellingRows == ["second"], "One cleanup must not clear another row's cancellation")
  DownloadManager.shared.completions.removeValue(forKey: ObjectIdentifier(second))!()
  while !cancellation.cancellingRows.isEmpty && Date() < deadline { await Task.yield() }
  precondition(cancellation.cancellingRows.isEmpty)
  print("Unified row progress, completion, subscription release and download cancellation checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aether-unified-progress-') as directory:
    root = pathlib.Path(directory)
    swift = root / 'Checks.swift'
    swift.write_text(fixture.replace('CANCELLATION', cancellation).replace('VISIBILITY', visibility).replace('UPDATE_ROWS', update_rows).replace('@main struct Checks', activity + '\n@main struct Checks'))
    environment = dict(os.environ)
    environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), '-o', str(root / 'Checks')], env=environment, check=True)
    subprocess.run([str(root / 'Checks')], check=True)
