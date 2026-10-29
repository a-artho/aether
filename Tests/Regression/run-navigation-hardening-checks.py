#!/usr/bin/env python3
"""Exercise source-app routing and guard its UIKit/SwiftUI activation ownership."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def declaration(path: str, marker: str) -> str:
    source = (ROOT / path).read_text()
    start = source.index(marker)
    brace = source.index("{", start)
    end = brace + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


router_path = "Aether/Backend/Observable/SourcesRouter.swift"
collection_route = declaration(router_path, "enum CollectionRoute: Hashable")
route = declaration(router_path, "enum Route: Hashable")
locator = declaration(router_path, "struct AppLocator: Hashable")
open_app = declaration(router_path, "func openResolvedApp(")

cell_path = "Aether/Views/Sources/Apps/SourceAppsCellView.swift"
cell_source = (ROOT / cell_path).read_text()
selection_wrapper = declaration(cell_path, "private func _selectableContent<Content: View>")
assert ".accessibilityAction(.default)" in selection_wrapper, "App details lost VoiceOver activation"
table_branch = selection_wrapper.split("case .tableView:", 1)[1]
assert "Button(" not in table_branch, "Hosted SwiftUI button competes with UIKit row selection"
assert "DownloadButtonView" in cell_source, "Separate download control was removed"
assert "SourceAppBodyText.body" in cell_source, "Extended description was removed"

table_path = "Aether/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift"
table_source = (ROOT / table_path).read_text()
did_select = declaration(table_path, "func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)")
assert "onSelect(" in did_select, "UITableView no longer owns touch navigation"
assert "selectionOwner: .tableView" in table_source
shutdown = declaration(table_path, "func shutdown(from tableView: UITableView)")
assert "_prepareTask?.cancel()" in shutdown and "_generation += 1" in shutdown
assert "_displayed = nil" in shutdown and "_previousDisplay = nil" in shutdown
assert "sourceContexts.removeAll" in shutdown and "onSelect = { _ in }" in shutdown
assert "!self._isShutdown, self.uiTableView === table,\n\t\t\t\t\tself._generation == generation" in table_source, \
    "A stale diffable-data-source completion can still modify a detached table"

overlay_path = "Aether/Views/Shared/SearchHeaderOverlay.swift"
overlay_source = (ROOT / overlay_path).read_text()
assert "private func firstSearchTextField" not in overlay_source, \
    "Search field cleanup must not depend on UIHostingConfiguration subviews"
assert "let searchFieldOwner = SearchTextFieldOwner()" in overlay_source
deactivate = declaration(overlay_path, "func deactivateAndDetach()")
teardown = declaration(overlay_path, "func tearDown()")
assert "searchFieldOwner.setScreenActive(false)" in deactivate
assert "searchFieldOwner.prepareForRemoval()" in teardown
report_frame = declaration(overlay_path, "func reportFrame()")
assert "publish(nil)" in report_frame, "Invalid window-frame measurements must clear stale anchors"
assert "sourceAnchor.windowID == barAnchor.windowID" in overlay_source

field_path = "Aether/Views/Shared/ToolbarSearchField.swift"
field_source = (ROOT / field_path).read_text()
assert "guard isScreenActive, window != nil else" in field_source
assert "self.isFirstResponder || self.hasKeyboardSession" in field_source
assert "transition?.isWaitingForKeyboard == true" in field_source

swift = f'''import Foundation
struct ASRepository {{ struct App: Hashable {{ let identifier: String }} }}
{collection_route}
{route}
{locator}
@MainActor final class RouterFixture {{
    var path: [Route] = []
    var pendingAppRequest: String? = "pending"
    {open_app}
}}
@MainActor func verifyRoutes() {{
    let router = RouterFixture()
    let parent = CollectionRoute.source(objectURI: "repo://one")
    let firstApp = AppLocator.locator(for: ASRepository.App(identifier: "com.example.first"))
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: firstApp)
    let expected = router.path
    precondition(expected.count == 2, "Opening an app must produce parent + detail")

    router.pendingAppRequest = "duplicate request"
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: firstApp)
    precondition(router.path == expected, "Opening the current detail route must not mutate the path")
    precondition(router.pendingAppRequest == nil, "Resolved requests must be cleared")

    let secondApp = AppLocator.locator(for: ASRepository.App(identifier: "com.example.second"))
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: secondApp)
    precondition(router.path == [.collection(parent), .app(parent: parent, sourceObjectURI: "repo://one", appLocator: secondApp)],
        "A different app in the same repository must replace the detail route")

    let secondParent = CollectionRoute.source(objectURI: "repo://two")
    router.openResolvedApp(parent: secondParent, sourceObjectURI: "repo://two", appLocator: firstApp)
    precondition(router.path == [.collection(secondParent), .app(parent: secondParent, sourceObjectURI: "repo://two", appLocator: firstApp)],
        "Opening an app from another repository must replace the parent and detail routes")
}}
@main struct NavigationCheck {{
    @MainActor static func main() {{
        verifyRoutes()
        print("Navigation hardening checks passed")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix="aether-navigation-check-") as temp:
    source = pathlib.Path(temp) / "navigation-check.swift"
    binary = pathlib.Path(temp) / "navigation-check"
    source.write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", "-o", str(binary), str(source)], check=True)
    subprocess.run([str(binary)], check=True)

# iOS 26 anchors confirmation dialogs to the modified view. List-level
# attachment makes a row action point at the list's center instead of the row.
all_apps = (ROOT / 'Aether/Views/Installed/AllInstalledAppsView.swift').read_text()
uninstall_row = all_apps[all_apps.index('ForEach(apps) { app in'):all_apps.index('\n\t\t.listStyle(.plain)')]
assert '.confirmationDialog(' in uninstall_row, 'Uninstall confirmation must be owned by its list row'
assert 'get: { pendingUninstall?.id == app.id }' in uninstall_row, 'Only the selected row may present Uninstall'
assert '.confirmationDialog(' not in all_apps[all_apps.index('\n\t\t.listStyle(.plain)'):], 'Uninstall must not anchor to the entire list'
library = (ROOT / 'Aether/Views/Library/LibraryView.swift').read_text()
ignore_row = declaration('Aether/Views/Library/LibraryView.swift', 'private func updatesSection(')
assert '.confirmationDialog(' in ignore_row and 'get: { updateIgnoreRequest?.app.id == app.id }' in ignore_row
print('Dialog anchor checks passed: Uninstall and Ignore belong to the selected row')

# Run the production transition gate with controlled UIKit transition callbacks.
reply = declaration(table_path, 'private final class SourceNavigationTransitionReply').replace('private final class', 'final class', 1)
wait = declaration(table_path, 'private func waitForOpeningNavigationTransition()').replace('private func', 'func', 1)
transition_checks = r'''
import Foundation
@MainActor class UIResponder {var next:UIResponder?}
@MainActor final class UIViewController:UIResponder {var navigationController:UINavigationController?}
@MainActor final class UINavigationController {var transitionCoordinator:Transition?}
@MainActor final class Transition {
 var isAnimated=true;var registered=true;var calls=0
 var replies:[(Bool)->Void]=[]
 func animate(alongsideTransition:((Bool)->Void)?,completion:@escaping (Bool)->Void)->Bool {
  calls+=1;replies.append(completion);return registered
 }
 func finish(){for reply in replies {reply(true)}}
}
@MainActor
REPLY
@MainActor final class Driver {
 var uiTableView:UIResponder?
 var completed=false;var applied=false;var active=true
 WAIT
 func load() async {
  await waitForOpeningNavigationTransition()
  completed=true
  guard !Task.isCancelled,active else {return}
  applied=true
 }
}
@main struct Checks {
 @MainActor static func ready(_ transition:Transition) async {
  for _ in 0..<1000 {if transition.calls>0{return};await Task.yield()}
  preconditionFailure("Transition callback was not registered")
 }
 @MainActor static func driver(_ transition:Transition)->Driver {
  let table=UIResponder(),owner=UIViewController(),navigation=UINavigationController()
  table.next=owner;owner.navigationController=navigation;navigation.transitionCoordinator=transition
  let result=Driver();result.uiTableView=table;return result
 }
 @MainActor static func main() async {
  let transition=Transition()
  let first=driver(transition)
  let request=Task {await first.load()};await ready(transition)
  precondition(!first.applied && !first.completed,"Cell reload waits while native navigation is animating")
  transition.finish();await request.value
  precondition(first.applied,"The first catalog is published as soon as navigation completes")
  transition.finish() // Repeated/late UIKit callback must never resume twice.
  let rejected=Transition();rejected.registered=false
  let rejectedDriver=driver(rejected);await rejectedDriver.load()
  precondition(rejectedDriver.applied,"Rejected transition registration cannot strand the list")
  rejected.finish();rejected.finish() // UIKit may still invoke completion after returning false.
  let noAnimation=Transition();noAnimation.isAnimated=false
  let immediate=driver(noAnimation);await immediate.load()
  precondition(immediate.applied && noAnimation.calls==0,"Nonanimated navigation never adds a delay")
  let absent=Driver();await absent.load();precondition(absent.applied)
  let canceled=Transition()
  let disappearing=driver(canceled)
  let old=Task {await disappearing.load()};await ready(canceled)
  old.cancel();disappearing.active=false;canceled.finish();await old.value
  precondition(!disappearing.applied,"A canceled or detached table cannot publish its old catalog")
  print("Repository transition checks passed: real completion, no-animation fast path, rejected/late callbacks and cancellation")
 }
}
'''.replace('REPLY', reply).replace('WAIT', wait)
with tempfile.TemporaryDirectory(prefix='aether-repo-transition-') as directory:
    directory=pathlib.Path(directory)
    path=directory/'Checks.swift';path.write_text(transition_checks)
    subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(path),'-o',str(directory/'checks')],check=True)
    subprocess.run([str(directory/'checks')],check=True)

prepare = declaration(table_path, 'func prepareList(')
assert prepare.index('await store.presentation(') < prepare.index('await self.waitForOpeningNavigationTransition()') < prepare.index('self.apply(')
assert 'if !self._hasAppliedList { await self.waitForOpeningNavigationTransition() }' in prepare
assert 'guard !Task.isCancelled, !self._isShutdown, self._generation == generation' in prepare
assert 'if enabled {\n\t\t\t\t\tSearchHeaderOverlay' in field_source, 'Custom search host must remain mounted independently of expansion'
assert 'transition.restore(isPresented: isPresented)' in field_source
sources = (ROOT/'Aether/Views/Sources/SourcesView.swift').read_text()
assert '_ = SourceLibraryDownloads.shared' in sources
print('Repository opening guards passed: prepare off-main, defer first reload and preserve the custom search host')
